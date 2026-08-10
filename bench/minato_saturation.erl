-module(minato_saturation).
-moduledoc """
How many queries a second, at a concurrency, and what is stopping it.

`m:minato_bench` measures one operation at a time, which answers what a query
costs. It does not answer the question that usually matters, which is what
happens when a node is busy: a client that costs less per operation only goes
faster if the client was what the operations were waiting for.

This runs a fixed pool of connections, points a growing number of processes at
it, and counts what comes back. Three numbers per row:

- `queries/s` is the throughput, which is the answer.
- `us/op` is what one caller waited, which grows with the queue rather than with
  the work.
- `busy %` is how much of the wall time the schedulers were not idle, measured
  as a delta across the run rather than since the node booted. It is the number
  that says whether the BEAM was the constraint. If throughput has stopped
  climbing and this is still low, the ceiling is the server or the round trip,
  and no amount of work on the client will lift it.

```
docker compose -f test/docker-compose.yml up -d
rebar3 as bench compile
erl -noshell -pa _build/bench/lib/*/ebin _build/bench/lib/minato/bench \\
    -eval 'minato_saturation:run(), init:stop().'
```

`pgo` and both minato transports get the same pool and the same statement.
`epgsql` has no pool, and two callers sharing one of its connections interleave
their parse and bind on the unnamed statement, which the server answers with
`26000`: it gets a connection per caller instead. That is more connections than
the others are allowed at the higher rows and is meant to be - a client given
more than its share and still stopping at the same number is the clearest way to
show that the number is not the client's.
""".

-export([run/0, run/1]).

-define(DEFAULT_SECONDS, 6).
-define(DEFAULT_CONNECTIONS, 16).
-define(CONCURRENCIES, [1, 8, 32, 64]).

-doc "Run every client at every concurrency and print the table.".
-spec run() -> ok.
run() ->
    run(seconds()).

-doc "`run/0` holding each concurrency for a given number of seconds.".
-spec run(pos_integer()) -> ok.
run(Seconds) ->
    _ = erlang:system_flag(scheduler_wall_time, true),
    ok = application:ensure_started(crypto),
    io:format("~nminato saturation, ~w connections, ~w seconds a row~n~n", [
        connections(), Seconds
    ]),
    io:format("~-16s ~9s ~12s ~12s ~10s~n", [
        "client", "workers", "queries/s", "us/op", "busy %"
    ]),
    io:format("~s~n", [lists:duplicate(63, $-)]),
    _ = [row(Client, Workers, Seconds) || Client <- clients(), Workers <- ?CONCURRENCIES],
    ok.

clients() ->
    [{minato, inet}, {minato, socket}, {pgo, pool}, {epgsql, own}].

%%----------------------------------------------------------------------
%% One row
%%----------------------------------------------------------------------

row(Client, Workers, Seconds) ->
    Held = setup(Client, Workers),
    Run = runner(Client, Held),
    _ = warmed(Run, warmup(Client)),
    Before = erlang:statistics(scheduler_wall_time),
    Start = erlang:monotonic_time(millisecond),
    Total = hammered(Run, Workers, Start + Seconds * 1000),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    After = erlang:statistics(scheduler_wall_time),
    io:format("~-16s ~9w ~12.1f ~12.1f ~10.1f~n", [
        name(Client),
        Workers,
        Total * 1000 / Elapsed,
        Elapsed * 1000 * Workers / Total,
        busy(Before, After)
    ]),
    teardown(Client, Held).

hammered(Run, Workers, Deadline) ->
    Parent = self(),
    Pids = [
        spawn_monitor(fun() -> Parent ! {done, self(), until(Run, Deadline, 0)} end)
     || Worker <- lists:seq(1, Workers), is_integer(Worker)
    ],
    joined(Pids, 0).

until(Run, Deadline, Count) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true ->
            ok = Run(),
            until(Run, Deadline, Count + 1);
        false ->
            Count
    end.

joined([], Total) ->
    Total;
joined([{Pid, Ref} | Rest], Total) ->
    receive
        {done, Pid, Count} ->
            demonitor(Ref, [flush]),
            joined(Rest, Total + Count);
        {'DOWN', Ref, process, Pid, Reason} ->
            error({minato_saturation, {worker_died, Reason}})
    after 120000 -> error({minato_saturation, {worker_timeout, Pid}})
    end.

