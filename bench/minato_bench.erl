-module(minato_bench).
-moduledoc """
minato against the other Erlang PostgreSQL clients, on the same workloads.

`pgo` here is `erleans/pgo` from Hex, not the fork the test profile uses as a
transport: the number worth having is against the client somebody else would
install.

Run it with:

```
docker compose -f test/docker-compose.yml up -d
rebar3 as bench compile
rebar3 as bench shell --eval 'minato_bench:main([]), halt(0).'
```

## What is being measured

A client benchmark against a database on the same machine measures the client,
which is the point: the server does the same work for everybody, so what is left
is round trips, framing, decoding and whatever the client does between them. It
is not a measure of how fast PostgreSQL is, and it says nothing about a network
with a real round trip time, where everybody's numbers converge.

The workloads are chosen to separate those costs:

- `simple` is the round trip floor: the simple query protocol, one message out,
  nothing to bind, nothing to describe. `pgo` has no simple path, so it has no
  number here.
- `unnamed` is the extended protocol with nothing kept: parse, describe, bind,
  execute, sync, every time. `pgo` caches statements itself and cannot be asked
  not to, so it has no number here either. This row is what a client costs when
  the caller avoids its cache.
- `cached` is the same statement kept per connection, which is what all three
  do by default: `minato_query:cached/4`, pgo's own cache, and `prepared_query`
  in epgsql. This is the comparison that matters, and every row below it is run
  the same way.
- `rows_1000` and `rows_5000` are where framing shows up. A client that reads a
  five byte header and then a payload does two reads per row; one that reads
  whatever arrived does a handful in total.
- `wide_row` is one row of 64 columns, which is decoding rather than framing.
- `insert` writes, so the server does real work and the client's share shrinks.
- `concurrent` runs eight processes at once, one connection each: minato and pgo
  through their pools, epgsql through eight connections opened for it, since it
  has no pool of its own. One connection per caller is the best case for every
  client and takes queueing out of the comparison, which is a pool question
  rather than a client one.

## Fairness

Every client gets the same statement, the same parameters, the same iteration
count, and a warmup that is thrown away. Sequential workloads run on one
connection each; the concurrent one runs on a pool of the same size for
everybody. Timings are per operation, and the report gives the median and the
99th percentile as well as the mean, because a mean hides the tail that a
connection pool exists to manage.

Numbers move with the machine. What is worth reading is the ratio between
clients on the same run, and a difference under about ten percent is noise.
""".

-export([main/1, run/1, iterations/1, json/1]).
%% For minato_profile, which measures the same workloads a different way.
-export([setup/1, prepare_schema/2, parsed/2, runner/3, teardown/2]).

-define(DEFAULT_ITERATIONS, 2000).
-define(DEFAULT_WARMUP, 200).
-define(POOL_SIZE, 8).
-define(WORKERS, 8).

-doc "Run every workload against every client and print the report.".
-spec main([string()]) -> ok.
main(Args) ->
    process_flag(trap_exit, true),
    Iterations = iterations(Args),
    ok = application:ensure_started(crypto),
    Results = run(Iterations),
    report(Results, Iterations).

-doc "Run every workload against every client and answer the measurements.".
-spec run(pos_integer()) -> [map()].
run(Iterations) ->
    Clients = [minato, pgo, epgsql],
    Ready = [{Client, started(Client)} || Client <- Clients],
    Results = [
        measured(Client, Setup, Workload, Iterations)
     || Workload <- workloads(), {Client, Setup} <- Ready
    ],
    _ = [teardown(Client, Setup) || {Client, Setup} <- Ready],
    Results.

started(Client) ->
    Setup = setup(Client),
    ok = prepare_schema(Client, Setup),
    parsed(Client, Setup).

workloads() ->
    [simple, unnamed, cached, rows_1000, rows_5000, wide_row, insert, concurrent].

%%----------------------------------------------------------------------
%% Measuring
%%----------------------------------------------------------------------

measured(Client, Setup, Workload, Iterations) ->
    io:format("  ~s ~s~n", [Workload, Client]),
    case runner(Client, Workload, Setup) of
        unsupported -> #{client => Client, workload => Workload, samples => 0};
        Run -> timed(Client, Workload, Run, Iterations)
    end.

