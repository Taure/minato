-module(minato_txn_tests).
-moduledoc """
`m:minato_txn` against a server that says exactly what each case needs.

`minato_txn_SUITE` asks a real PostgreSQL whether the work was kept. What is
asked here is the other half: which statements `minato_txn` sends for each
outcome of the caller's function, and what it makes of every answer a server
can give them, including the ones a real server only gives when something
has already gone wrong.
""".

-include_lib("eunit/include/eunit.hrl").

-export([marked_idle/1, marked_open/1, marked_behind_a_stale_rollback/1, unmarked/1]).

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).
-define(BEGUN, [{command_complete, ~"BEGIN"}, {ready_for_query, transaction}]).
-define(COMMITTED, [{command_complete, ~"COMMIT"}, {ready_for_query, idle}]).
-define(ROLLED_BACK, [{command_complete, ~"ROLLBACK"}, {ready_for_query, idle}]).
-define(REFUSED, [
    {error_response, #{severity => ~"ERROR", code => ~"25P02", message => ~"aborted"}},
    {ready_for_query, failed}
]).

%%----------------------------------------------------------------------
%% One statement each
%%----------------------------------------------------------------------

open_begins_test() ->
    {Server, Conn} = connected([?BEGUN]),
    {ok, Open} = minato_txn:open(Conn),
    ?assertEqual(transaction, minato_txn:status(Open)),
    ?assertEqual([{query, ~"BEGIN"}], asked(Server)).

commit_commits_test() ->
    {Server, Conn} = connected([?COMMITTED]),
    {ok, Committed} = minato_txn:commit(Conn),
    ?assertEqual(idle, minato_txn:status(Committed)),
    ?assertEqual([{query, ~"COMMIT"}], asked(Server)).

a_commit_answered_with_a_rollback_is_an_error_test() ->
    {_Server, Conn} = connected([?ROLLED_BACK]),
    ?assertMatch({error, transaction_rolled_back, _Conn}, minato_txn:commit(Conn)).

a_rollback_answered_with_a_rollback_is_not_an_error_test() ->
    {Server, Conn} = connected([?ROLLED_BACK]),
    ?assertMatch({ok, _Conn}, minato_txn:rollback(Conn)),
    ?assertEqual([{query, ~"ROLLBACK"}], asked(Server)).

a_statement_the_server_refuses_is_returned_with_the_connection_test() ->
    {_Server, Conn} = connected([?REFUSED]),
    {error, {pgsql_error, #{code := Code}}, Failed} = minato_txn:commit(Conn),
    ?assertEqual(~"25P02", Code),
    ?assertEqual(failed, minato_txn:status(Failed)).

a_statement_on_a_closed_connection_has_no_connection_to_return_test() ->
    {_Server, Conn} = connected([]),
    ok = minato_conn:close(Conn),
    ?assertMatch({error, _Reason}, minato_txn:open(Conn)).

savepoints_are_quoted_test() ->
    Named = [{command_complete, ~"SAVEPOINT"}, {ready_for_query, transaction}],
    Returned = [{command_complete, ~"ROLLBACK"}, {ready_for_query, transaction}],
    Released = [{command_complete, ~"RELEASE"}, {ready_for_query, transaction}],
    {Server, Conn} = connected([Named, Returned, Released]),
    {ok, Saved} = minato_txn:savepoint(Conn, ~"a \"b\""),
    {ok, Back} = minato_txn:rollback_to(Saved, ~"a \"b\""),
    {ok, _Kept} = minato_txn:release(Back, ~"plain"),
    ?assertEqual(
        [
            {query, ~"SAVEPOINT \"a \"\"b\"\"\""},
            {query, ~"ROLLBACK TO SAVEPOINT \"a \"\"b\"\"\""},
            {query, ~"RELEASE SAVEPOINT \"plain\""}
        ],
        asked(Server)
    ).

a_rollback_to_a_savepoint_is_not_a_refused_commit_test() ->
    Returned = [{command_complete, ~"ROLLBACK"}, {ready_for_query, transaction}],
    {_Server, Conn} = connected([Returned]),
    ?assertMatch({ok, _Conn}, minato_txn:rollback_to(Conn, ~"a")).

%%----------------------------------------------------------------------
%% A function's outcome
%%----------------------------------------------------------------------

ok_commits_and_hands_back_the_value_test() ->
    {Server, Conn} = connected([?BEGUN, ?COMMITTED]),
    {ok, Value, Committed} = minato_txn:transaction(Conn, fun(Open) -> {ok, done, Open} end),
    ?assertEqual(done, Value),
    ?assertEqual(idle, minato_txn:status(Committed)),
    ?assertEqual([{query, ~"BEGIN"}, {query, ~"COMMIT"}], asked(Server)).

rollback_rolls_back_and_hands_back_the_reason_test() ->
    {Server, Conn} = connected([?BEGUN, ?ROLLED_BACK]),
    Answer = minato_txn:transaction(Conn, fun(Open) -> {rollback, changed_my_mind, Open} end),
    ?assertMatch({rollback, changed_my_mind, _Conn}, Answer),
    ?assertEqual([{query, ~"BEGIN"}, {query, ~"ROLLBACK"}], asked(Server)).

an_error_without_a_connection_sends_nothing_more_test() ->
    {Server, Conn} = connected([?BEGUN]),
    Answer = minato_txn:transaction(Conn, fun(_Open) -> {error, {socket, closed}} end),
    ?assertEqual({error, {socket, closed}}, Answer),
    ?assertEqual([{query, ~"BEGIN"}], asked(Server)).

a_begin_that_fails_never_calls_the_function_test() ->
    {Server, Conn} = connected([?REFUSED]),
    Answer = minato_txn:transaction(Conn, fun(_Open) -> error(called) end),
    ?assertMatch({error, {pgsql_error, #{code := ~"25P02"}}, _Conn}, Answer),
    ?assertEqual([{query, ~"BEGIN"}], asked(Server)).

a_commit_the_server_turned_into_a_rollback_is_an_error_test() ->
    {_Server, Conn} = connected([?BEGUN, ?ROLLED_BACK]),
    Answer = minato_txn:transaction(Conn, fun(Open) -> {ok, done, Open} end),
    ?assertMatch({error, transaction_rolled_back, _Conn}, Answer).

a_rollback_the_server_refuses_is_an_error_test() ->
    {_Server, Conn} = connected([?BEGUN, ?REFUSED]),
    Answer = minato_txn:transaction(Conn, fun(Open) -> {rollback, why, Open} end),
    ?assertMatch({error, {pgsql_error, #{code := ~"25P02"}}, _Conn}, Answer).

%%----------------------------------------------------------------------
%% A function that raises
%%----------------------------------------------------------------------

an_exception_is_raised_again_as_it_was_test_() ->
    [
        {atom_to_list(Class), fun() ->
            {_Server, Conn} = connected([?BEGUN, [], {reply, {?MODULE, marked_idle}}]),
            Raised =
                try minato_txn:transaction(Conn, fun(_Open) -> erlang:Class(stopped) end) of
                    Answer -> {answered, Answer}
                catch
                    Caught:Reason -> {Caught, Reason}
                end,
            ?assertEqual({Class, stopped}, Raised)
        end}
     || Class <- [error, exit, throw]
    ].

an_exception_rolls_back_behind_a_sync_test() ->
    {Server, Conn} = connected([?BEGUN, [], {reply, {?MODULE, marked_idle}}]),
    ?assertError(stopped, minato_txn:transaction(Conn, fun(_Open) -> error(stopped) end)),
    [{query, ~"BEGIN"}, sync, {query, Rollback}] = asked(Server),
    ?assertEqual(
        match, re:run(Rollback, ~"^ROLLBACK; SELECT '[0-9A-F]{16}'$", [{capture, none}])
    ).

an_exception_that_rolled_back_keeps_the_connection_test() ->
    Script = [?BEGUN, [], {reply, {?MODULE, marked_idle}}, ?COMMITTED],
    {Server, Conn} = connected(Script),
    ?assertError(stopped, minato_txn:transaction(Conn, fun(_Open) -> error(stopped) end)),
    ?assertMatch({ok, _Conn}, minato_txn:commit(Conn)),
    ?assertEqual(
        [query, sync, query, query], [kind(Message) || Message <- asked(Server)]
    ).

a_mark_behind_somebody_elses_rollback_is_still_waited_for_test() ->
    Script = [?BEGUN, [], {reply, {?MODULE, marked_behind_a_stale_rollback}}, ?COMMITTED],
    {_Server, Conn} = connected(Script),
    ?assertError(stopped, minato_txn:transaction(Conn, fun(_Open) -> error(stopped) end)),
    ?assertMatch({ok, _Conn}, minato_txn:commit(Conn)).

a_rollback_that_left_a_transaction_open_costs_the_connection_test() ->
    closes_after([?BEGUN, [], {reply, {?MODULE, marked_open}}]).

a_rollback_whose_mark_never_comes_costs_the_connection_test() ->
    closes_after([?BEGUN, [], {reply, {?MODULE, unmarked}}]).

a_rollback_answered_with_what_is_not_a_message_costs_the_connection_test() ->
    closes_after([?BEGUN, [], {raw, <<$Z, 0:32>>}]).

a_rollback_that_cannot_be_sent_costs_nothing_more_test() ->
    {_Server, Conn} = connected([?BEGUN]),
    Closing = fun(Open) ->
        ok = minato_conn:close(Open),
        error(stopped)
    end,
    ?assertError(stopped, minato_txn:transaction(Conn, Closing)).

closes_after(Script) ->
    {Server, Conn} = connected(Script, #{timeout => 300}),
    ?assertError(stopped, minato_txn:transaction(Conn, fun(_Open) -> error(stopped) end)),
    ?assertMatch({error, _Closed}, minato_txn:commit(Conn)),
    ?assertEqual(terminate, lists:last(asked(Server))).

%%----------------------------------------------------------------------
%% What the server says to the rollback
%%----------------------------------------------------------------------

marked_idle({query, Sql}) ->
    [{command_complete, ~"ROLLBACK"} | mark(Sql)] ++ [{ready_for_query, idle}].

marked_open({query, Sql}) ->
    [{command_complete, ~"ROLLBACK"} | mark(Sql)] ++ [{ready_for_query, transaction}].

%% An answer the function never read, which looks like the rollback's own
%% right up to the row: a `ROLLBACK` tag and an idle `ReadyForQuery`.
marked_behind_a_stale_rollback({query, _Sql} = Query) ->
    [{command_complete, ~"ROLLBACK"}, {ready_for_query, idle} | marked_idle(Query)].

unmarked({query, _Sql}) ->
    [
        {command_complete, ~"ROLLBACK"},
        {data_row, [~"0000000000000000"]},
        {command_complete, ~"SELECT 1"},
        {ready_for_query, idle}
    ].

mark(Sql) ->
    {match, [Mark]} = re:run(Sql, ~"SELECT '([^']+)'", [{capture, all_but_first, binary}]),
    [{data_row, [Mark]}, {command_complete, ~"SELECT 1"}].

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

connected(Script) ->
    connected(Script, #{}).

connected(Script, Opts) ->
    Server = minato_backend_server:start([?READY | Script]),
    Port = minato_backend_server:port(Server),
    {ok, Conn} = minato_conn:connect(
        maps:merge(#{host => "127.0.0.1", port => Port, user => ~"minato", timeout => 5000}, Opts)
    ),
    {Server, Conn}.

%% Reading the server's mailbox races the server reading its socket, so ask
%% only once the client has had every answer it was waiting for.
asked(Server) ->
    [Message || Message <- minato_backend_server:received(Server), kind(Message) =/= startup].

kind(Message) when is_atom(Message) -> Message;
kind(Message) -> element(1, Message).