warmed(_Run, 0) -> ok;
warmed(Run, N) -> ok = Run(), warmed(Run, N - 1).

%% The warm up runs in this process, which for epgsql would take a connection
%% one of the workers needs.
warmup({epgsql, _How}) -> 0;
warmup(_Pooled) -> 200.

%%----------------------------------------------------------------------
%% What the schedulers did while that happened
%%----------------------------------------------------------------------

busy(Before, After) ->
    {Active, Wall} = spent(lists:sort(Before), lists:sort(After), 0, 0),
    percentage(Active, Wall).

spent([], [], Active, Wall) ->
    {Active, Wall};
spent([{Id, A0, T0} | Before], [{Id, A1, T1} | After], Active, Wall) ->
    spent(Before, After, Active + A1 - A0, Wall + T1 - T0);
spent(_Before, _After, Active, Wall) ->
    {Active, Wall}.

percentage(_Active, 0) -> 0.0;
percentage(Active, Wall) -> Active * 100 / Wall.

%%----------------------------------------------------------------------
%% The clients
%%----------------------------------------------------------------------

name({minato, Transport}) -> "minato (" ++ atom_to_list(Transport) ++ ")";
name({Client, _How}) -> atom_to_list(Client).

runner({minato, _Transport}, Name) ->
    fun() -> ran(minato:query(Name, sql(), [1])) end;
runner({pgo, _How}, _Held) ->
    fun() -> ran(pgo:query(sql(), [1])) end;
runner({epgsql, _How}, Connections) ->
    Next = atomics:new(1, []),
    fun() ->
        ran(epgsql:equery(taken(Connections, Next), "SELECT $1::int4", [1]))
    end.

%% Each worker takes the next connection the first time it runs and keeps it,
%% because two of them on one connection interleave their parse and bind on the
%% unnamed statement and the server answers 26000. Taking it has to be one
%% operation for the same reason: a read after an add is two, and two workers
%% got the same connection often enough to be the first thing this measured.
taken(Connections, Next) ->
    case get({?MODULE, connection}) of
        undefined ->
            Mine = lists:nth(atomics:add_get(Next, 1, 1), Connections),
            put({?MODULE, connection}, Mine),
            Mine;
        Mine ->
            Mine
    end.

ran({ok, #{command := _Command}}) -> ok;
ran(#{command := _Command}) -> ok;
ran({ok, _Columns, _Rows}) -> ok;
ran(Other) -> error({minato_saturation, Other}).

setup({minato, Transport}, _Workers) ->
    {ok, _Started} = application:ensure_all_started(minato),
    Name = list_to_atom("minato_saturation_" ++ atom_to_list(Transport)),
    {ok, _Pool} = minato:start_pool(Name, #{
        size => connections(), min_size => connections(), connection => connection(Transport)
    }),
    Name;
setup({pgo, _How}, _Workers) ->
    {ok, _Started} = application:ensure_all_started(pgo),
    {ok, _Pool} = pgo:start_pool(default, pgo_config()),
    default;
setup({epgsql, _How}, Workers) ->
    {ok, _Started} = application:ensure_all_started(epgsql),
    [element(2, epgsql:connect(epgsql_config())) || _N <- lists:seq(1, Workers)].

teardown({minato, _Transport}, Name) ->
    _ = minato:stop_pool(Name),
    ok;
teardown({pgo, _How}, _Held) ->
    ok = application:stop(pgo);
teardown({epgsql, _How}, Connections) ->
    _ = [epgsql:close(Each) || Each <- Connections],
    ok.

sql() -> ~"SELECT $1::int4".

connection(inet) ->
    base();
connection(socket) ->
    (base())#{transport => socket}.

base() ->
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
        pool_size => connections()
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

seconds() ->
    list_to_integer(env("MINATO_SATURATION_SECONDS", integer_to_list(?DEFAULT_SECONDS))).

-doc false.
-spec connections() -> pos_integer().
connections() ->
    list_to_integer(env("MINATO_SATURATION_CONNECTIONS", integer_to_list(?DEFAULT_CONNECTIONS))).

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
