-module(minato_pool_SUITE).
-moduledoc """
The pool, against a real PostgreSQL.

What is worth proving here is not that a query runs - `minato_query_SUITE` does
that - but what the pool does with connections at the edges: a borrower that
dies, a checkout with nothing free, a connection given back mid-transaction, a
pool started before its database answers.

The last one needs a server that is not there, so it points a pool at a port
nothing is listening on and requires the pool to be alive and waiting rather
than dead.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    a_query_runs_through_the_pool/1,
    a_failing_statement_does_not_cost_the_connection/1,
    a_transaction_holds_one_connection/1,
    a_rolled_back_transaction_reports_its_reason/1,
    a_connection_given_back_mid_transaction_is_reset/1,
    a_borrower_that_dies_is_replaced/1,
    a_checkout_with_nothing_free_waits/1,
    a_checkout_that_waits_too_long_gives_up/1,
    a_pool_with_no_server_stays_up/1,
    the_stats_count_what_happened/1,
    a_connection_can_be_handed_to_another_process/1,
    the_process_it_was_handed_to_is_the_one_watched/1,
    a_connection_nobody_borrowed_cannot_be_handed_on/1,
    a_connection_older_than_max_age_is_retired/1,
    a_healthy_pool_answers_ok/1,
    a_pool_with_no_server_is_not_healthy/1,
    a_cancelled_statement_does_not_cost_a_connection/1,
    a_pool_opens_only_its_floor_before_anybody_asks/1,
    a_pool_grows_when_a_caller_finds_none_free/1,
    a_pool_that_cannot_connect_fails_a_checkout_at_once/1,
    a_pool_told_to_wait_waits/1
]).

-define(TIMEOUT, 10000).
-define(POOL, minato_test_pool).

-spec all() -> [atom()].
all() ->
    [
        a_query_runs_through_the_pool,
        a_failing_statement_does_not_cost_the_connection,
        a_transaction_holds_one_connection,
        a_rolled_back_transaction_reports_its_reason,
        a_connection_given_back_mid_transaction_is_reset,
        a_borrower_that_dies_is_replaced,
        a_checkout_with_nothing_free_waits,
        a_checkout_that_waits_too_long_gives_up,
        a_pool_with_no_server_stays_up,
        the_stats_count_what_happened,
        a_connection_can_be_handed_to_another_process,
        the_process_it_was_handed_to_is_the_one_watched,
        a_connection_nobody_borrowed_cannot_be_handed_on,
        a_connection_older_than_max_age_is_retired,
        a_healthy_pool_answers_ok,
        a_pool_with_no_server_is_not_healthy,
        a_cancelled_statement_does_not_cost_a_connection,
        a_pool_opens_only_its_floor_before_anybody_asks,
        a_pool_grows_when_a_caller_finds_none_free,
        a_pool_that_cannot_connect_fails_a_checkout_at_once,
        a_pool_told_to_wait_waits
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(connection()) of
        {ok, Conn} ->
            {ok, _Results, Ready} = minato_query:simple(Conn, schema()),
            ok = minato_conn:close(Ready),
            {ok, _Started} = application:ensure_all_started(minato),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok = application:stop(minato).

-spec init_per_testcase(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_testcase(a_pool_with_no_server_stays_up, Config) ->
    Config;
init_per_testcase(a_pool_with_no_server_is_not_healthy, Config) ->
    Config;
init_per_testcase(a_pool_that_cannot_connect_fails_a_checkout_at_once, Config) ->
    Config;
init_per_testcase(a_pool_told_to_wait_waits, Config) ->
    Config;
init_per_testcase(a_pool_opens_only_its_floor_before_anybody_asks, Config) ->
    Config;
init_per_testcase(a_pool_grows_when_a_caller_finds_none_free, Config) ->
    Config;
init_per_testcase(a_connection_older_than_max_age_is_retired, Config) ->
    {ok, _Pid} = minato:start_pool(?POOL, #{
        size => 1, min_size => 1, max_age => 1, connection => connection()
    }),
    ok = filled(?POOL, 1, 100),
    Config;
init_per_testcase(_Case, Config) ->
    {ok, _Pid} = minato:start_pool(?POOL, #{size => 2, min_size => 2, connection => connection()}),
    ok = filled(?POOL, 2, 100),
    {ok, _Results} = minato:simple(?POOL, ~"TRUNCATE minato_pool_rows"),
    Config.

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(a_pool_with_no_server_stays_up, _Config) ->
    ok;
end_per_testcase(a_pool_with_no_server_is_not_healthy, _Config) ->
    ok;
end_per_testcase(a_pool_that_cannot_connect_fails_a_checkout_at_once, _Config) ->
    ok;
end_per_testcase(a_pool_told_to_wait_waits, _Config) ->
    ok;
end_per_testcase(a_pool_opens_only_its_floor_before_anybody_asks, _Config) ->
    ok = minato:stop_pool(minato_floor_pool);
end_per_testcase(a_pool_grows_when_a_caller_finds_none_free, _Config) ->
    ok = minato:stop_pool(minato_growth_pool);
end_per_testcase(_Case, _Config) ->
    ok = minato:stop_pool(?POOL).

-spec a_query_runs_through_the_pool([{atom(), term()}]) -> ok.
a_query_runs_through_the_pool(_Config) ->
    ?assertMatch({ok, #{rows := [{42}]}}, minato:query(?POOL, ~"SELECT $1::int4", [42])).

-spec a_failing_statement_does_not_cost_the_connection([{atom(), term()}]) -> ok.
a_failing_statement_does_not_cost_the_connection(_Config) ->
    Failed = minato:query(?POOL, ~"SELECT * FROM no_such_table", []),
    ?assertMatch({error, {pgsql_error, #{code := ~"42P01"}}}, Failed),
    ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])),
    ?assertMatch(#{disconnects := 0}, minato:stats(?POOL)).

-spec a_transaction_holds_one_connection([{atom(), term()}]) -> ok.
a_transaction_holds_one_connection(_Config) ->
    Written = minato:transaction(?POOL, fun(Conn) ->
        {ok, _Result, One} = insert(Conn, ~"a"),
        {ok, _Second, Two} = insert(One, ~"b"),
        {ok, both, Two}
    end),
    ?assertEqual({ok, both}, Written),
    ?assertEqual([~"a", ~"b"], names()).

-spec a_rolled_back_transaction_reports_its_reason([{atom(), term()}]) -> ok.
a_rolled_back_transaction_reports_its_reason(_Config) ->
    Answer = minato:transaction(?POOL, fun(Conn) ->
        {ok, _Result, Written} = insert(Conn, ~"a"),
        {rollback, changed_my_mind, Written}
    end),
    ?assertEqual({rollback, changed_my_mind}, Answer),
    ?assertEqual([], names()).

-spec a_connection_given_back_mid_transaction_is_reset([{atom(), term()}]) -> ok.
a_connection_given_back_mid_transaction_is_reset(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    {ok, Open} = minato_txn:open(Conn),
    {ok, _Result, Written} = insert(Open, ~"a"),
    ok = minato_pool:checkin(?POOL, Written),
    ok = filled(?POOL, 2, 100),
    ?assertEqual([], names()),
    {ok, Again} = minato_pool:checkout(?POOL),
    ?assertEqual(idle, minato_txn:status(Again)),
    ok = minato_pool:checkin(?POOL, Again).

-spec a_borrower_that_dies_is_replaced([{atom(), term()}]) -> ok.
a_borrower_that_dies_is_replaced(_Config) ->
    Test = self(),
    Borrower = spawn(fun() ->
        {ok, _Conn} = minato_pool:checkout(?POOL),
        Test ! borrowed,
        receive
            never -> ok
        end
    end),
    receive
        borrowed -> ok
    after ?TIMEOUT -> error(timeout)
    end,
    true = exit(Borrower, kill),
    ok = filled(?POOL, 2, 200),
    ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])).

-spec a_checkout_with_nothing_free_waits([{atom(), term()}]) -> ok.
a_checkout_with_nothing_free_waits(_Config) ->
    {ok, First} = minato_pool:checkout(?POOL),
    {ok, Second} = minato_pool:checkout(?POOL),
    Test = self(),
    _Waiter = spawn_link(fun() ->
        {ok, Conn} = minato_pool:checkout(?POOL, ?TIMEOUT),
        Test ! waited,
        minato_pool:checkin(?POOL, Conn)
    end),
    ?assertMatch(#{waiting := 1}, waited_for(?POOL)),
    ok = minato_pool:checkin(?POOL, First),
    receive
        waited -> ok
    after ?TIMEOUT -> error(never_served)
    end,
    ok = minato_pool:checkin(?POOL, Second).

-spec a_checkout_that_waits_too_long_gives_up([{atom(), term()}]) -> ok.
a_checkout_that_waits_too_long_gives_up(_Config) ->
    {ok, First} = minato_pool:checkout(?POOL),
    {ok, Second} = minato_pool:checkout(?POOL),
    ?assertEqual({error, checkout_timeout}, minato_pool:checkout(?POOL, 100)),
    ?assertMatch(#{timeouts := 1, waiting := 0}, minato:stats(?POOL)),
    ok = minato_pool:checkin(?POOL, First),
    ok = minato_pool:checkin(?POOL, Second).

-spec a_pool_with_no_server_stays_up([{atom(), term()}]) -> ok.
a_pool_with_no_server_stays_up(_Config) ->
    Nowhere = maps:merge(connection(), #{port => 1, connect_timeout => 100}),
    {ok, Pid} = minato:start_pool(minato_nowhere_pool, #{size => 1, connection => Nowhere}),
    ?assertEqual({error, checkout_timeout}, minato_pool:checkout(minato_nowhere_pool, 200)),
    ?assert(is_pid(Pid) andalso is_process_alive(Pid)),
    ?assertMatch(#{idle := 0}, minato:stats(minato_nowhere_pool)),
    ok = minato:stop_pool(minato_nowhere_pool).

-spec the_stats_count_what_happened([{atom(), term()}]) -> ok.
the_stats_count_what_happened(_Config) ->
    {ok, _Result} = minato:query(?POOL, ~"SELECT 1", []),
    ?assertMatch(
        #{size := 2, borrowed := 0, checkouts := Count} when Count >= 1, minato:stats(?POOL)
    ).

-spec a_connection_can_be_handed_to_another_process([{atom(), term()}]) -> ok.
a_connection_can_be_handed_to_another_process(_Config) ->
    Test = self(),
    Owner = spawn_link(fun() ->
        receive
            {conn, Conn} ->
                {ok, #{rows := [{7}]}, Used} = minato_query:query(Conn, ~"SELECT 7", []),
                ok = minato_pool:checkin(?POOL, Used),
                Test ! used
        end
    end),
    {ok, Conn} = minato_pool:checkout(?POOL),
    ok = minato:give_away(?POOL, Conn, Owner),
    Owner ! {conn, Conn},
    receive
        used -> ok
    after ?TIMEOUT -> error(never_used)
    end,
    ok = settled(2, 200),
    ?assertMatch(#{borrowed := 0, disconnects := 0}, minato:stats(?POOL)).

-spec the_process_it_was_handed_to_is_the_one_watched([{atom(), term()}]) -> ok.
the_process_it_was_handed_to_is_the_one_watched(_Config) ->
    Test = self(),
    Owner = spawn(fun() ->
        receive
            {conn, _Conn} -> Test ! holding
        end,
        receive
            never -> ok
        end
    end),
    Borrower = spawn(fun() ->
        {ok, Conn} = minato_pool:checkout(?POOL, ?TIMEOUT),
        ok = minato:give_away(?POOL, Conn, Owner),
        Owner ! {conn, Conn}
    end),
    receive
        holding -> ok
    after ?TIMEOUT -> error(never_handed_over)
    end,
    ok = buried([Borrower], 200),
    ?assertMatch(#{borrowed := 1}, minato:stats(?POOL)),
    true = exit(Owner, kill),
    ok = settled(2, 500),
    ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])).

-spec a_connection_nobody_borrowed_cannot_be_handed_on([{atom(), term()}]) -> ok.
a_connection_nobody_borrowed_cannot_be_handed_on(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    ok = minato_pool:checkin(?POOL, Conn),
    ?assertEqual({error, not_borrowed}, minato:give_away(?POOL, Conn, self())).

-spec a_connection_older_than_max_age_is_retired([{atom(), term()}]) -> ok.
a_connection_older_than_max_age_is_retired(_Config) ->
    {ok, First} = minato_pool:checkout(?POOL),
    timer:sleep(5),
    ok = minato_pool:checkin(?POOL, First),
    ok = settled(1, 200),
    ?assertMatch(#{retired := Count, disconnects := 0} when Count >= 1, minato:stats(?POOL)),
    ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])).

-spec a_healthy_pool_answers_ok([{atom(), term()}]) -> ok.
a_healthy_pool_answers_ok(_Config) ->
    ?assertEqual(ok, minato:health(?POOL)),
    ?assertMatch(#{borrowed := 0}, minato:stats(?POOL)).

-spec a_pool_with_no_server_is_not_healthy([{atom(), term()}]) -> ok.
a_pool_with_no_server_is_not_healthy(_Config) ->
    Nowhere = maps:merge(connection(), #{port => 1, connect_timeout => 100}),
    {ok, _Pid} = minato:start_pool(minato_unhealthy_pool, #{size => 1, connection => Nowhere}),
    ?assertEqual({error, checkout_timeout}, minato:health(minato_unhealthy_pool, 200)),
    ok = minato:stop_pool(minato_unhealthy_pool).

-spec a_cancelled_statement_does_not_cost_a_connection([{atom(), term()}]) -> ok.
a_cancelled_statement_does_not_cost_a_connection(_Config) ->
    #{disconnects := Before} = minato:stats(?POOL),
    Opts = #{timeout => 300},
    Answer = minato:query(?POOL, ~"SELECT pg_sleep(30)", [], Opts),
    ?assertMatch({error, {pgsql_error, #{code := ~"57014"}}}, Answer),
    ok = settled(2, 200),
    ?assertMatch(#{disconnects := Before, borrowed := 0}, minato:stats(?POOL)),
    ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])).

-spec a_pool_opens_only_its_floor_before_anybody_asks([{atom(), term()}]) -> ok.
a_pool_opens_only_its_floor_before_anybody_asks(_Config) ->
    {ok, _Pid} = minato:start_pool(minato_floor_pool, #{
        size => 8, min_size => 2, connection => connection()
    }),
    ok = filled(minato_floor_pool, 2, 200),
    timer:sleep(100),
    ?assertMatch(#{idle := 2, size := 8}, minato:stats(minato_floor_pool)).

-spec a_pool_grows_when_a_caller_finds_none_free([{atom(), term()}]) -> ok.
a_pool_grows_when_a_caller_finds_none_free(_Config) ->
    {ok, _Pid} = minato:start_pool(minato_growth_pool, #{
        size => 4, min_size => 1, connection => connection()
    }),
    ok = filled(minato_growth_pool, 1, 200),
    {ok, First} = minato_pool:checkout(minato_growth_pool),
    {ok, Second} = minato_pool:checkout(minato_growth_pool, ?TIMEOUT),
    ?assertMatch(#{borrowed := 2}, minato:stats(minato_growth_pool)),
    ok = minato_pool:checkin(minato_growth_pool, First),
    ok = minato_pool:checkin(minato_growth_pool, Second).

-spec a_pool_that_cannot_connect_fails_a_checkout_at_once([{atom(), term()}]) -> ok.
a_pool_that_cannot_connect_fails_a_checkout_at_once(_Config) ->
    Nowhere = maps:merge(connection(), #{port => 1, connect_timeout => 100}),
    {ok, _Pid} = minato:start_pool(minato_gone_pool, #{size => 1, connection => Nowhere}),
    ok = refused(minato_gone_pool, 200),
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual({error, disconnected}, minato_pool:checkout(minato_gone_pool, ?TIMEOUT)),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
    ok = minato:stop_pool(minato_gone_pool).

-spec a_pool_told_to_wait_waits([{atom(), term()}]) -> ok.
a_pool_told_to_wait_waits(_Config) ->
    Nowhere = maps:merge(connection(), #{port => 1, connect_timeout => 100}),
    {ok, _Pid} = minato:start_pool(minato_patient_pool, #{
        size => 1, disconnected => wait, connection => Nowhere
    }),
    ok = refused(minato_patient_pool, 200),
    ?assertEqual({error, checkout_timeout}, minato_pool:checkout(minato_patient_pool, 200)),
    ok = minato:stop_pool(minato_patient_pool).

refused(_Pool, 0) ->
    {error, never_failed};
refused(Pool, Attempts) ->
    case minato:stats(Pool) of
        #{disconnects := Failures} when Failures > 0 -> ok;
        _NotYet ->
            timer:sleep(20),
            refused(Pool, Attempts - 1)
    end.

%%----------------------------------------------------------------------
%% Waiting for the pool to be ready
%%----------------------------------------------------------------------

settled(Size, Attempts) ->
    filled(?POOL, Size, Attempts).

buried([], _Attempts) ->
    ok;
buried(_Pids, 0) ->
    {error, still_alive};
buried(Pids, Attempts) ->
    case [Pid || Pid <- Pids, is_process_alive(Pid)] of
        [] ->
            ok;
        Alive ->
            timer:sleep(20),
            buried(Alive, Attempts - 1)
    end.

filled(_Pool, _Size, 0) ->
    {error, never_filled};
filled(Pool, Size, Attempts) ->
    case minato_pool:stats(Pool) of
        #{idle := Idle} when Idle >= Size -> ok;
        _Filling ->
            timer:sleep(20),
            filled(Pool, Size, Attempts - 1)
    end.

waited_for(Pool) ->
    waited_for(Pool, 100).

waited_for(Pool, 0) ->
    minato_pool:stats(Pool);
waited_for(Pool, Attempts) ->
    case minato_pool:stats(Pool) of
        #{waiting := Waiting} = Stats when Waiting > 0 -> Stats;
        _None ->
            timer:sleep(20),
            waited_for(Pool, Attempts - 1)
    end.

insert(Conn, Name) ->
    minato_query:query(Conn, ~"INSERT INTO minato_pool_rows (name) VALUES ($1)", [Name]).

names() ->
    {ok, #{rows := Rows}} = minato:query(
        ?POOL, ~"SELECT name FROM minato_pool_rows ORDER BY name", []
    ),
    [Name || {Name} <- Rows].

schema() ->
    ~"""
    DROP TABLE IF EXISTS minato_pool_rows;
    CREATE TABLE minato_pool_rows (name text PRIMARY KEY)
    """.

connection() ->
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