timed(Client, Workload, Run, Iterations) ->
    _ = repeat(Run, warmup(Iterations)),
    Samples = repeat(Run, count(Workload, Iterations)),
    #{
        client => Client,
        workload => Workload,
        samples => length(Samples),
        mean => mean(Samples),
        median => percentile(Samples, 50),
        p99 => percentile(Samples, 99),
        per_second => per_second(Samples)
    }.

count(concurrent, Iterations) -> max(1, Iterations div 20);
count(rows_5000, Iterations) -> max(1, Iterations div 20);
count(rows_1000, Iterations) -> max(1, Iterations div 5);
count(_Workload, Iterations) -> Iterations.

warmup(Iterations) ->
    min(?DEFAULT_WARMUP, Iterations).

repeat(_Run, 0) ->
    [];
repeat(Run, N) ->
    Start = erlang:monotonic_time(microsecond),
    ok = Run(),
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    [Elapsed | repeat(Run, N - 1)].

%%----------------------------------------------------------------------
%% The workloads, per client
%%----------------------------------------------------------------------

runner(minato, simple, _Setup) ->
    stateful(fun(C) -> minato_query:simple(C, ~"SELECT 1") end);
runner(minato, unnamed, _Setup) ->
    stateful(fun(C) -> minato_query:query(C, ~"SELECT $1::int4", [42]) end);
runner(minato, cached, _Setup) ->
    stateful(fun(C) -> minato_query:cached(C, ~"SELECT $1::int4", [42]) end);
runner(minato, rows_1000, _Setup) ->
    stateful(fun(C) -> minato_query:cached(C, rows_sql(1000), []) end);
runner(minato, rows_5000, _Setup) ->
    stateful(fun(C) -> minato_query:cached(C, rows_sql(5000), []) end);
runner(minato, wide_row, _Setup) ->
    stateful(fun(C) -> minato_query:cached(C, wide_sql(), []) end);
runner(minato, insert, _Setup) ->
    stateful(fun(C) -> minato_query:cached(C, insert_sql(), [1, ~"a"]) end);
runner(minato, concurrent, _Setup) ->
    fun() ->
        concurrently(fun(_Worker) -> minato:query(bench_pool, ~"SELECT $1::int4", [42]) end)
    end;
runner(pgo, simple, _Setup) ->
    unsupported;
runner(pgo, unnamed, _Setup) ->
    unsupported;
runner(pgo, cached, _Setup) ->
    fun() -> ran(pgo:query(~"SELECT $1::int4", [42])) end;
runner(pgo, rows_1000, _Setup) ->
    fun() -> ran(pgo:query(rows_sql(1000), [])) end;
runner(pgo, rows_5000, _Setup) ->
    fun() -> ran(pgo:query(rows_sql(5000), [])) end;
runner(pgo, wide_row, _Setup) ->
    fun() -> ran(pgo:query(wide_sql(), [])) end;
runner(pgo, insert, _Setup) ->
    fun() -> ran(pgo:query(insert_sql(), [1, ~"a"])) end;
runner(pgo, concurrent, _Setup) ->
    fun() -> concurrently(fun(_Worker) -> ran(pgo:query(~"SELECT $1::int4", [42])) end) end;
