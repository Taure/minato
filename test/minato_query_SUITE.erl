-module(minato_query_SUITE).
-moduledoc """
Running SQL, against a real PostgreSQL.

The two query paths are worth proving against the server rather than a stub,
because most of what can go wrong is the server disagreeing: a parameter encoded
in a format the server did not expect, a result decoded as text when binary
bytes arrived, a failed statement leaving the connection in a state the next
query cannot use.

The last of those is the case this suite cares most about. A driver that returns
an error and leaves the connection unusable turns one failing statement into a
pool of dead connections, so every failure case here runs a second statement on
the same connection afterwards and requires it to work.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    a_simple_query_returns_rows/1,
    a_simple_query_runs_every_statement_it_was_given/1,
    a_simple_query_reports_what_a_statement_changed/1,
    a_failing_simple_query_leaves_the_connection_usable/1,
    parameters_round_trip_through_the_binary_format/1,
    a_null_parameter_round_trips/1,
    an_array_parameter_round_trips/1,
    a_type_without_a_codec_arrives_as_text/1,
    an_insert_reports_the_rows_it_wrote/1,
    a_failing_statement_leaves_the_connection_usable/1,
    the_wrong_number_of_parameters_raises/1,
    rows_can_be_maps/1,
    a_prepared_statement_runs_more_than_once/1,
    a_closed_statement_is_gone/1,
    an_empty_statement_is_not_an_error/1,
    a_statement_past_its_deadline_is_cancelled/1,
    a_cancelled_statement_leaves_the_connection_usable/1,
    the_connection_timeout_is_the_default_deadline/1,
    a_transaction_survives_a_cancelled_statement/1
]).

-define(TIMEOUT, 10000).

-spec all() -> [atom()].
all() ->
    [
        a_simple_query_returns_rows,
        a_simple_query_runs_every_statement_it_was_given,
        a_simple_query_reports_what_a_statement_changed,
        a_failing_simple_query_leaves_the_connection_usable,
        parameters_round_trip_through_the_binary_format,
        a_null_parameter_round_trips,
        an_array_parameter_round_trips,
        a_type_without_a_codec_arrives_as_text,
        an_insert_reports_the_rows_it_wrote,
        a_failing_statement_leaves_the_connection_usable,
        the_wrong_number_of_parameters_raises,
        rows_can_be_maps,
        a_prepared_statement_runs_more_than_once,
        a_closed_statement_is_gone,
        an_empty_statement_is_not_an_error,
        a_statement_past_its_deadline_is_cancelled,
        a_cancelled_statement_leaves_the_connection_usable,
        the_connection_timeout_is_the_default_deadline,
        a_transaction_survives_a_cancelled_statement
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(opts()) of
        {ok, Conn} ->
            {ok, _Results, Ready} = minato_query:simple(Conn, schema()),
            ok = minato_conn:close(Ready),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    case minato_conn:connect(opts()) of
        {ok, Conn} ->
            {ok, _Results, Ready} = minato_query:simple(Conn, ~"DROP TABLE IF EXISTS minato_rows"),
            minato_conn:close(Ready);
        {error, _Reason} ->
            ok
    end.

-spec init_per_testcase(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_testcase(_Case, Config) ->
    {ok, Conn} = minato_conn:connect(opts()),
    {ok, _Results, Ready} = minato_query:simple(Conn, ~"TRUNCATE minato_rows"),
    [{conn, Ready} | Config].

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(_Case, Config) ->
    minato_conn:close(conn(Config)).

-spec a_simple_query_returns_rows([{atom(), term()}]) -> ok.
a_simple_query_returns_rows(Config) ->
    {ok, [Result], _Conn} = minato_query:simple(conn(Config), ~"SELECT 1, 'ok'"),
    ?assertMatch(#{command := select, num_rows := 1, rows := [{1, ~"ok"}]}, Result).

-spec a_simple_query_runs_every_statement_it_was_given([{atom(), term()}]) -> ok.
a_simple_query_runs_every_statement_it_was_given(Config) ->
    {ok, Results, _Conn} = minato_query:simple(conn(Config), ~"SELECT 1; SELECT 2; SELECT 3"),
    ?assertEqual([[{1}], [{2}], [{3}]], [Rows || #{rows := Rows} <- Results]).

-spec a_simple_query_reports_what_a_statement_changed([{atom(), term()}]) -> ok.
a_simple_query_reports_what_a_statement_changed(Config) ->
    Sql = ~"INSERT INTO minato_rows (name, count) VALUES ('a', 1), ('b', 2)",
    {ok, [Result], _Conn} = minato_query:simple(conn(Config), Sql),
    ?assertMatch(#{command := insert, num_rows := 2}, Result).

-spec a_failing_simple_query_leaves_the_connection_usable([{atom(), term()}]) -> ok.
a_failing_simple_query_leaves_the_connection_usable(Config) ->
    {error, Reason, Conn} = minato_query:simple(conn(Config), ~"SELECT * FROM no_such_table"),
    ?assertMatch({pgsql_error, #{code := ~"42P01"}}, Reason),
    ?assertMatch({ok, [#{rows := [{1}]}], _Conn}, minato_query:simple(Conn, ~"SELECT 1")).

-spec parameters_round_trip_through_the_binary_format([{atom(), term()}]) -> ok.
parameters_round_trip_through_the_binary_format(Config) ->
    Sql = ~"SELECT $1::int4, $2::text, $3::bool, $4::float8, $5::uuid, $6::bytea",
    Uuid = ~"0196f0a9-1c4f-7e21-9b3a-6d2c5e8f1a44",
    Given = [42, ~"hello", true, 1.5, Uuid, ~"\x00\x01\xff"],
    {ok, #{rows := [Row]}, _Conn} = minato_query:query(conn(Config), Sql, Given),
    ?assertEqual({42, ~"hello", true, 1.5, Uuid, ~"\x00\x01\xff"}, Row).

-spec a_null_parameter_round_trips([{atom(), term()}]) -> ok.
a_null_parameter_round_trips(Config) ->
    Sql = ~"SELECT $1::int4, $1::int4 IS NULL",
    {ok, #{rows := [Row]}, _Conn} = minato_query:query(conn(Config), Sql, [null]),
    ?assertEqual({null, true}, Row).

-spec an_array_parameter_round_trips([{atom(), term()}]) -> ok.
an_array_parameter_round_trips(Config) ->
    Sql = ~"SELECT $1::int4[]",
    {ok, #{rows := [Row]}, _Conn} = minato_query:query(conn(Config), Sql, [[1, 2, 3]]),
    ?assertEqual({[1, 2, 3]}, Row).

-spec a_type_without_a_codec_arrives_as_text([{atom(), term()}]) -> ok.
a_type_without_a_codec_arrives_as_text(Config) ->
    {ok, #{rows := [Row]}, _Conn} = minato_query:query(
        conn(Config), ~"SELECT '1 year'::interval", []
    ),
    ?assertEqual({~"1 year"}, Row).

-spec an_insert_reports_the_rows_it_wrote([{atom(), term()}]) -> ok.
an_insert_reports_the_rows_it_wrote(Config) ->
    Sql = ~"INSERT INTO minato_rows (name, count) VALUES ($1, $2), ($3, $4)",
    {ok, Result, Conn} = minato_query:query(conn(Config), Sql, [~"a", 1, ~"b", 2]),
    ?assertMatch(#{command := insert, num_rows := 2, rows := []}, Result),
    {ok, #{rows := Rows}, _Read} = minato_query:query(
        Conn, ~"SELECT name, count FROM minato_rows ORDER BY name", []
    ),
    ?assertEqual([{~"a", 1}, {~"b", 2}], Rows).

-spec a_failing_statement_leaves_the_connection_usable([{atom(), term()}]) -> ok.
a_failing_statement_leaves_the_connection_usable(Config) ->
    Sql = ~"INSERT INTO minato_rows (name, count) VALUES ($1, $2)",
    {ok, _Result, Conn} = minato_query:query(conn(Config), Sql, [~"a", 1]),
    {error, Reason, Again} = minato_query:query(Conn, Sql, [~"a", 2]),
    ?assertMatch({pgsql_error, #{code := ~"23505"}}, Reason),
    ?assertMatch({ok, #{rows := [{1}]}, _Read}, minato_query:query(Again, ~"SELECT 1", [])).

-spec the_wrong_number_of_parameters_raises([{atom(), term()}]) -> ok.
the_wrong_number_of_parameters_raises(Config) ->
    Conn = conn(Config),
    ?assertError(
        {minato_query, #{reason := parameter_count_mismatch}},
        minato_query:query(Conn, ~"SELECT $1::int4, $2::int4", [1])
    ),
    ?assertMatch({ok, #{rows := [{1}]}, _Read}, minato_query:query(Conn, ~"SELECT 1", [])).

-spec rows_can_be_maps([{atom(), term()}]) -> ok.
rows_can_be_maps(Config) ->
    Opts = #{return_rows_as_maps => true, column_name_as_atom => true},
    Sql = ~"SELECT 1 AS one, 'ok'::text AS word",
    {ok, #{rows := [Row]}, _Conn} = minato_query:query(conn(Config), Sql, [], Opts),
    ?assertEqual(#{one => 1, word => ~"ok"}, Row).

-spec a_prepared_statement_runs_more_than_once([{atom(), term()}]) -> ok.
a_prepared_statement_runs_more_than_once(Config) ->
    Sql = ~"INSERT INTO minato_rows (name, count) VALUES ($1, $2)",
    {ok, Statement, Conn} = minato_query:prepare(conn(Config), ~"insert_row", Sql),
    {ok, _First, Once} = minato_query:execute(Conn, Statement, [~"a", 1]),
    {ok, _Second, Twice} = minato_query:execute(Once, Statement, [~"b", 2]),
    {ok, #{rows := Rows}, _Read} = minato_query:query(
        Twice, ~"SELECT count FROM minato_rows ORDER BY name", []
    ),
    ?assertEqual([{1}, {2}], Rows).

-spec a_closed_statement_is_gone([{atom(), term()}]) -> ok.
a_closed_statement_is_gone(Config) ->
    {ok, Statement, Conn} = minato_query:prepare(conn(Config), ~"one", ~"SELECT 1"),
    {ok, Closed} = minato_query:close(Conn, Statement),
    {error, Reason, Usable} = minato_query:execute(Closed, Statement, []),
    ?assertMatch({pgsql_error, #{code := ~"26000"}}, Reason),
    ?assertMatch({ok, #{rows := [{1}]}, _Read}, minato_query:query(Usable, ~"SELECT 1", [])).

-spec an_empty_statement_is_not_an_error([{atom(), term()}]) -> ok.
an_empty_statement_is_not_an_error(Config) ->
    {ok, Result, _Conn} = minato_query:query(conn(Config), ~"", []),
    ?assertMatch(#{command := empty, rows := []}, Result).

-spec a_statement_past_its_deadline_is_cancelled([{atom(), term()}]) -> ok.
a_statement_past_its_deadline_is_cancelled(Config) ->
    Started = erlang:monotonic_time(millisecond),
    Answer = minato_query:query(conn(Config), ~"SELECT pg_sleep(30)", [], #{timeout => 300}),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assertMatch({error, {pgsql_error, #{code := ~"57014"}}, _Conn}, Answer),
    ?assert(Elapsed < 5000).

-spec a_cancelled_statement_leaves_the_connection_usable([{atom(), term()}]) -> ok.
a_cancelled_statement_leaves_the_connection_usable(Config) ->
    Sql = ~"SELECT pg_sleep(30)",
    {error, _Reason, Cancelled} = minato_query:query(conn(Config), Sql, [], #{timeout => 300}),
    ?assertEqual(idle, minato_txn:status(Cancelled)),
    ?assertMatch({ok, #{rows := [{1}]}, _Read}, minato_query:query(Cancelled, ~"SELECT 1", [])).

-spec the_connection_timeout_is_the_default_deadline([{atom(), term()}]) -> ok.
the_connection_timeout_is_the_default_deadline(_Config) ->
    {ok, Conn} = minato_conn:connect((opts())#{timeout => 300}),
    Answer = minato_query:query(Conn, ~"SELECT pg_sleep(30)", []),
    ?assertMatch({error, {pgsql_error, #{code := ~"57014"}}, _Conn}, Answer),
    {error, _Reason, Usable} = Answer,
    ?assertMatch({ok, #{rows := [{1}]}, _Read}, minato_query:query(Usable, ~"SELECT 1", [])),
    ok = minato_conn:close(Usable).

-spec a_transaction_survives_a_cancelled_statement([{atom(), term()}]) -> ok.
a_transaction_survives_a_cancelled_statement(Config) ->
    {ok, Open} = minato_txn:open(conn(Config)),
    Sql = ~"SELECT pg_sleep(30)",
    {error, _Reason, Cancelled} = minato_query:query(Open, Sql, [], #{timeout => 300}),
    ?assertEqual(failed, minato_txn:status(Cancelled)),
    {ok, Rolled} = minato_txn:rollback(Cancelled),
    ?assertEqual(idle, minato_txn:status(Rolled)),
    ?assertMatch({ok, #{rows := [{1}]}, _Read}, minato_query:query(Rolled, ~"SELECT 1", [])).

%%----------------------------------------------------------------------
%% Where the server is
%%----------------------------------------------------------------------

conn(Config) ->
    {conn, Conn} = lists:keyfind(conn, 1, Config),
    Conn.

schema() ->
    ~"""
    DROP TABLE IF EXISTS minato_rows;
    CREATE TABLE minato_rows (
        name text PRIMARY KEY,
        count int4 NOT NULL
    )
    """.

opts() ->
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
