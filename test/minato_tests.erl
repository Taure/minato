-module(minato_tests).
-moduledoc """
`m:minato` over a pool whose server says exactly what each case needs.

The suites ask a real PostgreSQL whether the statement did what it said. What
is asked here is what `m:minato` does with the connection afterwards, for every
way a borrowed connection can come back: kept, kept after an error that left it
in step, and given up on. A connection that was given up on is closed, and the
server sees the `Terminate`.
""".

-include_lib("eunit/include/eunit.hrl").

-export([served/1, commit_rolled_back/1, silent/1]).

-define(POOL, minato_tests_pool).
-define(LISTENER, minato_tests_listener).
-define(INT4, 23).

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).
-define(IDLE, {ready_for_query, idle}).
-define(REFUSED,
    {error_response, #{severity => ~"ERROR", code => ~"42601", message => ~"refused"}}
).

%%----------------------------------------------------------------------
%% Statements
%%----------------------------------------------------------------------

a_statement_is_answered_and_its_connection_kept_test_() ->
    pooled(fun(Server) ->
        ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])),
        ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [], #{})),
        ?assertMatch({ok, [#{rows := [{~"1"}]}]}, minato:simple(?POOL, ~"SELECT 1")),
        ?assertMatch({ok, [#{rows := [{~"1"}]}]}, minato:simple(?POOL, ~"SELECT 1", #{})),
        ?assertEqual(1, opened(Server)),
        ?assertNot(closed(Server))
    end).

a_statement_is_kept_on_its_connection_test_() ->
    pooled(fun(Server) ->
        {ok, _First} = minato:query(?POOL, ~"SELECT 1", []),
        {ok, _Second} = minato:query(?POOL, ~"SELECT 1", []),
        ?assertEqual(1, length([Parse || {parse, _, _, _} = Parse <- asked(Server)]))
    end).

a_statement_the_server_refuses_keeps_its_connection_test_() ->
    pooled(fun(Server) ->
        ?assertMatch(
            {error, {pgsql_error, #{code := ~"42601"}}}, minato:simple(?POOL, ~"refused")
        ),
        ?assertMatch({ok, _Result}, minato:query(?POOL, ~"SELECT 1", [])),
        ?assertNot(closed(Server))
    end).

a_statement_that_lost_its_connection_gives_it_up_test_() ->
    pooled(fun(Server) ->
        ?assertMatch({error, _Reason}, minato:simple(?POOL, ~"silence")),
        ?assert(closed(Server))
    end).

a_statement_raised_over_what_the_server_sent_gives_up_its_connection_test_() ->
    pooled(fun(Server) ->
        ?assertError(
            {minato_protocol, #{reason := column_count_mismatch}},
            minato:simple(?POOL, ~"mismatch")
        ),
        ?assert(closed(Server))
    end).

a_statement_raised_over_its_values_keeps_its_connection_test_() ->
    pooled(fun(Server) ->
        ?assertError(
            {minato_query, #{reason := parameter_count_mismatch}},
            minato:query(?POOL, ~"SELECT 1", [1, 2])
        ),
        ?assertMatch({ok, _Result}, minato:query(?POOL, ~"SELECT 1", [])),
        ?assertNot(closed(Server))
    end).

a_pool_that_is_not_there_is_asked_nothing_test_() ->
    [
        ?_assertMatch({error, _Reason}, minato:query(minato_tests_no_such_pool, ~"SELECT 1", [])),
        ?_assertMatch({error, _Reason}, minato:simple(minato_tests_no_such_pool, ~"SELECT 1")),
        ?_assertMatch(
            {error, _Reason},
            minato:with(minato_tests_no_such_pool, fun(Conn) -> {keep, kept, Conn} end)
        ),
        ?_assertMatch(
            {error, _Reason},
            minato:transaction(minato_tests_no_such_pool, fun(Conn) -> {ok, done, Conn} end)
        ),
        ?_assertMatch({error, _Reason}, minato:health(minato_tests_no_such_pool))
    ].

a_statement_with_no_pool_to_borrow_from_is_an_error_test_() ->
    pooled(fun(_Server) ->
        Held = held(),
        ?assertEqual({error, checkout_timeout}, minato:health(?POOL, 50)),
        ?assertMatch({error, _Reason}, minato:health(?POOL, 0)),
        ok = released(Held)
    end).

%%----------------------------------------------------------------------
%% Borrowing
%%----------------------------------------------------------------------

a_borrower_says_what_becomes_of_the_connection_test_() ->
    pooled(fun(Server) ->
        ?assertEqual(kept, minato:with(?POOL, fun(Conn) -> {keep, kept, Conn} end)),
        ?assertNot(closed(Server)),
        ?assertEqual(dropped, minato:with(?POOL, fun(_Conn) -> {discard, dropped} end)),
        ?assert(closed(Server))
    end).

a_borrower_that_raises_loses_the_connection_and_raises_again_test_() ->
    [
        pooled(fun(Server) ->
            Raised =
                try minato:with(?POOL, fun(_Conn) -> erlang:Class(stopped) end) of
                    Answer -> {answered, Answer}
                catch
                    Caught:Reason -> {Caught, Reason}
                end,
            ?assertEqual({Class, stopped}, Raised),
            ?assert(closed(Server))
        end)
     || Class <- [error, exit, throw]
    ].

a_borrower_that_raises_what_a_statement_would_still_loses_it_test_() ->
    pooled(fun(Server) ->
        Raise = fun(_Conn) -> error({minato_query, #{reason => parameter_count_mismatch}}) end,
        ?assertError({minato_query, _Report}, minato:with(?POOL, Raise)),
        ?assert(closed(Server))
    end).

a_connection_handed_on_is_the_new_owners_test_() ->
    pooled(fun(_Server) ->
        Self = self(),
        Owner = spawn_link(fun() ->
            receive
                {use, Conn} ->
                    {ok, _Result, Used} = minato_query:simple(Conn, ~"SELECT 1"),
                    ok = minato_pool:checkin(?POOL, Used),
                    Self ! used
            end
        end),
        {ok, Conn} = minato_pool:checkout(?POOL),
        ?assertEqual(ok, minato:give_away(?POOL, Conn, Owner)),
        Owner ! {use, Conn},
        receive
            used -> ok
        after 2000 -> error(not_used)
        end,
        ?assertMatch(#{size := 1, borrowed := 0}, minato:stats(?POOL))
    end).

%%----------------------------------------------------------------------
%% Transactions
%%----------------------------------------------------------------------

a_transaction_answers_with_what_its_function_decided_test_() ->
    pooled(fun(Server) ->
        ?assertEqual(
            {ok, done}, minato:transaction(?POOL, fun(Conn) -> {ok, done, Conn} end)
        ),
        ?assertEqual(
            {rollback, changed_my_mind},
            minato:transaction(?POOL, fun(Conn) -> {rollback, changed_my_mind, Conn} end)
        ),
        ?assertEqual(
            [~"BEGIN", ~"COMMIT", ~"BEGIN", ~"ROLLBACK"],
            [Sql || {query, Sql} <- asked(Server), byte_size(Sql) < 10]
        ),
        ?assertNot(closed(Server))
    end).

a_transaction_that_lost_its_connection_gives_it_up_test_() ->
    pooled(fun(Server) ->
        ?assertEqual(
            {error, {socket, closed}},
            minato:transaction(?POOL, fun(_Conn) -> {error, {socket, closed}} end)
        ),
        ?assert(closed(Server))
    end).

a_commit_the_server_rolled_back_is_an_error_on_a_kept_connection_test_() ->
    pooled(script({?MODULE, commit_rolled_back}), fun(Server) ->
        ?assertEqual(
            {error, transaction_rolled_back},
            minato:transaction(?POOL, fun(Conn) -> {ok, done, Conn} end)
        ),
        ?assertNot(closed(Server))
    end).

%%----------------------------------------------------------------------
%% Health
%%----------------------------------------------------------------------

a_pool_that_answers_is_healthy_and_keeps_its_own_timeout_test_() ->
    pooled(fun(Server) ->
        ?assertEqual(ok, minato:health(?POOL)),
        ?assertEqual(ok, minato:health(?POOL, 400)),
        ?assertEqual(
            1000, minato:with(?POOL, fun(Conn) -> {keep, minato_conn:timeout(Conn), Conn} end)
        ),
        ?assertNot(closed(Server))
    end).

a_pool_whose_server_says_nothing_is_not_healthy_test_() ->
    pooled(script({?MODULE, silent}), fun(Server) ->
        ?assertMatch({error, _Reason}, minato:health(?POOL, 100)),
        ?assert(closed(Server))
    end).

a_pool_whose_server_refuses_the_question_is_not_healthy_test_() ->
    pooled(script({?MODULE, commit_rolled_back}), fun(Server) ->
        ?assertMatch({error, {pgsql_error, #{code := ~"42601"}}}, minato:health(?POOL, 400)),
        ?assertEqual(
            1000, minato:with(?POOL, fun(Conn) -> {keep, minato_conn:timeout(Conn), Conn} end)
        ),
        ?assertNot(closed(Server))
    end).

%%----------------------------------------------------------------------
%% Starting and stopping
%%----------------------------------------------------------------------

a_pool_is_stopped_once_test_() ->
    pooled(fun(_Server) ->
        ?assertMatch(#{size := 1}, minato:stats(?POOL)),
        ?assertEqual({error, not_found}, minato:stop_pool(minato_tests_no_such_pool))
    end).

a_listener_is_started_subscribed_to_and_stopped_test_() ->
    {timeout, 30, fun() ->
        {ok, _Started} = application:ensure_all_started(minato),
        _ = minato_sup:stop_listener(?LISTENER),
        Server = minato_backend_server:start(script({?MODULE, served})),
        {ok, _Pid} = minato:start_listener(?LISTENER, #{connection => connection(Server)}),
        try
            ?assertEqual(ok, minato:listen(?LISTENER, ~"jobs")),
            ?assertEqual(#{~"jobs" => 1}, minato_listener:channels(?LISTENER)),
            ?assertEqual(ok, minato:unlisten(?LISTENER, ~"jobs")),
            ?assertEqual(#{}, minato_listener:channels(?LISTENER)),
            ?assertEqual(
                [~"LISTEN \"jobs\"", ~"UNLISTEN \"jobs\""], [Sql || {query, Sql} <- asked(Server)]
            )
        after
            ?assertEqual(ok, minato:stop_listener(?LISTENER)),
            ?assertEqual({error, not_found}, minato:stop_listener(?LISTENER)),
            minato_backend_server:stop(Server)
        end
    end}.

%%----------------------------------------------------------------------
%% What the server says
%%----------------------------------------------------------------------

served({query, ~"SHOW max_connections"}) ->
    [{command_complete, ~"SHOW"}, ?IDLE];
served({query, <<"CLOSE ALL; ", _/binary>> = Sql}) ->
    reset(Sql);
served({query, <<"ROLLBACK; CLOSE ALL; ", _/binary>> = Sql}) ->
    [{command_complete, ~"ROLLBACK"} | reset(Sql)];
served({query, ~"BEGIN"}) ->
    [{command_complete, ~"BEGIN"}, {ready_for_query, transaction}];
served({query, ~"COMMIT"}) ->
    [{command_complete, ~"COMMIT"}, ?IDLE];
served({query, ~"ROLLBACK"}) ->
    [{command_complete, ~"ROLLBACK"}, ?IDLE];
served({query, ~"refused"}) ->
    [?REFUSED, ?IDLE];
served({query, ~"silence"}) ->
    [];
served({query, ~"mismatch"}) ->
    [
        {row_description, [column(25)]},
        {data_row, [~"1", ~"2"]},
        {command_complete, ~"SELECT 1"},
        ?IDLE
    ];
served({query, <<"LISTEN ", _/binary>>}) ->
    [{command_complete, ~"LISTEN"}, ?IDLE];
served({query, <<"UNLISTEN ", _/binary>>}) ->
    [{command_complete, ~"UNLISTEN"}, ?IDLE];
served({query, _Sql}) ->
    [
        {row_description, [column(25)]},
        {data_row, [~"1"]},
        {command_complete, ~"SELECT 1"},
        ?IDLE
    ];
served(flush) ->
    [parse_complete, {parameter_description, []}, {row_description, [column(?INT4)]}];
served(sync) ->
    [bind_complete, {data_row, [<<1:32>>]}, {command_complete, ~"SELECT 1"}, ?IDLE];
served(_Message) ->
    [].

%% A server that turns every `COMMIT` into a `ROLLBACK`, and will not parse.
commit_rolled_back({query, ~"COMMIT"}) -> [{command_complete, ~"ROLLBACK"}, ?IDLE];
commit_rolled_back(flush) -> [?REFUSED];
commit_rolled_back(sync) -> [?IDLE];
commit_rolled_back(Message) -> served(Message).

%% A server that answers the pool and nobody else.
silent({query, _Sql} = Query) -> served(Query);
silent(_Message) -> [].

reset(Sql) ->
    {match, [Nonce]} = re:run(Sql, ~"SELECT '([0-9A-F]+)' WHERE", [{capture, all_but_first, binary}]),
    [
        {command_complete, ~"CLOSE CURSOR ALL"},
        {command_complete, ~"SET"},
        {command_complete, ~"RESET"},
        {command_complete, ~"UNLISTEN"},
        {command_complete, ~"SELECT 1"},
        {command_complete, ~"DISCARD TEMP"},
        {command_complete, ~"DISCARD SEQUENCES"},
        {data_row, [Nonce]},
        {command_complete, ~"SELECT 1"},
        ?IDLE
    ].

column(Oid) ->
    #{
        name => ~"a",
        table_oid => 0,
        column => 0,
        type_oid => Oid,
        type_size => -1,
        type_modifier => -1,
        format => text
    }.

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

script(Reply) ->
    [?READY | lists:duplicate(200, {reply, Reply})].

pooled(Fun) ->
    pooled(script({?MODULE, served}), Fun).

pooled(Script, Fun) ->
    {timeout, 30, fun() ->
        {ok, _Started} = application:ensure_all_started(minato),
        _ = minato_sup:stop_pool(?POOL),
        Server = minato_backend_server:start(Script),
        {ok, _Pid} = minato:start_pool(?POOL, #{
            size => 1, min_size => 1, connection => connection(Server)
        }),
        try
            Fun(Server)
        after
            ?assertEqual(ok, minato:stop_pool(?POOL)),
            minato_backend_server:stop(Server)
        end
    end}.

connection(Server) ->
    #{
        host => "127.0.0.1",
        port => minato_backend_server:port(Server),
        user => ~"minato",
        timeout => 1000
    }.

%% The pool's one connection, borrowed by a process that keeps it until told.
held() ->
    Self = self(),
    Holder = spawn_link(fun() ->
        {ok, Conn} = minato_pool:checkout(?POOL),
        Self ! {held, self()},
        receive
            release -> ok = minato_pool:checkin(?POOL, Conn)
        end,
        Self ! {released, self()}
    end),
    receive
        {held, Holder} -> Holder
    after 5000 -> error(not_held)
    end.

released(Holder) ->
    Holder ! release,
    receive
        {released, Holder} -> ok
    after 5000 -> error(not_released)
    end.

%% Asked once the call has its answer, and the server hands a message over
%% before it answers it.
asked(Server) ->
    [
        Message
     || Message <- minato_backend_server:received(Server, 20), kind(Message) =/= startup
    ].

opened(Server) ->
    length([
        Message
     || Message <- minato_backend_server:received(Server, 20), kind(Message) =:= startup
    ]).

%% `Terminate` is never answered, so it is waited for, and not for longer than
%% it takes to come.
closed(Server) ->
    closed(Server, 10).

closed(_Server, 0) ->
    false;
closed(Server, Tries) ->
    lists:member(terminate, minato_backend_server:received(Server, 20)) orelse
        closed(Server, Tries - 1).

kind(Message) when is_atom(Message) -> Message;
kind(Message) -> element(1, Message).