runner(epgsql, simple, #{conn := Conn}) ->
    fun() -> ran(epgsql:squery(Conn, "SELECT 1")) end;
runner(epgsql, unnamed, #{conn := Conn}) ->
    fun() -> ran(epgsql:equery(Conn, "SELECT $1::int4", [42])) end;
runner(epgsql, cached, #{conn := Conn, statements := #{cached := Statement}}) ->
    fun() -> ran(epgsql:prepared_query(Conn, Statement, [42])) end;
runner(epgsql, rows_1000, #{conn := Conn, statements := #{rows_1000 := Statement}}) ->
    fun() -> ran(epgsql:prepared_query(Conn, Statement, [])) end;
runner(epgsql, rows_5000, #{conn := Conn, statements := #{rows_5000 := Statement}}) ->
    fun() -> ran(epgsql:prepared_query(Conn, Statement, [])) end;
runner(epgsql, wide_row, #{conn := Conn, statements := #{wide_row := Statement}}) ->
    fun() -> ran(epgsql:prepared_query(Conn, Statement, [])) end;
runner(epgsql, insert, #{conn := Conn, statements := #{insert := Statement}}) ->
    fun() -> ran(epgsql:prepared_query(Conn, Statement, [1, "a"])) end;
runner(epgsql, concurrent, #{pool := Pool}) ->
    fun() -> concurrently(fun(Worker) -> epgsql_own(Pool, Worker) end) end.

stateful(Fun) ->
    fun() ->
        Held = held(),
        case Fun(Held) of
            {ok, _Result, Next} ->
                holding(Next),
                ok;
            {ok, _Results, Next, _More} ->
                holding(Next),
                ok;
            Other ->
                error({minato_bench, Other})
        end
    end.

held() ->
    get({?MODULE, conn}).

holding(Conn) ->
    put({?MODULE, conn}, Conn),
    ok.

ran(#{command := _Command}) -> ok;
ran({ok, _Columns, _Rows}) -> ok;
ran({ok, _Count}) -> ok;
ran({ok, _Count, _Columns, _Rows}) -> ok;
ran(ok) -> ok;
ran(Other) -> error({minato_bench, Other}).

concurrently(Fun) ->
    Parent = self(),
    Workers = [spawn(fun() -> Parent ! {done, self(), Fun(N)} end) || N <- workers()],
    ok = joined(Workers).

workers() ->
    lists:seq(1, ?WORKERS).

joined([]) ->
    ok;
joined([Pid | Rest]) ->
    receive
        {done, Pid, _Answer} -> joined(Rest)
    after 30000 -> error({minato_bench, {worker_timeout, Pid}})
    end.

epgsql_own(Connections, Worker) ->
    ran(epgsql:equery(lists:nth(Worker, Connections), "SELECT $1::int4", [42])).

%%----------------------------------------------------------------------
%% Statements
%%----------------------------------------------------------------------

rows_sql(Rows) ->
    <<"SELECT i, repeat('x', 32) FROM generate_series(1, ", (integer_to_binary(Rows))/binary,
        ") i">>.

wide_sql() ->
    Columns = [<<"i * ", (integer_to_binary(N))/binary>> || N <- lists:seq(1, 64)],
    <<"SELECT ", (join(Columns))/binary, " FROM generate_series(1, 1) i">>.

insert_sql() ->
    ~"INSERT INTO minato_bench (n, name) VALUES ($1, $2)".

join([Only]) -> Only;
join([Head | Rest]) -> <<Head/binary, ", ", (join(Rest))/binary>>.

%%----------------------------------------------------------------------
%% Setting each client up
%%----------------------------------------------------------------------

setup(minato) ->
    {ok, _Started} = application:ensure_all_started(minato),
    {ok, Conn} = minato_conn:connect(connection()),
    ok = holding(Conn),
    {ok, _Pool} = minato:start_pool(bench_pool, #{
        size => ?POOL_SIZE, connection => connection()
    }),
    #{conn => Conn};
setup(pgo) ->
    {ok, _Started} = application:ensure_all_started(pgo),
    {ok, _Pool} = pgo:start_pool(default, pgo_config()),
    #{};
setup(epgsql) ->
    {ok, _Started} = application:ensure_all_started(epgsql),
    {ok, Conn} = epgsql:connect(epgsql_config()),
    Pool = [element(2, epgsql:connect(epgsql_config())) || _N <- lists:seq(1, ?POOL_SIZE)],
    #{conn => Conn, pool => Pool}.

prepare_schema(minato, #{conn := Conn}) ->
    {ok, _Results, Ready} = minato_query:simple(Conn, schema()),
    holding(Ready);
prepare_schema(pgo, _Setup) ->
    _ = pgo:query(schema(), []),
    ok;
prepare_schema(epgsql, #{conn := Conn}) ->
    _ = epgsql:squery(Conn, binary_to_list(schema())),
    ok.

parsed(epgsql, #{conn := Conn} = Setup) ->
    Named = [
        {cached, "bench_cached", "SELECT $1::int4"},
        {rows_1000, "bench_rows_1000", binary_to_list(rows_sql(1000))},
        {rows_5000, "bench_rows_5000", binary_to_list(rows_sql(5000))},
        {wide_row, "bench_wide", binary_to_list(wide_sql())},
        {insert, "bench_insert", binary_to_list(insert_sql())}
    ],
    Statements = #{
        Key => element(2, epgsql:parse(Conn, Name, Sql, []))
     || {Key, Name, Sql} <- Named
    },
    Setup#{statements => Statements};
parsed(_Client, Setup) ->
    Setup.

teardown(minato, _Setup) ->
    ok = minato_conn:close(held()),
    _ = minato:stop_pool(bench_pool),
    ok;
teardown(pgo, _Setup) ->
    ok;
teardown(epgsql, #{conn := Conn, pool := Pool}) ->
    _ = [epgsql:close(Each) || Each <- Pool],
    ok = epgsql:close(Conn),
    ok.

schema() ->
    ~"""
    DROP TABLE IF EXISTS minato_bench;
    CREATE UNLOGGED TABLE minato_bench (n int4, name text)
    """.

%%----------------------------------------------------------------------
%% Where the server is
%%----------------------------------------------------------------------

connection() ->
    #{
        host => host(),
        port => port(),
        user => list_to_binary(user()),
        password => list_to_binary(password()),
        database => list_to_binary(database()),
        timeout => 30000
    }.

pgo_config() ->
    #{
        host => host(),
        port => port(),
        database => database(),
        user => user(),
        password => password(),
        pool_size => ?POOL_SIZE
    }.

epgsql_config() ->
    #{
        host => host(),
        port => port(),
        database => database(),
        username => user(),
        password => password(),
        timeout => 30000
    }.

host() -> env("MINATO_PG_HOST", "127.0.0.1").
port() -> list_to_integer(env("MINATO_PG_PORT", "55432")).
database() -> env("MINATO_PG_DATABASE", "minato_test").
user() -> env("MINATO_PG_USER", "minato").
password() -> env("MINATO_PG_PASSWORD", "minato").

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.

-doc "How many iterations to run: the argument, the environment, or the default.".
-spec iterations([string()]) -> pos_integer().
iterations([]) ->
    list_to_integer(env("MINATO_BENCH_ITERATIONS", integer_to_list(?DEFAULT_ITERATIONS)));
iterations([Given | _Rest]) ->
    list_to_integer(Given).

-doc "The measurements as JSON, for the runner that puts every language in one table.".
-spec json([map()]) -> iodata().
json(Results) ->
    [$[, lists:join($,, [object(Result) || Result <- Results]), $]].

object(#{client := Client, workload := Workload, samples := 0}) ->
    io_lib:format(~'{"client":"~s","workload":"~s"}', [Client, Workload]);
object(Result) ->
    #{client := Client, workload := Workload} = Result,
    #{mean := Mean, median := Median, p99 := P99, per_second := Rate} = Result,
    io_lib:format(
        ~'{"client":"~s","workload":"~s","mean":~.1f,"median":~w,"p99":~w,"ops":~.1f}',
        [Client, Workload, Mean, Median, P99, Rate]
    ).

%%----------------------------------------------------------------------
%% Statistics and the report
%%----------------------------------------------------------------------

mean(Samples) ->
    lists:sum(Samples) / length(Samples).

percentile(Samples, Percent) ->
    Sorted = lists:sort(Samples),
    Index = max(1, round(length(Sorted) * Percent / 100)),
    lists:nth(min(Index, length(Sorted)), Sorted).

per_second(Samples) ->
    Total = lists:sum(Samples),
    case Total of
        0 -> 0.0;
        _Microseconds -> length(Samples) * 1000000 / Total
    end.

report(Results, Iterations) ->
    io:format("~nminato benchmark, ~p iterations, OTP ~s~n~n", [
        Iterations, erlang:system_info(otp_release)
    ]),
    io:format("~-12s ~-10s ~10s ~10s ~10s ~12s~n", [
        "workload", "client", "mean us", "median", "p99", "ops/s"
    ]),
    io:format("~s~n", [lists:duplicate(70, $-)]),
    _ = [line(Result) || Result <- Results],
    io:format("~n"),
    ok.

line(#{workload := Workload, client := Client, samples := 0}) ->
    io:format("~-12s ~-10s ~10s ~10s ~10s ~12s~n", [
        atom_to_list(Workload), atom_to_list(Client), "-", "-", "-", "-"
    ]);
line(#{workload := Workload, client := Client} = Result) ->
    #{mean := Mean, median := Median, p99 := P99, per_second := Rate} = Result,
    io:format("~-12s ~-10s ~10.1f ~10w ~10w ~12w~n", [
        atom_to_list(Workload), atom_to_list(Client), Mean, Median, P99, round(Rate)
    ]).
