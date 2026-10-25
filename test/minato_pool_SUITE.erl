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
-export([checkout_stopped/4]).
-export([
    a_query_runs_through_the_pool/1,
    a_failing_statement_does_not_cost_the_connection/1,
    a_transaction_holds_one_connection/1,
    a_rolled_back_transaction_reports_its_reason/1,
    a_connection_given_back_mid_transaction_is_reset/1,
    a_borrower_that_dies_is_replaced/1,
    a_connection_the_server_ended_is_not_handed_out/1,
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
    a_pool_told_to_wait_waits/1,
    a_connection_nobody_wants_is_closed_down_to_the_floor/1,
    a_pool_that_grew_gives_the_connections_back/1,
    a_setting_does_not_reach_the_next_borrower/1,
    a_session_default_does_not_reach_the_next_borrower/1,
    an_advisory_lock_does_not_reach_the_next_borrower/1,
    a_listen_does_not_reach_the_next_borrower/1,
    a_temporary_table_does_not_reach_the_next_borrower/1,
    a_held_cursor_does_not_reach_the_next_borrower/1,
    a_cached_statement_survives_the_reset/1,
    a_role_does_not_reach_the_next_borrower/1,
    a_search_path_does_not_reach_the_next_borrower/1,
    an_unread_answer_does_not_reach_the_next_borrower/1,
    an_unread_answer_does_not_reach_a_later_borrower/1,
    a_statement_prepared_with_sql_closes_the_connection/1,
    a_refused_reset_is_tried_again_on_another_connection/1,
    a_checkout_that_runs_out_of_time_leaves_nothing_borrowed/1,
    a_checkout_with_no_time_left_leaves_nothing_borrowed/1,
    an_unread_error_does_not_reach_the_next_borrower/1,
    a_forged_reset_does_not_pass_for_the_real_one/1,
    a_connection_given_back_in_a_failed_transaction_is_reset/1,
    a_transaction_left_open_does_not_hold_up_a_checkout/1,
    a_waiter_is_served_after_a_discard_below_the_floor/1,
    a_waiter_past_its_deadline_is_lent_nothing/1,
    an_unread_begin_does_not_reach_the_next_borrower/1,
    a_stale_idle_term_inside_a_transaction_is_not_lent_again/1,
    a_checkout_the_pool_reaches_after_its_caller_left_lends_nothing/1,
    a_connection_given_back_unread_comes_back_idle/1,
    a_connection_given_back_unread_with_another_nonce_is_closed/1
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
        a_connection_the_server_ended_is_not_handed_out,
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
        a_pool_told_to_wait_waits,
        a_connection_nobody_wants_is_closed_down_to_the_floor,
        a_pool_that_grew_gives_the_connections_back,
        a_setting_does_not_reach_the_next_borrower,
        a_session_default_does_not_reach_the_next_borrower,
        an_advisory_lock_does_not_reach_the_next_borrower,
        a_listen_does_not_reach_the_next_borrower,
        a_temporary_table_does_not_reach_the_next_borrower,
        a_held_cursor_does_not_reach_the_next_borrower,
        a_cached_statement_survives_the_reset,
        a_role_does_not_reach_the_next_borrower,
        a_search_path_does_not_reach_the_next_borrower,
        an_unread_answer_does_not_reach_the_next_borrower,
        an_unread_answer_does_not_reach_a_later_borrower,
        a_statement_prepared_with_sql_closes_the_connection,
        a_refused_reset_is_tried_again_on_another_connection,
        a_checkout_that_runs_out_of_time_leaves_nothing_borrowed,
        a_checkout_with_no_time_left_leaves_nothing_borrowed,
        an_unread_error_does_not_reach_the_next_borrower,
        a_forged_reset_does_not_pass_for_the_real_one,
        a_connection_given_back_in_a_failed_transaction_is_reset,
        a_transaction_left_open_does_not_hold_up_a_checkout,
        a_waiter_is_served_after_a_discard_below_the_floor,
        a_waiter_past_its_deadline_is_lent_nothing,
        an_unread_begin_does_not_reach_the_next_borrower,
        a_stale_idle_term_inside_a_transaction_is_not_lent_again,
        a_checkout_the_pool_reaches_after_its_caller_left_lends_nothing,
        a_connection_given_back_unread_comes_back_idle,
        a_connection_given_back_unread_with_another_nonce_is_closed
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
init_per_testcase(a_connection_nobody_wants_is_closed_down_to_the_floor, Config) ->
    Config;
init_per_testcase(a_pool_that_grew_gives_the_connections_back, Config) ->
    Config;
init_per_testcase(a_pool_opens_only_its_floor_before_anybody_asks, Config) ->
    Config;
init_per_testcase(a_pool_grows_when_a_caller_finds_none_free, Config) ->
    Config;
init_per_testcase(a_waiter_is_served_after_a_discard_below_the_floor, Config) ->
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
end_per_testcase(a_connection_nobody_wants_is_closed_down_to_the_floor, _Config) ->
    ok = minato:stop_pool(minato_idle_pool);
end_per_testcase(a_pool_that_grew_gives_the_connections_back, _Config) ->
    ok = minato:stop_pool(minato_grew_pool);
end_per_testcase(a_pool_opens_only_its_floor_before_anybody_asks, _Config) ->
    ok = minato:stop_pool(minato_floor_pool);
end_per_testcase(a_pool_grows_when_a_caller_finds_none_free, _Config) ->
    ok = minato:stop_pool(minato_growth_pool);
end_per_testcase(a_waiter_is_served_after_a_discard_below_the_floor, _Config) ->
    ok = minato:stop_pool(minato_bare_pool);
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

-spec a_connection_given_back_in_a_failed_transaction_is_reset([{atom(), term()}]) -> ok.
a_connection_given_back_in_a_failed_transaction_is_reset(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    {ok, Open} = minato_txn:open(Conn),
    {error, _Reason, Failed} = minato_query:query(Open, ~"SELECT * FROM no_such_table", []),
    ok = minato_pool:checkin(?POOL, Failed),
    {ok, Again} = minato_pool:checkout(?POOL),
    {ok, #{rows := Rows}, Read} = minato_query:query(Again, ~"SELECT 1::int4", []),
    ok = minato_pool:checkin(?POOL, Read),
    ?assertEqual([{1}], Rows),
    ?assertMatch(#{disconnects := 0}, minato:stats(?POOL)).

%% The rollback is the next borrower's to wait for, within its own timeout; a
%% pool that waited for it would hold up every checkout behind the slow one.
-spec a_transaction_left_open_does_not_hold_up_a_checkout([{atom(), term()}]) -> ok.
a_transaction_left_open_does_not_hold_up_a_checkout(_Config) ->
    {ok, Other} = minato_pool:checkout(?POOL),
    {ok, Conn} = minato_pool:checkout(?POOL),
    {ok, Open} = minato_txn:open(Conn),
    {ok, _Result, Written} = insert(Open, ~"a"),
    ok = minato_conn:send(Written, {query, ~"SELECT pg_sleep(2)"}),
    ok = minato_pool:checkin(?POOL, Written),
    Started = erlang:monotonic_time(millisecond),
    Checkout = minato_pool:checkout(?POOL, 300),
    Waited = erlang:monotonic_time(millisecond) - Started,
    _ = [minato_pool:checkin(?POOL, Lent) || {ok, Lent} <- [Checkout]],
    ok = minato_pool:checkin(?POOL, Other),
    ?assertEqual({error, checkout_timeout}, Checkout),
    ?assert(Waited < 1500),
    ?assertMatch(#{timeouts := 1}, minato:stats(?POOL)),
    ?assertEqual([], names()).

-spec a_waiter_is_served_after_a_discard_below_the_floor([{atom(), term()}]) -> ok.
a_waiter_is_served_after_a_discard_below_the_floor(_Config) ->
    {ok, _Pid} = minato:start_pool(minato_bare_pool, #{
        size => 1, min_size => 0, connection => connection()
    }),
    {ok, Conn} = minato_pool:checkout(minato_bare_pool, ?TIMEOUT),
    Test = self(),
    _Waiter = spawn_link(fun() ->
        Test ! {waited, minato_pool:checkout(minato_bare_pool, ?TIMEOUT)}
    end),
    ?assertMatch(#{waiting := 1}, waited_for(minato_bare_pool)),
    ok = minato_pool:discard(minato_bare_pool, Conn),
    Served =
        receive
            {waited, Checkout} -> Checkout
        after 2000 -> error(never_served)
        end,
    ?assertMatch({ok, _}, Served).

%% Stalled for longer than its caller waits for a late answer, the pool must not
%% lend to it when it gets there: the answer would reach nobody.
-spec a_checkout_the_pool_reaches_after_its_caller_left_lends_nothing([{atom(), term()}]) -> ok.
a_checkout_the_pool_reaches_after_its_caller_left_lends_nothing(_Config) ->
    ok = sys:suspend(?POOL),
    _Resumer = spawn_link(fun() ->
        timer:sleep(400),
        sys:resume(?POOL)
    end),
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual({error, checkout_timeout}, minato_pool:checkout(?POOL, 50)),
    ?assert(erlang:monotonic_time(millisecond) - Started < 350),
    ?assertMatch(#{borrowed := 0, idle := 2, timeouts := 1}, minato:stats(?POOL)).

-spec a_waiter_past_its_deadline_is_lent_nothing([{atom(), term()}]) -> ok.
a_waiter_past_its_deadline_is_lent_nothing(_Config) ->
    #{checkouts := Before} = minato_pool:stats(?POOL),
    {ok, First} = minato_pool:checkout(?POOL),
    {ok, Second} = minato_pool:checkout(?POOL),
    Test = self(),
    _Waiter = spawn_link(fun() -> Test ! {waited, minato_pool:checkout(?POOL, 100)} end),
    ?assertMatch(#{waiting := 1}, waited_for(?POOL)),
    ok = sys:suspend(?POOL),
    ok = minato_pool:checkin(?POOL, First),
    timer:sleep(200),
    ok = sys:resume(?POOL),
    Waited =
        receive
            {waited, Checkout} -> Checkout
        after ?TIMEOUT -> error(never_answered)
        end,
    ok = minato_pool:checkin(?POOL, Second),
    ?assertEqual({error, checkout_timeout}, Waited),
    ?assertMatch(#{borrowed := 0, idle := 2}, minato_pool:stats(?POOL)),
    ?assertEqual(Before + 2, maps:get(checkouts, minato_pool:stats(?POOL))).

%% Its status still says idle, so no `ROLLBACK` goes ahead of the reset, and the
%% reset is answered by the `BEGIN` first.
-spec an_unread_begin_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
an_unread_begin_does_not_reach_the_next_borrower(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    ok = minato_conn:send(Conn, {query, ~"BEGIN"}),
    ok = minato_pool:checkin(?POOL, Conn),
    {ok, Next} = minato_pool:checkout(?POOL),
    {ok, _Result, Read} = minato_query:query(Next, ~"SELECT 1", []),
    Status = minato_txn:status(Read),
    ok = minato_pool:checkin(?POOL, Read),
    ?assertEqual(idle, Status).

%% The term given back still says idle, but the session is inside a transaction,
%% so the reset has to roll back on what the server says rather than the term.
-spec a_stale_idle_term_inside_a_transaction_is_not_lent_again([{atom(), term()}]) -> ok.
a_stale_idle_term_inside_a_transaction_is_not_lent_again(_Config) ->
    {ok, Stale} = minato_pool:checkout(?POOL),
    {ok, _Results, Begun} = minato_query:simple(Stale, ~"BEGIN; SET app.leak = 'x'"),
    transaction = minato_txn:status(Begun),
    ok = minato_pool:checkin(?POOL, Stale),
    {ok, Next} = minato_pool:checkout(?POOL),
    {ok, [#{rows := Rows}], Read} =
        minato_query:simple(Next, ~"SELECT current_setting('app.leak', true)"),
    Status = minato_txn:status(Read),
    ok = minato_pool:checkin(?POOL, Read),
    ?assertEqual([{null}], Rows),
    ?assertEqual(idle, Status).

-spec a_connection_given_back_unread_comes_back_idle([{atom(), term()}]) -> ok.
a_connection_given_back_unread_comes_back_idle(_Config) ->
    {ok, Conn, Expected, _Size} = lent_unread(?POOL),
    ok = minato_conn:give_away(Conn, pool_pid(?POOL)),
    ok = gen_server:cast(?POOL, {unlent, self(), Conn, Expected}),
    ?assertMatch(#{borrowed := 0, idle := 2, disconnects := 0}, minato:stats(?POOL)).

-spec a_connection_given_back_unread_with_another_nonce_is_closed([{atom(), term()}]) -> ok.
a_connection_given_back_unread_with_another_nonce_is_closed(_Config) ->
    {ok, Conn, _Expected, _Size} = lent_unread(?POOL),
    ok = minato_conn:give_away(Conn, pool_pid(?POOL)),
    ok = gen_server:cast(?POOL, {unlent, self(), Conn, [{row, ~"0000000000000000"}]}),
    ?assertMatch(#{borrowed := 0, disconnects := 1}, minato:stats(?POOL)).

%% The pool's own answer to a checkout, with the reset still unread, as
%% `minato_pool:checkout/2` gets it before reading the reset.
-spec lent_unread(atom()) -> dynamic().
lent_unread(Pool) ->
    gen_server:call(Pool, {checkout, infinity}).

-spec pool_pid(atom()) -> pid().
pool_pid(Pool) ->
    case whereis(Pool) of
        Pid when is_pid(Pid) -> Pid
    end.

-spec a_setting_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
a_setting_does_not_reach_the_next_borrower(_Config) ->
    Left = left_behind(
        ~"SET statement_timeout = 1234; SELECT set_config('minato.tenant', 'acme', false)",
        ~"SELECT current_setting('statement_timeout'), current_setting('minato.tenant', true)"
    ),
    ?assertMatch([{~"0", Tenant}] when Tenant =/= ~"acme", Left).

-spec a_session_default_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
a_session_default_does_not_reach_the_next_borrower(_Config) ->
    Left = left_behind(
        ~"SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY",
        ~"SELECT current_setting('default_transaction_read_only')"
    ),
    ?assertEqual([{~"off"}], Left).

-spec an_advisory_lock_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
an_advisory_lock_does_not_reach_the_next_borrower(_Config) ->
    Left = left_behind(
        ~"SELECT pg_advisory_lock(424242)",
        ~"SELECT count(*)::int4 FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
    ),
    ?assertEqual([{0}], Left).

-spec a_listen_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
a_listen_does_not_reach_the_next_borrower(_Config) ->
    Left = left_behind(~"LISTEN minato_left_behind", ~"SELECT pg_listening_channels()"),
    ?assertEqual([], Left).

-spec a_temporary_table_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
a_temporary_table_does_not_reach_the_next_borrower(_Config) ->
    Left = left_behind(
        ~"CREATE TEMPORARY TABLE minato_left_behind (id int4)",
        ~"SELECT to_regclass('minato_left_behind')::text"
    ),
    ?assertEqual([{null}], Left).

-spec a_held_cursor_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
a_held_cursor_does_not_reach_the_next_borrower(_Config) ->
    Left = left_behind(
        ~"DECLARE minato_left_behind CURSOR WITH HOLD FOR SELECT 1",
        ~"SELECT name FROM pg_cursors WHERE name <> ''"
    ),
    ?assertEqual([], Left).

-spec a_cached_statement_survives_the_reset([{atom(), term()}]) -> ok.
a_cached_statement_survives_the_reset(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    {ok, _Result, Cached} = minato_query:cached(Conn, ~"SELECT 1 AS minato_cached", []),
    ok = minato_pool:checkin(?POOL, Cached),
    {ok, Again} = minato_pool:checkout(?POOL),
    {ok, #{rows := Rows}, Used} = minato_query:query(
        Again, ~"SELECT count(*)::int4 FROM pg_prepared_statements", []
    ),
    ok = minato_pool:checkin(?POOL, Used),
    ?assertEqual([{1}], Rows).

-spec a_role_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
a_role_does_not_reach_the_next_borrower(_Config) ->
    Left = left_behind(
        ~"SELECT set_config('role', current_user, false)", ~"SELECT current_setting('role')"
    ),
    ?assertEqual([{~"none"}], Left).

-spec a_search_path_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
a_search_path_does_not_reach_the_next_borrower(_Config) ->
    Left = left_behind(~"SET search_path = pg_catalog", ~"SELECT current_setting('search_path')"),
    ?assertMatch([{Path}] when Path =/= ~"pg_catalog", Left).

-spec an_unread_answer_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
an_unread_answer_does_not_reach_the_next_borrower(_Config) ->
    ?assertEqual([{~"own"}], after_unread_answers(0)).

-spec an_unread_answer_does_not_reach_a_later_borrower([{atom(), term()}]) -> ok.
an_unread_answer_does_not_reach_a_later_borrower(_Config) ->
    ?assertEqual([{~"own"}], after_unread_answers(50)).

-spec a_statement_prepared_with_sql_closes_the_connection([{atom(), term()}]) -> ok.
a_statement_prepared_with_sql_closes_the_connection(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    {ok, #{rows := [{Backend}]}, Asked} = minato_query:query(Conn, ~"SELECT pg_backend_pid()", []),
    {ok, _Results, Prepared} = minato_query:simple(
        Asked, ~"PREPARE minato_left_behind AS SELECT 1"
    ),
    ok = minato_pool:checkin(?POOL, Prepared),
    {ok, Next} = minato_pool:checkout(?POOL),
    {ok, #{rows := [{Other}]}, Checked} = minato_query:query(Next, ~"SELECT pg_backend_pid()", []),
    {ok, #{rows := Rows}, Probed} = minato_query:query(
        Checked, ~"SELECT count(*)::int4 FROM pg_prepared_statements WHERE from_sql", []
    ),
    ok = minato_pool:checkin(?POOL, Probed),
    ?assertNotEqual(Backend, Other),
    ?assertEqual([{0}], Rows).

-spec a_refused_reset_is_tried_again_on_another_connection([{atom(), term()}]) -> ok.
a_refused_reset_is_tried_again_on_another_connection(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    ok = left_copying(Conn),
    {ok, Next} = minato_pool:checkout(?POOL),
    {ok, #{rows := Rows}, Read} = minato_query:query(Next, ~"SELECT 1::int4", []),
    ok = minato_pool:checkin(?POOL, Read),
    ?assertEqual([{1}], Rows).

-spec a_checkout_that_runs_out_of_time_leaves_nothing_borrowed([{atom(), term()}]) -> ok.
a_checkout_that_runs_out_of_time_leaves_nothing_borrowed(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    ok = minato_conn:send(Conn, {query, ~"SELECT pg_sleep(0.3)"}),
    ok = minato_pool:checkin(?POOL, Conn),
    ?assertEqual({error, checkout_timeout}, minato_pool:checkout(?POOL, 100)),
    ?assertMatch(#{borrowed := 0}, minato_pool:stats(?POOL)).

-spec a_checkout_with_no_time_left_leaves_nothing_borrowed([{atom(), term()}]) -> ok.
a_checkout_with_no_time_left_leaves_nothing_borrowed(_Config) ->
    Checkouts = [minato_pool:checkout(?POOL, Timeout) || Timeout <- [0, 1], _ <- lists:seq(1, 20)],
    _ = [minato_pool:checkin(?POOL, Conn) || {ok, Conn} <- Checkouts],
    ?assertMatch(#{borrowed := 0}, minato_pool:stats(?POOL)).

%% Both connections are left with an error nobody read, which quotes the value
%% that failed. Neither the checkout nor its telemetry may carry it on.
-spec an_unread_error_does_not_reach_the_next_borrower([{atom(), term()}]) -> ok.
an_unread_error_does_not_reach_the_next_borrower(_Config) ->
    {ok, First} = minato_pool:checkout(?POOL),
    {ok, Second} = minato_pool:checkout(?POOL),
    Failing = {query, ~"SELECT ('alice@example.com:hunter2')::int"},
    ok = minato_conn:send(First, Failing),
    ok = minato_conn:send(Second, Failing),
    ok = minato_pool:checkin(?POOL, First),
    ok = minato_pool:checkin(?POOL, Second),
    ok = telemetry:attach(
        checkout_stopped, [minato, checkout, stop], fun ?MODULE:checkout_stopped/4, self()
    ),
    Checkout =
        try
            minato_pool:checkout(?POOL)
        after
            telemetry:detach(checkout_stopped)
        end,
    Metadata =
        receive
            {checkout_stopped, Seen} -> Seen
        after ?TIMEOUT -> error(no_telemetry)
        end,
    _ = [minato_pool:checkin(?POOL, Conn) || {ok, Conn} <- [Checkout]],
    ?assertMatch({ok, _}, Checkout),
    ?assertEqual(nomatch, binary:match(term_to_binary({Checkout, Metadata}), ~"hunter2")).

%% A borrower that sends something shaped like the reset, unread, and something
%% slow behind it would otherwise have its answers taken for the reset's.
-spec a_forged_reset_does_not_pass_for_the_real_one([{atom(), term()}]) -> ok.
a_forged_reset_does_not_pass_for_the_real_one(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    Forged =
        ~"CLOSE ALL; SET SESSION AUTHORIZATION DEFAULT; RESET ALL; UNLISTEN *; SELECT pg_catalog.pg_advisory_unlock_all(); DISCARD TEMP; DISCARD SEQUENCES; SELECT '00' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_prepared_statements WHERE from_sql)",
    ok = minato_conn:send(Conn, {query, Forged}),
    ok = minato_conn:send(Conn, {query, ~"SELECT pg_sleep(0.2), 'slow'"}),
    ok = minato_pool:checkin(?POOL, Conn),
    {ok, Next} = minato_pool:checkout(?POOL),
    {ok, #{rows := Rows}, Read} = minato_query:query(Next, ~"SELECT 'own'", []),
    ok = minato_pool:checkin(?POOL, Read),
    ?assertEqual([{~"own"}], Rows).

checkout_stopped(_Event, _Measurements, Metadata, Test) ->
    Test ! {checkout_stopped, Metadata},
    ok.

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

-spec a_connection_nobody_wants_is_closed_down_to_the_floor([{atom(), term()}]) -> ok.
a_connection_nobody_wants_is_closed_down_to_the_floor(_Config) ->
    {ok, _Pid} = minato:start_pool(minato_idle_pool, #{
        size => 4, min_size => 4, max_idle => 1, connection => connection()
    }),
    ok = filled(minato_idle_pool, 4, 200),
    ?assertMatch(#{idle := 4}, minato:stats(minato_idle_pool)),
    ok = shrunk(minato_idle_pool, 4, 600),
    ?assertMatch(#{idle := 4}, minato:stats(minato_idle_pool)),
    {ok, Conn} = minato_pool:checkout(minato_idle_pool),
    ok = minato_pool:checkin(minato_idle_pool, Conn),
    ?assertMatch({ok, #{rows := [{1}]}}, minato:query(minato_idle_pool, ~"SELECT 1", [])).

-spec a_pool_that_grew_gives_the_connections_back([{atom(), term()}]) -> ok.
a_pool_that_grew_gives_the_connections_back(_Config) ->
    {ok, _Pid} = minato:start_pool(minato_grew_pool, #{
        size => 4, min_size => 1, max_idle => 100, connection => connection()
    }),
    ok = filled(minato_grew_pool, 1, 200),
    {ok, One} = minato_pool:checkout(minato_grew_pool, ?TIMEOUT),
    {ok, Two} = minato_pool:checkout(minato_grew_pool, ?TIMEOUT),
    {ok, Three} = minato_pool:checkout(minato_grew_pool, ?TIMEOUT),
    ?assertMatch(#{borrowed := 3}, minato:stats(minato_grew_pool)),
    ok = minato_pool:checkin(minato_grew_pool, One),
    ok = minato_pool:checkin(minato_grew_pool, Two),
    ok = minato_pool:checkin(minato_grew_pool, Three),
    ok = settled_at(minato_grew_pool, 1, 150),
    ?assertMatch({ok, #{rows := [{1}]}}, minato:query(minato_grew_pool, ~"SELECT 1", [])).

settled_at(_Pool, _Floor, 0) ->
    {error, never_shrank};
settled_at(Pool, Floor, Attempts) ->
    case minato:stats(Pool) of
        #{idle := Floor, borrowed := 0} ->
            ok;
        _Waiting ->
            timer:sleep(100),
            settled_at(Pool, Floor, Attempts - 1)
    end.

shrunk(_Pool, _Floor, 0) ->
    ok;
shrunk(Pool, Floor, Attempts) ->
    case minato:stats(Pool) of
        #{idle := Idle} when Idle < Floor -> {error, {shrank_below_floor, Idle}};
        _Held ->
            timer:sleep(100),
            shrunk(Pool, Floor, Attempts - 1)
    end.

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

%% What `Probe` finds on the connection the next borrower gets, after `Setup` ran
%% on it and it went back to the pool. The idle connections are lent most recent
%% first, so the next borrower gets the same backend, which is asserted rather
%% than assumed.
left_behind(Setup, Probe) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    {ok, #{rows := [{Backend}]}, Asked} = minato_query:query(Conn, ~"SELECT pg_backend_pid()", []),
    {ok, _Results, Set} = minato_query:simple(Asked, Setup),
    ok = minato_pool:checkin(?POOL, Set),
    {ok, Next} = minato_pool:checkout(?POOL),
    {ok, #{rows := [{Same}]}, Checked} = minato_query:query(Next, ~"SELECT pg_backend_pid()", []),
    {ok, #{rows := Rows}, Probed} = minato_query:query(Checked, Probe, []),
    ok = minato_pool:checkin(?POOL, Probed),
    ?assertEqual(Backend, Same),
    Rows.

%% What the next borrower's own query returns after the last one sent two queries
%% without reading their answers and gave the connection back.
after_unread_answers(Wait) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    ok = minato_conn:send(Conn, {query, ~"SELECT 'fast'"}),
    ok = minato_conn:send(Conn, {query, ~"SELECT pg_sleep(0.2), 'slow'"}),
    ok = minato_pool:checkin(?POOL, Conn),
    timer:sleep(Wait),
    {ok, Next} = minato_pool:checkout(?POOL),
    {ok, #{rows := Rows}, Read} = minato_query:query(Next, ~"SELECT 'own'", []),
    ok = minato_pool:checkin(?POOL, Read),
    Rows.

%% Gives a connection back in the middle of a COPY, which the server answers the
%% reset on with an error.
left_copying(Conn) ->
    ok = minato_conn:send(Conn, {query, ~"COPY minato_pool_rows (name) FROM STDIN"}),
    minato_pool:checkin(?POOL, Conn).

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

-doc """
A pooled connection can die where nobody is holding it, and nothing says so.

Ending every backend from another session is what a restart or a failover
looks like from the pool's side: connections that are idle, healthy as far as
anyone knew, and gone. Before the pool asked, each one was handed out once and
cost a caller a statement that never reached a server.
""".
-spec a_connection_the_server_ended_is_not_handed_out([{atom(), term()}]) -> ok.
a_connection_the_server_ended_is_not_handed_out(_Config) ->
    ok = ended_every_other_backend(),
    Answers = [minato:query(?POOL, ~"SELECT 1", []) || _Each <- lists:seq(1, 6)],
    ?assertEqual([{ok, one_row} || _Each <- lists:seq(1, 6)], [shaped(A) || A <- Answers]).

shaped({ok, #{rows := [{1}]}}) -> {ok, one_row};
shaped(Other) -> Other.

ended_every_other_backend() ->
    {ok, Admin} = minato_conn:connect(connection()),
    SQL =
        ~"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()",
    {ok, _Result, Used} = minato_query:query(Admin, SQL, []),
    ok = minato_conn:close(Used),
    timer:sleep(200).

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
