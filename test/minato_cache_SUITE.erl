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
