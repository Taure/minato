-module(minato_cache_SUITE).
-moduledoc """
The per-connection statement cache, against a real PostgreSQL.

A cache is only worth having if it is invisible: the same answers as the
uncached path, and never a name the server has already seen. Both are things a
server has to be asked about, so this suite asks it - `pg_prepared_statements`
lists exactly what a session has parsed, which is the only honest way to check
what a client kept.

The case that decides whether this is safe to turn on by default is the schema
change. A table altered underneath a prepared statement makes PostgreSQL refuse
it with `0A000`, and a client that passes that back has turned a working
application into a broken one at the moment somebody ran a migration.

The session doing the asking is one of the sessions being asked about, so the
statement that reads `pg_prepared_statements` is itself in the answer. Two
parsed statements after three calls of one query is the point being made.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    the_same_sql_is_parsed_once/1,
    different_sql_gets_different_names/1,
    a_cached_statement_answers_like_an_uncached_one/1,
    a_schema_change_under_a_cached_plan_is_recovered/1,
    a_deallocated_statement_is_parsed_again/1,
    a_statement_is_kept_when_its_first_run_fails/1,
    a_statement_that_does_not_parse_leaves_the_connection_in_step/1,
    a_statement_that_does_not_parse_fails_its_transaction_and_no_more/1,
    a_plan_that_changed_in_a_transaction_is_returned_as_the_server_put_it/1,
    a_value_for_what_a_column_has_become_is_accepted/1,
    a_value_for_what_a_column_was_is_refused_as_an_unkept_statement_would/1,
    a_statement_the_server_refuses_over_its_old_types_is_parsed_again/1,
    a_statement_refused_over_its_old_types_in_a_transaction_recovers_after_it/1,
    a_value_that_does_not_fit_a_kept_statement_leaves_a_transaction_open/1,
    a_session_that_discarded_everything_parses_again/1,
    a_statement_deallocated_in_a_transaction_fails_it/1,
    a_full_cache_falls_back_to_unnamed/1,
    caching_can_be_turned_off/1,
    a_pool_query_parses_each_statement_once/1,
    two_connections_never_claim_the_same_name/1
]).

-define(TIMEOUT, 15000).
-define(POOL, minato_cache_pool).

-spec all() -> [atom()].
all() ->
    [
        the_same_sql_is_parsed_once,
        different_sql_gets_different_names,
        a_cached_statement_answers_like_an_uncached_one,
        a_schema_change_under_a_cached_plan_is_recovered,
        a_deallocated_statement_is_parsed_again,
        a_statement_is_kept_when_its_first_run_fails,
        a_statement_that_does_not_parse_leaves_the_connection_in_step,
        a_statement_that_does_not_parse_fails_its_transaction_and_no_more,
        a_plan_that_changed_in_a_transaction_is_returned_as_the_server_put_it,
        a_value_for_what_a_column_has_become_is_accepted,
        a_value_for_what_a_column_was_is_refused_as_an_unkept_statement_would,
        a_statement_the_server_refuses_over_its_old_types_is_parsed_again,
        a_statement_refused_over_its_old_types_in_a_transaction_recovers_after_it,
        a_value_that_does_not_fit_a_kept_statement_leaves_a_transaction_open,
        a_session_that_discarded_everything_parses_again,
        a_statement_deallocated_in_a_transaction_fails_it,
        a_full_cache_falls_back_to_unnamed,
        caching_can_be_turned_off,
        a_pool_query_parses_each_statement_once,
        two_connections_never_claim_the_same_name
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(connection(#{})) of
        {ok, Conn} ->
            ok = minato_conn:close(Conn),
            {ok, _Started} = application:ensure_all_started(minato),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok = application:stop(minato).

-spec init_per_testcase(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_testcase(a_pool_query_parses_each_statement_once, Config) ->
    {ok, _Pid} = minato:start_pool(?POOL, #{size => 1, connection => connection(#{})}),
    Config;
init_per_testcase(_Case, Config) ->
    Config.

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(a_pool_query_parses_each_statement_once, _Config) ->
    ok = minato:stop_pool(?POOL);
end_per_testcase(_Case, _Config) ->
    ok.

-spec the_same_sql_is_parsed_once([{atom(), term()}]) -> ok.
the_same_sql_is_parsed_once(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    Sql = ~"SELECT $1::int4",
    {ok, #{rows := [{1}]}, First} = minato_query:cached(Conn, Sql, [1]),
    {ok, #{rows := [{2}]}, Second} = minato_query:cached(First, Sql, [2]),
    {ok, #{rows := [{3}]}, Third} = minato_query:cached(Second, Sql, [3]),
    ?assertEqual([~"0"], counters(Third)),
    ?assertEqual({1, 64}, minato_conn:statements(Third)),
    ok = minato_conn:close(Third).

-spec different_sql_gets_different_names([{atom(), term()}]) -> ok.
different_sql_gets_different_names(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    {ok, _One, First} = minato_query:cached(Conn, ~"SELECT 1", []),
    {ok, _Two, Second} = minato_query:cached(First, ~"SELECT 2", []),
    ?assertEqual([~"0", ~"1"], counters(Second)),
    ok = minato_conn:close(Second).

%% Taure/minato#40. A counter alone is unique within one connection, which is
%% enough only while one connection means one backend. Behind a transaction
%% pooler it does not: many connections share few backends, so two of them
%% counting from zero hand the same backend `minato_30` twice and the second is
%% refused with 42P05. There is no pooler in this suite, so the property to pin
%% is the one that makes a pooler safe - two connections, same SQL, same
%% position in each one's sequence, and still different names on the wire.
-spec two_connections_never_claim_the_same_name([{atom(), term()}]) -> ok.
two_connections_never_claim_the_same_name(_Config) ->
    Sql = ~"SELECT $1::int4",
    {ok, A0} = minato_conn:connect(connection(#{})),
    {ok, B0} = minato_conn:connect(connection(#{})),
    {ok, _, A} = minato_query:cached(A0, Sql, [1]),
    {ok, _, B} = minato_query:cached(B0, Sql, [1]),

    [NameA] = parsed(A),
    [NameB] = parsed(B),
    ?assertEqual([~"0"], counters(A)),
    ?assertEqual([~"0"], counters(B)),
    ?assertNotEqual(NameA, NameB),

    ok = minato_conn:close(A),
    ok = minato_conn:close(B).

-spec a_cached_statement_answers_like_an_uncached_one([{atom(), term()}]) -> ok.
a_cached_statement_answers_like_an_uncached_one(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    Sql = ~"SELECT $1::text AS word, $2::int8 * 2 AS doubled",
    {ok, Direct, First} = minato_query:query(Conn, Sql, [~"a", 21]),
    {ok, Once, Second} = minato_query:cached(First, Sql, [~"a", 21]),
    {ok, Twice, Third} = minato_query:cached(Second, Sql, [~"a", 21]),
    ok = minato_conn:close(Third),
    ?assertEqual(Direct, Once),
    ?assertEqual(Direct, Twice).

-spec a_schema_change_under_a_cached_plan_is_recovered([{atom(), term()}]) -> ok.
a_schema_change_under_a_cached_plan_is_recovered(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    Create = ~"DROP TABLE IF EXISTS minato_cache; CREATE TABLE minato_cache (a int4)",
    {ok, _Made, Made} = minato_query:simple(Conn, Create),
    Sql = ~"SELECT * FROM minato_cache",
    {ok, _Empty, Cached} = minato_query:cached(Made, Sql, []),
    {ok, _Filled, Filled} = minato_query:simple(
        Cached, ~"INSERT INTO minato_cache VALUES (1); ALTER TABLE minato_cache ADD b int4"
    ),
    {ok, #{rows := Rows}, Recovered} = minato_query:cached(Filled, Sql, []),
    ?assertEqual([{1, null}], Rows),
    {ok, _Dropped, Dropped} = minato_query:simple(Recovered, ~"DROP TABLE minato_cache"),
    ok = minato_conn:close(Dropped).

-spec a_deallocated_statement_is_parsed_again([{atom(), term()}]) -> ok.
a_deallocated_statement_is_parsed_again(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    Sql = ~"SELECT $1::int4",
    {ok, _First, Cached} = minato_query:cached(Conn, Sql, [1]),
    {ok, _Gone, Deallocated} = minato_query:simple(Cached, ~"DEALLOCATE ALL"),
    {ok, #{rows := Rows}, Again} = minato_query:cached(Deallocated, Sql, [2]),
    ok = minato_conn:close(Again),
    ?assertEqual([{2}], Rows).

%% Parsing again inside the transaction the error aborted could only fail with
%% 25P02 and hide what went wrong.
-spec a_statement_deallocated_in_a_transaction_fails_it([{atom(), term()}]) -> ok.
a_statement_deallocated_in_a_transaction_fails_it(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    Sql = ~"SELECT $1::int4",
    {ok, _First, Cached} = minato_query:cached(Conn, Sql, [1]),
    {ok, Open} = minato_txn:open(Cached),
    {ok, _Gone, Deallocated} = minato_query:simple(Open, ~"DEALLOCATE ALL"),
    Failed = minato_query:cached(Deallocated, Sql, [2]),
    {error, _Reason, Aborted} = Failed,
    {ok, RolledBack} = minato_txn:rollback(Aborted),
    {ok, #{rows := Rows}, Again} = minato_query:cached(RolledBack, Sql, [3]),
    ok = minato_conn:close(Again),
    ?assertMatch({error, {pgsql_error, #{code := ~"26000"}}, _}, Failed),
    ?assertEqual([{3}], Rows).

%% A statement the server has parsed stays parsed whatever becomes of the
%% exchange it was parsed in, so one that failed to run is still worth keeping.
-spec a_statement_is_kept_when_its_first_run_fails([{atom(), term()}]) -> ok.
a_statement_is_kept_when_its_first_run_fails(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    Sql = ~"SELECT 10 / $1::int4",
    {error, {pgsql_error, #{code := Code}}, Kept} = minato_query:cached(Conn, Sql, [0]),
    ?assertEqual(~"22012", Code),
    ?assertEqual({1, 64}, minato_conn:statements(Kept)),
    ?assertEqual([~"0"], counters(Kept)),
    {ok, #{rows := Rows}, Again} = minato_query:cached(Kept, Sql, [5]),
    ?assertEqual([{2}], Rows),
    ?assertEqual([~"0"], counters(Again)),
    ok = minato_conn:close(Again).

-spec a_statement_that_does_not_parse_leaves_the_connection_in_step([{atom(), term()}]) -> ok.
a_statement_that_does_not_parse_leaves_the_connection_in_step(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    {error, {pgsql_error, #{code := Code}}, Refused} =
        minato_query:cached(Conn, ~"SELECT FROM WHERE", []),
    ?assertEqual(~"42601", Code),
    ?assertEqual(idle, minato_conn:transaction_status(Refused)),
    ?assertEqual({0, 64}, minato_conn:statements(Refused)),
    {ok, #{rows := Rows}, Next} = minato_query:cached(Refused, ~"SELECT $1::int4", [7]),
    ?assertEqual([{7}], Rows),
    ok = minato_conn:close(Next).

-spec a_statement_that_does_not_parse_fails_its_transaction_and_no_more([{atom(), term()}]) ->
    ok.
a_statement_that_does_not_parse_fails_its_transaction_and_no_more(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    {ok, Open} = minato_txn:open(Conn),
    {error, {pgsql_error, #{code := Code}}, Refused} =
        minato_query:cached(Open, ~"SELECT FROM WHERE", []),
    ?assertEqual(~"42601", Code),
    ?assertEqual(failed, minato_conn:transaction_status(Refused)),
    {error, {pgsql_error, #{code := Aborted}}, Still} =
        minato_query:cached(Refused, ~"SELECT 1", []),
    ?assertEqual(~"25P02", Aborted),
    {ok, RolledBack} = minato_txn:rollback(Still),
    {ok, #{rows := Rows}, Next} = minato_query:cached(RolledBack, ~"SELECT 1", []),
    ?assertEqual([{1}], Rows),
    ok = minato_conn:close(Next).

%% Parsing again inside the transaction the error aborted could only fail with
%% 25P02 and hide what went wrong. The statement is dropped instead, so the
%% next use after the rollback parses it as the table now is.
-spec a_plan_that_changed_in_a_transaction_is_returned_as_the_server_put_it(
    [{atom(), term()}]
) -> ok.
a_plan_that_changed_in_a_transaction_is_returned_as_the_server_put_it(_Config) ->
    Sql = ~"SELECT * FROM minato_cache",
    Cached = kept(~"a int4", Sql, []),
    {ok, _Altered, Open} = minato_query:simple(
        Cached, ~"BEGIN; INSERT INTO minato_cache VALUES (1); ALTER TABLE minato_cache ADD b int4"
    ),
    {error, {pgsql_error, #{code := Code}}, Aborted} = minato_query:cached(Open, Sql, []),
    ?assertEqual(~"0A000", Code),
    ?assertEqual(failed, minato_conn:transaction_status(Aborted)),
    ?assertEqual({0, 64}, minato_conn:statements(Aborted)),
    {ok, RolledBack} = minato_txn:rollback(Aborted),
    ?assertEqual([], parsed(RolledBack)),
    {ok, #{rows := Rows}, Again} = minato_query:cached(RolledBack, Sql, []),
    ?assertEqual([], Rows),
    ok = dropped(Again).

%% The statement was parsed when the column was an integer, and the types kept
%% with it are what a value is encoded as. A value that is right for the table
%% as it now is must not be refused over what the table was.
-spec a_value_for_what_a_column_has_become_is_accepted([{atom(), term()}]) -> ok.
a_value_for_what_a_column_has_become_is_accepted(_Config) ->
    Sql = ~"SELECT b FROM minato_cache WHERE a = $1",
    Cached = kept(~"a int4, b text", Sql, [1]),
    {ok, _Altered, Altered} = minato_query:simple(
        Cached,
        ~"INSERT INTO minato_cache VALUES (1, 'one'); ALTER TABLE minato_cache ALTER a TYPE text"
    ),
    {ok, #{rows := Rows}, Renewed} = minato_query:cached(Altered, Sql, [~"1"]),
    ?assertEqual([{~"one"}], Rows),
    ?assertEqual({1, 64}, minato_conn:statements(Renewed)),
    ?assertEqual(1, length(parsed(Renewed))),
    {ok, #{rows := Again}, Reused} = minato_query:cached(Renewed, Sql, [~"1"]),
    ?assertEqual([{~"one"}], Again),
    ok = dropped(Reused).

-spec a_value_for_what_a_column_was_is_refused_as_an_unkept_statement_would([{atom(), term()}]) ->
    ok.
a_value_for_what_a_column_was_is_refused_as_an_unkept_statement_would(_Config) ->
    Sql = ~"SELECT b FROM minato_cache WHERE a = $1",
    Cached = kept(~"a int4, b text", Sql, [1]),
    {ok, _Altered, Altered} =
        minato_query:simple(Cached, ~"ALTER TABLE minato_cache ALTER a TYPE text"),
    Unkept = raised(fun() -> minato_query:query(Altered, Sql, [1]) end),
    ?assertMatch({error, {minato_codec, #{type := text}}}, Unkept),
    ?assertEqual(Unkept, raised(fun() -> minato_query:cached(Altered, Sql, [1]) end)),
    ?assertEqual(Unkept, raised(fun() -> minato_query:cached(Altered, Sql, [1]) end)),
    {ok, #{rows := Rows}, Renewed} = minato_query:cached(Altered, Sql, [~"1"]),
    ?assertEqual([], Rows),
    ?assertEqual(1, length(parsed(Renewed))),
    ok = dropped(Renewed).

%% `bytea = text` has no operator, so the server refuses the statement it kept
%% with 42883 although the same SQL parses and runs if it is sent again.
-spec a_statement_the_server_refuses_over_its_old_types_is_parsed_again([{atom(), term()}]) ->
    ok.
a_statement_the_server_refuses_over_its_old_types_is_parsed_again(_Config) ->
    Sql = ~"SELECT a FROM minato_cache WHERE b = $1",
    Cached = kept(~"a int4, b text", Sql, [~"one"]),
    {ok, _Altered, Altered} = minato_query:simple(
        Cached,
        ~"INSERT INTO minato_cache VALUES (1, 'one'); ALTER TABLE minato_cache ALTER b TYPE bytea USING b::bytea"
    ),
    {ok, #{rows := Rows}, Renewed} = minato_query:cached(Altered, Sql, [~"one"]),
    ?assertEqual([{1}], Rows),
    ?assertEqual(1, length(parsed(Renewed))),
    ok = dropped(Renewed).

-spec a_statement_refused_over_its_old_types_in_a_transaction_recovers_after_it(
    [{atom(), term()}]
) -> ok.
a_statement_refused_over_its_old_types_in_a_transaction_recovers_after_it(_Config) ->
    Sql = ~"SELECT a FROM minato_cache WHERE b = $1",
    Cached = kept(~"a int4, b text", Sql, [~"one"]),
    {ok, _Altered, Altered} = minato_query:simple(
        Cached,
        ~"INSERT INTO minato_cache VALUES (1, 'one'); ALTER TABLE minato_cache ALTER b TYPE bytea USING b::bytea"
    ),
    {ok, Open} = minato_txn:open(Altered),
    {error, {pgsql_error, #{code := Code}}, Aborted} = minato_query:cached(Open, Sql, [~"one"]),
    ?assertEqual(~"42883", Code),
    ?assertEqual({0, 64}, minato_conn:statements(Aborted)),
    {ok, RolledBack} = minato_txn:rollback(Aborted),
    {ok, Reopened} = minato_txn:open(RolledBack),
    {ok, #{rows := Rows}, Renewed} = minato_query:cached(Reopened, Sql, [~"one"]),
    ?assertEqual([{1}], Rows),
    {ok, Committed} = minato_txn:commit(Renewed),
    ok = dropped(Committed).

%% Asking the server again what the statement takes is a `Parse`, which a
%% transaction that is still good survives.
-spec a_value_that_does_not_fit_a_kept_statement_leaves_a_transaction_open([{atom(), term()}]) ->
    ok.
a_value_that_does_not_fit_a_kept_statement_leaves_a_transaction_open(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    Sql = ~"SELECT $1::int4",
    {ok, _First, Cached} = minato_query:cached(Conn, Sql, [1]),
    {ok, Open} = minato_txn:open(Cached),
    ?assertMatch(
        {error, {minato_codec, #{reason := not_an_integer}}},
        raised(fun() -> minato_query:cached(Open, Sql, [~"one"]) end)
    ),
    {ok, #{rows := Rows}, Still} = minato_query:cached(Open, Sql, [2]),
    ?assertEqual([{2}], Rows),
    ?assertEqual(transaction, minato_conn:transaction_status(Still)),
    ?assertEqual([~"0"], counters(Still)),
    {ok, Committed} = minato_txn:commit(Still),
    ok = minato_conn:close(Committed).

-spec a_session_that_discarded_everything_parses_again([{atom(), term()}]) -> ok.
a_session_that_discarded_everything_parses_again(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    Sql = ~"SELECT $1::int4",
    {ok, _First, Cached} = minato_query:cached(Conn, Sql, [1]),
    {ok, _Gone, Discarded} = minato_query:simple(Cached, ~"DISCARD ALL"),
    {ok, #{rows := Rows}, Again} = minato_query:cached(Discarded, Sql, [2]),
    ?assertEqual([{2}], Rows),
    ?assertEqual(1, length(parsed(Again))),
    ok = minato_conn:close(Again).

-spec a_full_cache_falls_back_to_unnamed([{atom(), term()}]) -> ok.
a_full_cache_falls_back_to_unnamed(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{prepared_statements => 2})),
    {ok, _One, First} = minato_query:cached(Conn, ~"SELECT 1", []),
    {ok, _Two, Second} = minato_query:cached(First, ~"SELECT 2", []),
    {ok, #{rows := [{3}]}, Third} = minato_query:cached(Second, ~"SELECT 3", []),
    {ok, #{rows := [{3}]}, Fourth} = minato_query:cached(Third, ~"SELECT 3", []),
    ?assertEqual([~"0", ~"1"], counters(Fourth)),
    ?assertEqual({2, 2}, minato_conn:statements(Fourth)),
    ok = minato_conn:close(Fourth).

-spec caching_can_be_turned_off([{atom(), term()}]) -> ok.
caching_can_be_turned_off(_Config) ->
    {ok, Conn} = minato_conn:connect(connection(#{prepared_statements => 0})),
    {ok, #{rows := [{1}]}, First} = minato_query:cached(Conn, ~"SELECT 1", []),
    {ok, #{rows := [{1}]}, Second} = minato_query:cached(First, ~"SELECT 1", []),
    ?assertEqual([], parsed(Second)),
    ok = minato_conn:close(Second).

-spec a_pool_query_parses_each_statement_once([{atom(), term()}]) -> ok.
a_pool_query_parses_each_statement_once(_Config) ->
    Sql = ~"SELECT $1::int4",
    {ok, #{rows := [{1}]}} = minato:query(?POOL, Sql, [1]),
    {ok, #{rows := [{2}]}} = minato:query(?POOL, Sql, [2]),
    {ok, #{rows := [{3}]}} = minato:query(?POOL, Sql, [3]),
    {ok, #{rows := Rows}} = minato:query(?POOL, ~"SELECT name FROM pg_prepared_statements", []),
    ?assertEqual(2, length(Rows)).

%%----------------------------------------------------------------------
%% A table, and a statement kept against it
%%----------------------------------------------------------------------

kept(Columns, Sql, Parameters) ->
    {ok, Conn} = minato_conn:connect(connection(#{})),
    Create = [~"DROP TABLE IF EXISTS minato_cache; CREATE TABLE minato_cache (", Columns, ~")"],
    {ok, _Made, Made} = minato_query:simple(Conn, Create),
    {ok, _First, Cached} = minato_query:cached(Made, Sql, Parameters),
    Cached.

dropped(Conn) ->
    {ok, _Dropped, Dropped} = minato_query:simple(Conn, ~"DROP TABLE minato_cache"),
    minato_conn:close(Dropped).

raised(Fun) ->
    try Fun() of
        Answer -> {answered, Answer}
    catch
        Class:Reason -> {Class, Reason}
    end.

%%----------------------------------------------------------------------
%% Asking the server what it has parsed
%%----------------------------------------------------------------------

parsed(Conn) ->
    Sql = ~"SELECT name FROM pg_prepared_statements ORDER BY name",
    {ok, #{rows := Rows}, _Read} = minato_query:query(Conn, Sql, []),
    [Name || {Name} <- Rows].

%% Statement names carry a random per-connection prefix, so a test that pinned
%% the whole name would be pinning the randomness. The counter is the part these
%% cases are actually about: that the same SQL reuses one, and different SQL
%% takes the next.
counters(Conn) ->
    [lists:last(binary:split(Name, ~"_", [global])) || Name <- parsed(Conn)].

connection(Extra) ->
    maps:merge(
        #{
            host => env("MINATO_PG_HOST", "127.0.0.1"),
            port => list_to_integer(env("MINATO_PG_PORT", "55432")),
            user => list_to_binary(env("MINATO_PG_USER", "minato")),
            password => list_to_binary(env("MINATO_PG_PASSWORD", "minato")),
            database => list_to_binary(env("MINATO_PG_DATABASE", "minato_test")),
            timeout => ?TIMEOUT
        },
        Extra
    ).

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
