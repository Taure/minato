-module(minato_prop_SUITE).
-moduledoc """
Properties of the client against a real PostgreSQL.

The corpus suites answer "is this value carried correctly". These answer the
questions that are about shape rather than value, and that a handful of examples
cannot: any number of rows, any number of parameters, nulls in any position, a
value of any size, the same query asked two ways.

Shape is where a wire protocol client goes wrong. Framing is fine until a result
set spans enough reads; a parameter list is fine until it is longer than the one
in the test; a decoder is fine until a row is empty. PropEr generates the sizes
nobody would think to write down, and the server is the judge of every answer.

`MINATO_PROP_TESTS` sets how many times each property runs. The default is small
enough for CI, and every run is a round trip to a real database.

Skips when no server answers.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("stdlib/include/assert.hrl").

%% eqWAlizer: the PropEr macros expand to term(), so these cannot be typed.
-eqwalizer({nowarn_function, prop_result_set_of_any_size/0}).
-eqwalizer({nowarn_function, prop_any_number_of_parameters/0}).
-eqwalizer({nowarn_function, prop_nulls_in_any_position/0}).
-eqwalizer({nowarn_function, prop_a_binary_of_any_size/0}).
-eqwalizer({nowarn_function, prop_maps_and_tuples_agree/0}).
-eqwalizer({nowarn_function, prop_prepared_answers_like_unprepared/0}).
-eqwalizer({nowarn_function, gen_utf8/0}).
-eqwalizer({nowarn_function, gen_parameters/0}).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    a_result_set_of_any_size_arrives_whole/1,
    any_number_of_parameters_is_answered/1,
    nulls_in_any_position_survive/1,
    utf8_text_round_trips/1,
    a_binary_of_any_size_round_trips/1,
    maps_and_tuples_agree/1,
    a_prepared_statement_answers_like_an_unprepared_one/1,
    a_refused_statement_is_survivable/1,
    a_megabyte_value_survives_framing/1,
    five_thousand_rows_arrive_in_order/1
]).

-define(TIMEOUT, 30000).
-define(POOL, minato_prop_pool).

-spec all() -> [atom()].
all() ->
    [
        a_result_set_of_any_size_arrives_whole,
        any_number_of_parameters_is_answered,
        nulls_in_any_position_survive,
        utf8_text_round_trips,
        a_binary_of_any_size_round_trips,
        maps_and_tuples_agree,
        a_prepared_statement_answers_like_an_unprepared_one,
        a_refused_statement_is_survivable,
        a_megabyte_value_survives_framing,
        five_thousand_rows_arrive_in_order
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(connection()) of
        {ok, Conn} ->
            ok = minato_conn:close(Conn),
            {ok, _Started} = application:ensure_all_started(minato),
            {ok, _Pid} = minato:start_pool(?POOL, #{size => 2, connection => connection()}),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok = application:stop(minato).

%%----------------------------------------------------------------------
%% Cases
%%----------------------------------------------------------------------

-spec a_result_set_of_any_size_arrives_whole([{atom(), term()}]) -> ok.
a_result_set_of_any_size_arrives_whole(_Config) ->
    check(prop_result_set_of_any_size()).

-spec any_number_of_parameters_is_answered([{atom(), term()}]) -> ok.
any_number_of_parameters_is_answered(_Config) ->
    check(prop_any_number_of_parameters()).

-spec nulls_in_any_position_survive([{atom(), term()}]) -> ok.
nulls_in_any_position_survive(_Config) ->
    check(prop_nulls_in_any_position()).

-spec utf8_text_round_trips([{atom(), term()}]) -> ok.
utf8_text_round_trips(_Config) ->
    check(prop_utf8_text_round_trips()).

-spec a_binary_of_any_size_round_trips([{atom(), term()}]) -> ok.
a_binary_of_any_size_round_trips(_Config) ->
    check(prop_a_binary_of_any_size()).

-spec maps_and_tuples_agree([{atom(), term()}]) -> ok.
maps_and_tuples_agree(_Config) ->
    check(prop_maps_and_tuples_agree()).

-spec a_prepared_statement_answers_like_an_unprepared_one([{atom(), term()}]) -> ok.
a_prepared_statement_answers_like_an_unprepared_one(_Config) ->
    check(prop_prepared_answers_like_unprepared()).

-spec a_refused_statement_is_survivable([{atom(), term()}]) -> ok.
a_refused_statement_is_survivable(_Config) ->
    check(prop_a_refused_statement_is_survivable()).

-spec a_megabyte_value_survives_framing([{atom(), term()}]) -> ok.
a_megabyte_value_survives_framing(_Config) ->
    Value = binary:copy(~"minato", 200000),
    {ok, #{rows := [{Back}]}} = minato:query(?POOL, ~"SELECT $1::bytea", [Value]),
    ?assertEqual(Value, Back),
    {ok, #{rows := [{Text}]}} = minato:query(?POOL, ~"SELECT $1::text", [Value]),
    ?assertEqual(Value, Text).

-spec five_thousand_rows_arrive_in_order([{atom(), term()}]) -> ok.
five_thousand_rows_arrive_in_order(_Config) ->
    Sql = ~"SELECT i, repeat('x', 40) FROM generate_series(1, 5000) i",
    {ok, #{rows := Rows, num_rows := Count}} = minato:query(?POOL, Sql, []),
    ?assertEqual(5000, Count),
    ?assertEqual(5000, length(Rows)),
    ?assertEqual([I || I <- lists:seq(1, 5000)], [I || {I, _Padding} <- Rows]).

%%----------------------------------------------------------------------
%% Properties
%%----------------------------------------------------------------------

prop_result_set_of_any_size() ->
    ?FORALL(
        Size,
        integer(0, 500),
        begin
            Sql = ~"SELECT i FROM generate_series(1, $1::int4) i",
            {ok, #{rows := Rows, num_rows := Count}} = minato:query(?POOL, Sql, [Size]),
            Count =:= Size andalso [I || {I} <- Rows] =:= lists:seq(1, Size)
        end
    ).

prop_any_number_of_parameters() ->
    ?FORALL(
        Values,
        gen_parameters(),
        begin
            {ok, #{rows := [Row]}} = minato:query(?POOL, select(length(Values)), Values),
            tuple_to_list(Row) =:= Values
        end
    ).

prop_nulls_in_any_position() ->
    ?FORALL(
        Values,
        non_empty(list(oneof([null, integer()]))),
        begin
            {ok, #{rows := [Row]}} = minato:query(?POOL, select(length(Values)), Values),
            tuple_to_list(Row) =:= Values
        end
    ).

prop_utf8_text_round_trips() ->
    ?FORALL(
        Text,
        gen_utf8(),
        begin
            {ok, #{rows := [{Back}]}} = minato:query(?POOL, ~"SELECT $1::text", [Text]),
            Back =:= Text
        end
    ).

prop_a_binary_of_any_size() ->
    ?FORALL(
        Size,
        integer(0, 65536),
        begin
            Value = crypto:strong_rand_bytes(Size),
            {ok, #{rows := [{Back}]}} = minato:query(?POOL, ~"SELECT $1::bytea", [Value]),
            Back =:= Value
        end
    ).

prop_maps_and_tuples_agree() ->
    ?FORALL(
        Value,
        integer(),
        begin
            Sql = ~"SELECT $1::int8 AS a, $1::int8 * 2 AS b",
            {ok, #{rows := [Tuple]}} = minato:query(?POOL, Sql, [Value]),
            Opts = #{return_rows_as_maps => true, column_name_as_atom => true},
            {ok, #{rows := [Map]}} = minato:query(?POOL, Sql, [Value], Opts),
            Map =:= #{a => element(1, Tuple), b => element(2, Tuple)}
        end
    ).

prop_prepared_answers_like_unprepared() ->
    ?FORALL(
        Values,
        gen_parameters(),
        begin
            Sql = select(length(Values)),
            {ok, #{rows := Direct}} = minato:query(?POOL, Sql, Values),
            Prepared = minato:with(?POOL, fun(Conn) -> prepared(Conn, Sql, Values) end),
            Prepared =:= {ok, Direct}
        end
    ).

prop_a_refused_statement_is_survivable() ->
    ?FORALL(
        Name,
        gen_utf8(),
        begin
            Sql = <<"SELECT * FROM ", (quoted(Name))/binary>>,
            Refused = minato:query(?POOL, Sql, []),
            Answered = minato:query(?POOL, ~"SELECT 1", []),
            refused(Refused) andalso
                Answered =:=
                    {ok, #{
                        command => select,
                        num_rows => 1,
                        rows => [{1}]
                    }}
        end
    ).

refused({error, {pgsql_error, #{code := _Code}}}) -> true;
refused(_Other) -> false.

prepared(Conn, Sql, Values) ->
    case minato_query:prepare(Conn, ~"prop", Sql) of
        {ok, Statement, Ready} -> executed(Ready, Statement, Values);
        {error, Reason, Failed} -> {keep, {error, Reason}, Failed};
        {error, Reason} -> {discard, {error, Reason}}
    end.

executed(Conn, Statement, Values) ->
    case minato_query:execute(Conn, Statement, Values) of
        {ok, #{rows := Rows}, Ran} -> closed(Ran, Statement, Rows);
        {error, Reason, Failed} -> {keep, {error, Reason}, Failed};
        {error, Reason} -> {discard, {error, Reason}}
    end.

closed(Conn, Statement, Rows) ->
    case minato_query:close(Conn, Statement) of
        {ok, Closed} -> {keep, {ok, Rows}, Closed};
        {error, Reason, Failed} -> {keep, {error, Reason}, Failed};
        {error, Reason} -> {discard, {error, Reason}}
    end.

%%----------------------------------------------------------------------
%% Generators
%%----------------------------------------------------------------------

gen_parameters() ->
    ?LET(Count, integer(1, 40), vector(Count, integer())).

gen_utf8() ->
    ?LET(Characters, list(gen_char()), unicode:characters_to_binary(Characters)).

gen_char() ->
    oneof([
        integer(1, 127),
        integer(160, 255),
        integer(256, 55295),
        integer(57344, 65533),
        integer(65536, 1114111)
    ]).

%%----------------------------------------------------------------------
%% Running the properties
%%----------------------------------------------------------------------

check(Property) ->
    ?assert(proper:quickcheck(Property, [numtests(), {to_file, user}])).

numtests() ->
    list_to_integer(env("MINATO_PROP_TESTS", "50")).

select(Count) ->
    Placeholders = [
        <<"$", (integer_to_binary(N))/binary, "::int8">>
     || N <- lists:seq(1, Count)
    ],
    <<"SELECT ", (join(Placeholders))/binary>>.

join([Only]) ->
    Only;
join([Head | Rest]) ->
    <<Head/binary, ", ", (join(Rest))/binary>>.

quoted(Name) ->
    Escaped = binary:replace(Name, ~"\"", ~"\"\"", [global]),
    <<$", Escaped/binary, $">>.

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
