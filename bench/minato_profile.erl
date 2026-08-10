-module(minato_profile).
-moduledoc """
Where a query's time goes, rather than how long it takes.

`bench/run.sh` measures wall clock, which against a database on the same machine
is mostly the round trip: every client waits the same and the differences hide in
the noise. This module measures the work instead.

- `cost/0` runs each workload on each Erlang client and reports total system
  reductions and scheduler run time per operation. Reductions are not
  microseconds, but they do not move with the machine, the server or the load,
  so a change of five percent is a change rather than a run-to-run wobble.
- `eprof/1` runs one minato workload under `eprof` and prints where the calls
  are.

```
docker compose -f test/docker-compose.yml up -d
rebar3 as bench compile
erl -noshell -pa _build/bench/lib/*/ebin _build/bench/lib/minato/bench \\
    -eval 'minato_profile:cost(), init:stop().'
```
""".

-export([cost/0, cost/1, eprof/1, eprof/2]).

-define(DEFAULT_ITERATIONS, 2000).
-define(DEFAULT_EPROF_ITERATIONS, 200).

-doc "Reductions and run time per operation, every workload on every client.".
-spec cost() -> ok.
cost() ->
    cost(iterations()).

-doc "`cost/0` over a given number of iterations.".
-spec cost(pos_integer()) -> ok.
cost(Iterations) ->
    _ = erlang:system_flag(scheduler_wall_time, true),
    Clients = [minato, pgo, epgsql],
    Ready = [{Client, setup(Client)} || Client <- Clients],
    Rows = [
        {Workload, Client, measure(Client, Workload, Setup, Iterations)}
     || Workload <- workloads(), {Client, Setup} <- Ready
    ],
    report(Rows, Iterations),
    _ = [teardown(Client, Setup) || {Client, Setup} <- Ready],
    ok.

-doc "Run one minato workload under `eprof` and print the profile.".
-spec eprof(atom()) -> ok.
eprof(Workload) ->
    eprof(Workload, ?DEFAULT_EPROF_ITERATIONS).

-doc "`eprof/1` over a given number of iterations.".
-spec eprof(atom(), pos_integer()) -> ok.
eprof(Workload, Iterations) ->
    Setup = setup(minato),
    Run = runner(minato, Workload, Setup),
    repeat(Run, 100),
    {ok, _Pid} = eprof:start(),
    profiling = eprof:start_profiling(processes()),
    repeat(Run, Iterations),
    profiling_stopped = eprof:stop_profiling(),
    eprof:analyze(total),
    eprof:stop(),
    teardown(minato, Setup),
    ok.

%%----------------------------------------------------------------------
%% Measuring the work rather than the wait
%%----------------------------------------------------------------------

measure(Client, Workload, Setup, Iterations) ->
    case runner(Client, Workload, Setup) of
        unsupported ->
            unsupported;
        Run ->
            Count = count(Workload, Iterations),
            repeat(Run, min(200, Count)),
            _ = erlang:statistics(reductions),
            Before = scheduler_time(),
            {_Total, _Since} = erlang:statistics(reductions),
            Start = erlang:monotonic_time(microsecond),
            repeat(Run, Count),
            Elapsed = erlang:monotonic_time(microsecond) - Start,
            {_Again, Reductions} = erlang:statistics(reductions),
            Busy = scheduler_time() - Before,
            #{
                reductions => Reductions / Count,
                busy_us => Busy / Count,
                elapsed_us => Elapsed / Count
            }
    end.

scheduler_time() ->
    lists:sum([Active || {_Id, Active, _Total} <- erlang:statistics(scheduler_wall_time)]) /
        1000.

report(Rows, Iterations) ->
    io:format("~nminato cost profile, ~w iterations~n~n", [Iterations]),
    io:format("~-12s ~-10s ~12s ~12s ~12s~n", [
        "workload", "client", "reductions", "busy us", "elapsed us"
    ]),
    io:format("~s~n", [lists:duplicate(62, $-)]),
    _ = [line(Workload, Client, Measured) || {Workload, Client, Measured} <- Rows],
    ok.

line(_Workload, _Client, unsupported) ->
    ok;
line(Workload, Client, #{reductions := Reductions, busy_us := Busy, elapsed_us := Elapsed}) ->
    io:format("~-12s ~-10s ~12.1f ~12.1f ~12.1f~n", [Workload, Client, Reductions, Busy, Elapsed]).

repeat(_Run, 0) ->
    ok;
repeat(Run, N) ->
    ok = Run(),
    repeat(Run, N - 1).

workloads() ->
    [simple, unnamed, cached, rows_1000, rows_5000, wide_row, insert].

count(rows_5000, Iterations) -> max(1, Iterations div 20);
count(rows_1000, Iterations) -> max(1, Iterations div 5);
count(_Workload, Iterations) -> Iterations.

iterations() ->
    case os:getenv("MINATO_BENCH_ITERATIONS") of
        false -> ?DEFAULT_ITERATIONS;
        "" -> ?DEFAULT_ITERATIONS;
        Value -> list_to_integer(Value)
    end.

%%----------------------------------------------------------------------
%% Everything below borrows the benchmark's own setup and workloads
%%----------------------------------------------------------------------

setup(Client) ->
    _ = application:ensure_started(crypto),
    Setup = minato_bench_setup(Client),
    Setup.

minato_bench_setup(Client) ->
    Setup = minato_bench:setup(Client),
    ok = minato_bench:prepare_schema(Client, Setup),
    minato_bench:parsed(Client, Setup).

runner(Client, Workload, Setup) ->
    minato_bench:runner(Client, Workload, Setup).

teardown(Client, Setup) ->
    minato_bench:teardown(Client, Setup).
