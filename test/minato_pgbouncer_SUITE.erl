-module(minato_pgbouncer_SUITE).
-moduledoc """
minato through PgBouncer in transaction pooling mode.

A transaction pooler gives a client a server connection for the length of one
transaction and takes it back at the `ReadyForQuery` that ends it, so two
statements from one client can be answered by two backends. Everything minato
keeps on a session is tested here against that: the statements it parses by
name, the transaction it holds open, the reset a pool sends, a cancel, and a
`LISTEN`.

Two poolers stand in front of the test server, each with two server
connections and no more. `prepared` runs with `max_prepared_statements` above
zero, where PgBouncer follows named statements from backend to backend itself.
`unprepared` runs with it at zero, where it does not, and with
`server_round_robin` on so that the next statement always goes to the other
backend: what a busy pooler does some of the time, done every time.

Which backend answers is steered rather than hoped for. A client inside a
transaction keeps its backend, so with one of the two kept the other is the
only one left.

A group skips when its pooler does not answer.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_group/2, end_per_group/2]).
-export([
    a_simple_query_is_answered/1,
    a_statement_with_parameters_is_answered/1,
    a_transaction_stays_on_one_backend/1,
    a_rollback_leaves_nothing_behind/1,
    an_exception_in_a_transaction_rolls_back/1,
    a_statement_past_its_deadline_is_cancelled/1,
    a_pool_is_served_and_reset_through_the_pooler/1,
    a_notification_does_not_reach_a_listener_behind_the_pooler/1,
    a_kept_statement_follows_the_client_to_another_backend/1,
    a_kept_statement_first_used_on_another_backend_is_refused/1,
    a_kept_statement_lost_to_another_backend_is_parsed_again/1,
    a_connection_that_keeps_no_statements_is_answered_by_any_backend/1
]).

-define(TIMEOUT, 10000).
-define(POOL, minato_pgbouncer_pool).
-define(LISTENER, minato_pgbouncer_listener).
-define(BACKEND, ~"SELECT pg_backend_pid()").

-spec all() -> [{group, atom()}].
all() ->
    [{group, prepared}, {group, unprepared}].

-spec groups() -> [{atom(), [term()], [atom()]}].
groups() ->
    [
        {prepared, [], either() ++ [a_kept_statement_follows_the_client_to_another_backend]},
        {unprepared, [],
            either() ++
                [
                    a_kept_statement_first_used_on_another_backend_is_refused,
                    a_kept_statement_lost_to_another_backend_is_parsed_again,
                    a_connection_that_keeps_no_statements_is_answered_by_any_backend
                ]}
    ].

either() ->
    [
        a_simple_query_is_answered,
        a_statement_with_parameters_is_answered,
        a_transaction_stays_on_one_backend,
        a_rollback_leaves_nothing_behind,
        an_exception_in_a_transaction_rolls_back,
        a_statement_past_its_deadline_is_cancelled,
        a_pool_is_served_and_reset_through_the_pooler,
        a_notification_does_not_reach_a_listener_behind_the_pooler
    ].

-spec init_per_group(atom(), [{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_group(Group, Config) ->
    Pooler = pooler(Group),
    case minato_conn:connect(Pooler) of
        {ok, Conn} ->
            ok = minato_conn:close(Conn),
            {ok, _Started} = application:ensure_all_started(minato),
            [{pooler, Pooler}, {kept, kept(Group)} | Config];
        {error, Reason} ->
            {skip, {no_pooler, Reason}}
    end.

-spec end_per_group(atom(), [{atom(), term()}]) -> ok.
end_per_group(_Group, _Config) ->
    ok = application:stop(minato).

%%----------------------------------------------------------------------
%% Either setting
%%----------------------------------------------------------------------

-spec a_simple_query_is_answered([{atom(), term()}]) -> ok.
a_simple_query_is_answered(Config) ->
    Conn = connected(Config),
    {ok, [First, Second], Read} = minato_query:simple(Conn, ~"SELECT 1; SELECT 'two'"),
    ?assertMatch(#{command := select, rows := [{1}]}, First),
    ?assertMatch(#{command := select, rows := [{~"two"}]}, Second),
    ok = minato_conn:close(Read).

-spec a_statement_with_parameters_is_answered([{atom(), term()}]) -> ok.
a_statement_with_parameters_is_answered(Config) ->
    Sql = ~"SELECT $1::int4 + 1, $2::text",
    {ok, Result, Read} = minato_query:query(connected(Config), Sql, [41, ~"a"]),
    ?assertMatch(#{rows := [{42, ~"a"}]}, Result),
    ok = minato_conn:close(Read).

-spec a_transaction_stays_on_one_backend([{atom(), term()}]) -> ok.
a_transaction_stays_on_one_backend(Config) ->
    {ok, Open} = minato_txn:open(connected(Config)),
    {First, One} = backend(Open),
    {Second, Two} = backend(One),
    {Third, Three} = backend(Two),
    ?assertEqual([First, First], [Second, Third]),
    {ok, Committed} = minato_txn:commit(Three),
    ok = minato_conn:close(Committed).

-spec a_rollback_leaves_nothing_behind([{atom(), term()}]) -> ok.
a_rollback_leaves_nothing_behind(Config) ->
    Conn = connected(Config),
    {ok, _Dropped, Clean} = minato_query:simple(Conn, ~"DROP TABLE IF EXISTS minato_pooled"),
    {ok, _Created, Made} = minato_query:simple(Clean, ~"CREATE TABLE minato_pooled (id int4)"),
    {ok, Open} = minato_txn:open(Made),
    {ok, _Result, Written} =
        minato_query:query(Open, ~"INSERT INTO minato_pooled VALUES ($1)", [1]),
    {ok, Rolled} = minato_txn:rollback(Written),
    {ok, Counted, Read} =
        minato_query:query(Rolled, ~"SELECT count(*)::int4 FROM minato_pooled", []),
    ?assertMatch(#{rows := [{0}]}, Counted),
    {ok, _Gone, Done} = minato_query:simple(Read, ~"DROP TABLE minato_pooled"),
    ok = minato_conn:close(Done).

-spec an_exception_in_a_transaction_rolls_back([{atom(), term()}]) -> ok.
an_exception_in_a_transaction_rolls_back(Config) ->
    Conn = connected(Config),
    Raised = fun(Open) ->
        ok = minato_conn:send(Open, {query, ~"SELECT 1"}),
        error(stopped_with_an_answer_unread)
    end,
    ?assertError(stopped_with_an_answer_unread, minato_txn:transaction(Conn, Raised)),
    {ok, Result, Read} = minato_query:query(Conn, ~"SELECT $1::int4", [2]),
    ?assertMatch(#{rows := [{2}]}, Result),
    ?assertEqual(idle, minato_txn:status(Read)),
    ok = minato_conn:close(Read).

-spec a_statement_past_its_deadline_is_cancelled([{atom(), term()}]) -> ok.
a_statement_past_its_deadline_is_cancelled(Config) ->
    Started = erlang:monotonic_time(millisecond),
    Answer =
        minato_query:query(connected(Config), ~"SELECT pg_sleep(30)", [], #{timeout => 300}),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assertMatch({error, {pgsql_error, #{code := ~"57014"}}, _Conn}, Answer),
    ?assert(Elapsed < 5000),
    {error, _Reason, Cancelled} = Answer,
    ?assertMatch({ok, #{rows := [{1}]}, _Read}, minato_query:query(Cancelled, ~"SELECT 1", [])),
    ok = minato_conn:close(Cancelled).

-spec a_pool_is_served_and_reset_through_the_pooler([{atom(), term()}]) -> ok.
a_pool_is_served_and_reset_through_the_pooler(Config) ->
    {ok, _Pid} = minato:start_pool(?POOL, #{
        size => 4, min_size => 4, connection => pooled(Config)
    }),
    Test = self(),
    Callers = [
        spawn_link(fun() -> Test ! {self(), asked(Caller, 25)} end)
     || Caller <- lists:seq(1, 8)
    ],
    Answers = [
        receive
            {Caller, Answer} -> Answer
        after 60000 -> error(a_caller_never_came_back)
        end
     || Caller <- Callers
    ],
    #{disconnects := Disconnects} = minato:stats(?POOL),
    ok = minato:stop_pool(?POOL),
    ?assertEqual(lists:duplicate(8, ok), Answers),
    ?assertEqual(0, Disconnects).

asked(_Caller, 0) ->
    ok;
asked(Caller, Left) ->
    {ok, #{rows := [{Caller, Left}]}} =
        minato:query(?POOL, ~"SELECT $1::int4, $2::int4", [Caller, Left]),
    {ok, Left} = minato:transaction(?POOL, fun(Conn) ->
        {ok, #{rows := [{Sum}]}, Read} =
            minato_query:query(Conn, ~"SELECT $1::int4 + $2::int4", [Caller, Left]),
        ?assertEqual(Caller + Left, Sum),
        {ok, Left, Read}
    end),
    asked(Caller, Left - 1).

-spec a_notification_does_not_reach_a_listener_behind_the_pooler([{atom(), term()}]) -> ok.
a_notification_does_not_reach_a_listener_behind_the_pooler(Config) ->
    {ok, _Pid} = minato:start_listener(?LISTENER, #{connection => pooled(Config)}),
    ok = minato:listen(?LISTENER, ~"minato_pooled_events"),
    {ok, Direct} = minato_conn:connect(server()),
    {ok, _Result, Notified} =
        minato_query:query(Direct, ~"SELECT pg_notify($1, $2)", [~"minato_pooled_events", ~"one"]),
    ok = minato_conn:close(Notified),
    Heard =
        receive
            {minato_notification, _Channel, _Payload, _From} = Notification -> Notification
        after 1000 -> nothing
        end,
    ok = minato:stop_listener(?LISTENER),
    ok = unlistened(Config),
    ?assertEqual(nothing, Heard).

%% The `LISTEN` stays on whichever backend ran it, and nothing takes it off
%% again when the listener goes: the pooler does not reset a server connection
%% in this mode. Both backends are asked, so the next case starts without it.
unlistened(Config) ->
    {_First, One} = held(Config),
    {_Second, Other} = held(Config),
    ok = released(unlisten(One)),
    ok = released(unlisten(Other)).

unlisten(Conn) ->
    {ok, _Result, Read} = minato_query:simple(Conn, ~"UNLISTEN *"),
    Read.

%%----------------------------------------------------------------------
%% max_prepared_statements above zero
%%----------------------------------------------------------------------

-spec a_kept_statement_follows_the_client_to_another_backend([{atom(), term()}]) -> ok.
a_kept_statement_follows_the_client_to_another_backend(Config) ->
    Conn = connected(Config),
    {First, Kept} = held(Config),
    {ok, #{rows := [{Second}]}, Once} = minato_query:cached(Conn, ?BACKEND, []),
    {Second, Other} = held(Config),
    ok = released(Kept),
    {ok, #{rows := [{Moved}]}, Twice} = minato_query:cached(Once, ?BACKEND, []),
    ok = released(Other),
    ?assertNotEqual(First, Second),
    ?assertEqual(First, Moved),
    ok = minato_conn:close(Twice).

%%----------------------------------------------------------------------
%% max_prepared_statements at zero
%%----------------------------------------------------------------------

-spec a_kept_statement_first_used_on_another_backend_is_refused([{atom(), term()}]) -> ok.
a_kept_statement_first_used_on_another_backend_is_refused(Config) ->
    ok = both_backends_idle(Config),
    Answer = minato_query:cached(connected(Config), ~"SELECT $1::int4", [1]),
    ?assertMatch({error, {pgsql_error, #{code := ~"26000"}}, _Conn}, Answer),
    {error, _Reason, Refused} = Answer,
    ok = minato_conn:close(Refused).

-spec a_kept_statement_lost_to_another_backend_is_parsed_again([{atom(), term()}]) -> ok.
a_kept_statement_lost_to_another_backend_is_parsed_again(Config) ->
    Conn = connected(Config),
    {First, Kept} = held(Config),
    {ok, #{rows := [{Second}]}, Once} = minato_query:cached(Conn, ?BACKEND, []),
    {Second, Other} = held(Config),
    ok = released(Kept),
    {ok, #{rows := [{Moved}]}, Twice} = minato_query:cached(Once, ?BACKEND, []),
    ok = released(Other),
    ?assertNotEqual(First, Second),
    ?assertEqual(First, Moved),
    ok = minato_conn:close(Twice).

-spec a_connection_that_keeps_no_statements_is_answered_by_any_backend([{atom(), term()}]) -> ok.
a_connection_that_keeps_no_statements_is_answered_by_any_backend(Config) ->
    ok = both_backends_idle(Config),
    {ok, Conn} = minato_conn:connect((pooler(Config))#{prepared_statements => 0}),
    {Backends, Read} = answered_by(Conn, lists:seq(1, 10)),
    ?assertEqual(2, length(lists:usort(Backends))),
    ok = minato_conn:close(Read).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

both_backends_idle(Config) ->
    {First, One} = held(Config),
    {Second, Other} = held(Config),
    ?assertNotEqual(First, Second),
    ok = released(One),
    ok = released(Other).

held(Config) ->
    {ok, Open} = minato_txn:open(connected(Config)),
    backend(Open).

released(Conn) ->
    {ok, Committed} = minato_txn:commit(Conn),
    ok = minato_conn:close(Committed).

backend(Conn) ->
    {ok, #{rows := [{Backend}]}, Read} = minato_query:query(Conn, ?BACKEND, []),
    {Backend, Read}.

answered_by(Conn, []) ->
    {[], Conn};
answered_by(Conn, [Turn | Turns]) ->
    {ok, #{rows := [{Backend, Turn}]}, Answered} =
        minato_query:cached(Conn, ~"SELECT pg_backend_pid(), $1::int4", [Turn]),
    {Backends, Read} = answered_by(Answered, Turns),
    {[Backend | Backends], Read}.

connected(Config) ->
    {ok, Conn} = minato_conn:connect(pooler(Config)),
    Conn.

pooled(Config) ->
    (pooler(Config))#{prepared_statements => proplists:get_value(kept, Config)}.

kept(prepared) -> 64;
kept(unprepared) -> 0.

pooler(prepared) ->
    (server())#{port => list_to_integer(env("MINATO_PGBOUNCER_PORT", "56432"))};
pooler(unprepared) ->
    (server())#{port => list_to_integer(env("MINATO_PGBOUNCER_UNPREPARED_PORT", "56433"))};
pooler(Config) ->
    proplists:get_value(pooler, Config).

server() ->
    #{
        host => env("MINATO_PG_HOST", "127.0.0.1"),
        port => list_to_integer(env("MINATO_PG_PORT", "55432")),
        user => list_to_binary(env("MINATO_PG_USER", "minato")),
        password => list_to_binary(env("MINATO_PG_PASSWORD", "minato")),
        database => list_to_binary(env("MINATO_PG_DATABASE", "minato_test")),
        timeout => ?TIMEOUT
    }.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
