-module(minato_roundtrip_SUITE).
-moduledoc """
Every type the corpus knows, through the whole client and back.

`minato_differential_SUITE` proves the codecs against `pg_types` and a real
server, but it carries the bytes with `pgo`, because when it was written there
was no connection to carry them with. This suite is the same corpus through
minato's own connection, parameters, protocol and pool: the value goes out as a
bound parameter and comes back as a decoded row, and the two have to match.

That end to end path is where a codec that is right on its own can still be
wrong: a parameter sent in the format the other side was not told to expect, a
result decoded against a `RowDescription` that says something else, a value that
survives `SELECT $1` and not a column of a table.

Both are checked. `SELECT $1::type` proves the parameter path, and an `INSERT
... RETURNING` proves the storage path, which is the one an application uses.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    every_type_round_trips_as_a_parameter/1,
    every_type_round_trips_generated/1,
    every_scalar_round_trips_through_a_table/1,
    a_null_round_trips_for_every_type/1,
    every_type_round_trips_inside_an_array_column/1
]).

-define(TIMEOUT, 20000).
-define(POOL, minato_roundtrip_pool).
-define(SEED, 20260805).
-define(GENERATED, 20).

-spec all() -> [atom()].
all() ->
    [
        every_type_round_trips_as_a_parameter,
        every_type_round_trips_generated,
        every_scalar_round_trips_through_a_table,
        a_null_round_trips_for_every_type,
        every_type_round_trips_inside_an_array_column
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

-spec every_type_round_trips_as_a_parameter([{atom(), term()}]) -> ok.
every_type_round_trips_as_a_parameter(_Config) ->
    report([parameters(Entry, minato_corpus:fixed(Entry)) || Entry <- minato_corpus:types()]).

-spec every_type_round_trips_generated([{atom(), term()}]) -> ok.
every_type_round_trips_generated(_Config) ->
    report([
        parameters(Entry, minato_corpus:generate(Entry, ?GENERATED, ?SEED))
     || Entry <- minato_corpus:types()
    ]).

-spec every_scalar_round_trips_through_a_table([{atom(), term()}]) -> ok.
every_scalar_round_trips_through_a_table(_Config) ->
    report([stored(Entry, minato_corpus:fixed(Entry)) || Entry <- scalars()]).

-spec a_null_round_trips_for_every_type([{atom(), term()}]) -> ok.
a_null_round_trips_for_every_type(_Config) ->
    report([
        parameters(Entry, [#{value => null, expected => null, opts => #{}}])
     || Entry <- minato_corpus:types()
    ]).

-spec every_type_round_trips_inside_an_array_column([{atom(), term()}]) -> ok.
every_type_round_trips_inside_an_array_column(_Config) ->
    report([stored(Entry, minato_corpus:generate(Entry, 5, ?SEED)) || Entry <- arrays()]).

%%----------------------------------------------------------------------
%% Running a corpus through the client
%%----------------------------------------------------------------------

parameters(Entry, Cases) ->
    #{sql := Sql} = Entry,
    Statement = <<"SELECT $1::", Sql/binary>>,
    {Entry, [Wrong || Case <- Cases, Wrong <- asked(Statement, Entry, Case)]}.

stored(Entry, Cases) ->
    #{sql := Sql} = Entry,
    Table = table(Entry),
    Create =
        <<"DROP TABLE IF EXISTS ", Table/binary, "; CREATE TABLE ", Table/binary, " (v ",
            Sql/binary, ")">>,
    {ok, _Results} = minato:simple(?POOL, Create),
    Statement = <<"INSERT INTO ", Table/binary, " (v) VALUES ($1) RETURNING v">>,
    Wrong = [Bad || Case <- Cases, Bad <- asked(Statement, Entry, Case)],
    {ok, _Dropped} = minato:simple(?POOL, <<"DROP TABLE ", Table/binary>>),
    {Entry, Wrong}.

asked(Statement, Entry, #{value := Value, expected := Expected, opts := Opts}) ->
    case minato:query(?POOL, Statement, [Value], Opts) of
        {ok, #{rows := [{Expected}]}} ->
            [];
        {ok, #{rows := [{Other}]}} ->
            [#{entry => Entry, sent => Value, expected => Expected, got => Other}];
        {ok, Unexpected} ->
            [#{entry => Entry, sent => Value, expected => Expected, got => Unexpected}];
        {error, Reason} ->
            [#{entry => Entry, sent => Value, expected => Expected, got => {error, Reason}}]
    end.

report(Results) ->
    Failures = [{name(Entry), Wrong} || {Entry, Wrong} <- Results, Wrong =/= []],
    ?assertEqual([], Failures).

name(#{name := Name}) ->
    Name.

table(#{name := Name}) when is_atom(Name) ->
    <<"minato_rt_", (atom_to_binary(Name))/binary>>;
table(#{name := {array, Name}}) ->
    <<"minato_rt_", (atom_to_binary(Name))/binary, "_array">>.

scalars() ->
    [Entry || #{kind := scalar} = Entry <- minato_corpus:types()].

arrays() ->
    [Entry || #{kind := array} = Entry <- minato_corpus:types()].

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
