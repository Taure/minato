-module(minato_borrow_SUITE).
-moduledoc """
What `m:minato` promises about a borrowed connection, against a real PostgreSQL.

Each case here is a sentence from the documentation of `minato:query/4`,
`minato:with/2` or `minato:stop_pool/1`, asked through those functions and
answered by the server: which backend served a call, whether it is still there,
and in what order callers were served. A pool of one makes the backend a
caller gets the backend the last caller left, so "the connection went back"
and "the connection was replaced" are a process id that stayed or changed.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    a_parameter_that_will_not_encode_does_not_cost_the_connection/1,
    the_wrong_number_of_parameters_does_not_cost_the_connection/1,
    a_value_that_will_not_decode_does_not_cost_the_connection/1,
    a_refused_first_use_leaves_the_statement_cache_as_it_was/1,
    a_function_that_raises_costs_the_connection/1,
    a_function_that_asks_for_a_discard_costs_the_connection/1,
    callers_waiting_for_a_connection_are_served_in_the_order_they_asked/1,
    stopping_a_pool_closes_the_connections_it_holds/1,
    a_connection_borrowed_from_a_stopped_pool_is_closed_when_given_back/1
]).

-define(TIMEOUT, 10000).
-define(POOL, minato_borrow_pool).
-define(NAME, ~"minato_borrow_suite").
-define(BACKEND, ~"SELECT pg_backend_pid()").

-spec all() -> [atom()].
all() ->
    [
        a_parameter_that_will_not_encode_does_not_cost_the_connection,
        the_wrong_number_of_parameters_does_not_cost_the_connection,
        a_value_that_will_not_decode_does_not_cost_the_connection,
        a_refused_first_use_leaves_the_statement_cache_as_it_was,
        a_function_that_raises_costs_the_connection,
        a_function_that_asks_for_a_discard_costs_the_connection,
        callers_waiting_for_a_connection_are_served_in_the_order_they_asked,
        stopping_a_pool_closes_the_connections_it_holds,
        a_connection_borrowed_from_a_stopped_pool_is_closed_when_given_back
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(connection()) of
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
init_per_testcase(Case, Config) ->
    Size = connections(Case),
    {ok, _Pid} = minato:start_pool(?POOL, #{
        size => Size, min_size => Size, connection => named(connection())
    }),
    ok = eventually(fun() -> backends() =:= Size end),
    Config.

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(_Case, _Config) ->
    _ = minato:stop_pool(?POOL),
    ok = eventually(fun() -> backends() =:= 0 end).

connections(stopping_a_pool_closes_the_connections_it_holds) -> 3;
connections(a_connection_borrowed_from_a_stopped_pool_is_closed_when_given_back) -> 2;
connections(_Case) -> 1.

%%----------------------------------------------------------------------
%% A mistake in the call is not a fault in the connection
%%----------------------------------------------------------------------

-spec a_parameter_that_will_not_encode_does_not_cost_the_connection([{atom(), term()}]) -> ok.
a_parameter_that_will_not_encode_does_not_cost_the_connection(_Config) ->
    Before = backend(),
    ?assertError(
        {minato_codec, #{type := int4, value := redacted}},
        minato:query(?POOL, ~"SELECT $1::int4", [~"not a number"])
    ),
    ?assertEqual(Before, backend()),
    ?assertMatch(#{disconnects := 0, borrowed := 0}, minato:stats(?POOL)),
    ?assertEqual({ok, [{5}]}, rows(minato:query(?POOL, ~"SELECT $1::int4", [5]))).

-spec the_wrong_number_of_parameters_does_not_cost_the_connection([{atom(), term()}]) -> ok.
the_wrong_number_of_parameters_does_not_cost_the_connection(_Config) ->
    Before = backend(),
    ?assertError(
        {minato_query, #{reason := parameter_count_mismatch}},
        minato:query(?POOL, ~"SELECT $1::int4, $2::int4", [1])
    ),
    ?assertEqual(Before, backend()),
    ?assertMatch(#{disconnects := 0, borrowed := 0}, minato:stats(?POOL)).

-spec a_value_that_will_not_decode_does_not_cost_the_connection([{atom(), term()}]) -> ok.
a_value_that_will_not_decode_does_not_cost_the_connection(_Config) ->
    Before = backend(),
    Sql =
        ~"SELECT CASE WHEN i = 7 THEN '1e400'::numeric ELSE i::numeric END FROM generate_series(1, 50000) AS i",
    ?assertError(
        {minato_codec, #{type := numeric}},
        minato:query(?POOL, Sql, [], #{numeric_format => float})
    ),
    ?assertError(
        {minato_codec, #{type := numeric}},
        minato:simple(?POOL, [~"SELECT 1; ", Sql], #{numeric_format => float})
    ),
    ?assertEqual(Before, backend()),
    ?assertMatch(#{disconnects := 0, borrowed := 0}, minato:stats(?POOL)).

%% The pool lends the connection as it was before the call. A statement the
%% call parsed and the pool does not know about would hold its name on the
%% server, and the next statement to be given that name would be refused. The
%% one statement the server holds afterwards is the one that asks.
-spec a_refused_first_use_leaves_the_statement_cache_as_it_was([{atom(), term()}]) -> ok.
a_refused_first_use_leaves_the_statement_cache_as_it_was(_Config) ->
    ?assertError(
        {minato_codec, _Report},
        minato:query(?POOL, ~"SELECT $1::int4", [~"not a number"])
    ),
    Parsed = ~"SELECT count(*)::int4 FROM pg_prepared_statements",
    ?assertEqual({ok, [{1}]}, rows(minato:query(?POOL, Parsed, []))),
    ?assertEqual({ok, [{3}]}, rows(minato:query(?POOL, ~"SELECT $1::int4 + 1", [2]))),
    ?assertEqual({ok, [{7}]}, rows(minato:query(?POOL, ~"SELECT $1::int4", [7]))).

%%----------------------------------------------------------------------
%% A function that stopped somewhere unknown is
%%----------------------------------------------------------------------

-spec a_function_that_raises_costs_the_connection([{atom(), term()}]) -> ok.
a_function_that_raises_costs_the_connection(_Config) ->
    Before = backend(),
    ?assertError(half_way, minato:with(?POOL, fun(Conn) -> error(stopped(Conn)) end)),
    ?assertThrow(half_way, minato:with(?POOL, fun(Conn) -> throw(stopped(Conn)) end)),
    ?assertExit(half_way, minato:with(?POOL, fun(Conn) -> exit(stopped(Conn)) end)),
    ok = eventually(fun() -> not serving(Before) end),
    After = backend(),
    ?assertNotEqual(Before, After),
    ?assertMatch(#{disconnects := 3, borrowed := 0}, minato:stats(?POOL)).

stopped(Conn) ->
    ok = minato_conn:send(Conn, {query, ~"SELECT generate_series(1, 1000)"}),
    half_way.

-spec a_function_that_asks_for_a_discard_costs_the_connection([{atom(), term()}]) -> ok.
a_function_that_asks_for_a_discard_costs_the_connection(_Config) ->
    Before = backend(),
    ?assertEqual(done, minato:with(?POOL, fun(_Conn) -> {discard, done} end)),
    ok = eventually(fun() -> not serving(Before) end),
    ?assertNotEqual(Before, backend()),
    ?assertMatch(#{disconnects := 1}, minato:stats(?POOL)).

%%----------------------------------------------------------------------
%% Waiting
%%----------------------------------------------------------------------

%% One connection, held, and five callers that ask for it one after another.
%% Each is known to be queued before the next asks, so the order they asked in
%% is not in doubt, and each tells the test it was served while it still holds
%% the connection, so neither is the order they were served in.
-spec callers_waiting_for_a_connection_are_served_in_the_order_they_asked([{atom(), term()}]) ->
    ok.
callers_waiting_for_a_connection_are_served_in_the_order_they_asked(_Config) ->
    Test = self(),
    Holder = holding(Test),
    Callers = lists:seq(1, 5),
    ok = queued(Test, Callers),
    Holder ! release,
    ?assertEqual(Callers, [served() || _Caller <- Callers]),
    ?assertMatch(#{waiting := 0, borrowed := 0, waits := 5}, settled()).

queued(_Test, []) ->
    ok;
queued(Test, [Caller | Callers]) ->
    _ = spawn_link(fun() ->
        minato:with(?POOL, fun(Conn) ->
            Test ! {served, Caller},
            {keep, ok, Conn}
        end)
    end),
    ok = eventually(fun() -> maps:get(waiting, minato:stats(?POOL)) =:= Caller end),
    queued(Test, Callers).

served() ->
    receive
        {served, Caller} -> Caller
    after ?TIMEOUT -> never_served
    end.

settled() ->
    ok = eventually(fun() -> maps:get(borrowed, minato:stats(?POOL)) =:= 0 end),
    minato:stats(?POOL).

%%----------------------------------------------------------------------
%% Stopping
%%----------------------------------------------------------------------

-spec stopping_a_pool_closes_the_connections_it_holds([{atom(), term()}]) -> ok.
stopping_a_pool_closes_the_connections_it_holds(_Config) ->
    ?assertEqual(3, backends()),
    ok = minato:stop_pool(?POOL),
    ok = eventually(fun() -> backends() =:= 0 end),
    ?assertEqual({error, not_found}, minato:stop_pool(?POOL)).

%% A connection that is out when the pool stops is the borrower's, and the pool
%% cannot close a socket it does not hold. It is closed when it comes back.
-spec a_connection_borrowed_from_a_stopped_pool_is_closed_when_given_back([{atom(), term()}]) ->
    ok.
a_connection_borrowed_from_a_stopped_pool_is_closed_when_given_back(_Config) ->
    Holder = holding(self()),
    ok = minato:stop_pool(?POOL),
    ok = eventually(fun() -> backends() =:= 1 end),
    Holder ! release,
    ok = eventually(fun() -> backends() =:= 0 end).

%%----------------------------------------------------------------------
%% Asking the server
%%----------------------------------------------------------------------

holding(Test) ->
    Holder = spawn_link(fun() ->
        minato:with(?POOL, fun(Conn) ->
            Test ! held,
            receive
                release -> {keep, ok, Conn}
            end
        end)
    end),
    receive
        held -> Holder
    after ?TIMEOUT -> error(never_held)
    end.

backend() ->
    {ok, #{rows := [{Backend}]}} = minato:query(?POOL, ?BACKEND, []),
    Backend.

rows({ok, #{rows := Rows}}) -> {ok, Rows};
rows(Other) -> Other.

serving(Backend) ->
    observed(~"SELECT count(*)::int4 FROM pg_stat_activity WHERE pid = $1", [Backend]) =:= 1.

backends() ->
    observed(~"SELECT count(*)::int4 FROM pg_stat_activity WHERE application_name = $1", [?NAME]).

observed(Sql, Parameters) ->
    {ok, Conn} = minato_conn:connect(connection()),
    {ok, #{rows := [{Count}]}, Read} = minato_query:query(Conn, Sql, Parameters),
    ok = minato_conn:close(Read),
    Count.

eventually(Holds) ->
    eventually(Holds, 250).

eventually(_Holds, 0) ->
    {error, never_held};
eventually(Holds, Attempts) ->
    case Holds() of
        true ->
            ok;
        false ->
            timer:sleep(20),
            eventually(Holds, Attempts - 1)
    end.

named(Connection) ->
    Connection#{parameters => #{~"application_name" => ?NAME}}.

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
