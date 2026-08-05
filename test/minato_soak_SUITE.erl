-module(minato_soak_SUITE).
-moduledoc """
Sustained concurrent load, and what the pool looks like afterwards.

The suites before this one prove single steps: one query, one transaction, one
borrower that dies. None of them can show what a client does over thousands of
operations from many processes at once, which is where a driver leaks
connections, loses track of what it lent, or ends up one message out of step and
answers the next caller with the last caller's rows.

Every worker checks its own answers. A `SELECT` that returns the row the same
worker just wrote is the assertion that matters: it fails if a connection is
handed out with somebody else's bytes on it, which is the failure a soak exists
to find and a unit test cannot. It is only asserted when the write it follows
was acknowledged, because a write the server never saw has nothing to read back
and the case that kills backends mid-run makes exactly that happen.

Then the pool is measured at rest. Every connection back, none borrowed, nobody
waiting, and as many idle as the pool was told to keep. A driver that loses a
connection per thousand operations looks perfect in a unit test and dies on a
Friday.

`MINATO_SOAK_SECONDS` sets how long each load case runs. The default is short
enough for CI; the number to run before believing anything is minutes, not
seconds.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    sustained_load_is_answered_correctly/1,
    load_survives_the_server_dropping_backends/1,
    callers_that_die_do_not_leak_connections/1
]).

-define(TIMEOUT, 10000).
-define(POOL, minato_soak_pool).
-define(SIZE, 8).
-define(WORKERS, 16).

-spec all() -> [atom()].
all() ->
    [
        sustained_load_is_answered_correctly,
        load_survives_the_server_dropping_backends,
        callers_that_die_do_not_leak_connections
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
init_per_testcase(_Case, Config) ->
    {ok, _Pid} = minato:start_pool(?POOL, #{size => ?SIZE, connection => connection()}),
    ok = settled(?SIZE, 200),
    {ok, _Results} = minato:simple(?POOL, ~"TRUNCATE minato_soak"),
    Config.

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(_Case, _Config) ->
    ok = minato:stop_pool(?POOL).

-spec sustained_load_is_answered_correctly([{atom(), term()}]) -> ok.
sustained_load_is_answered_correctly(_Config) ->
    Reports = load(?WORKERS, seconds()),
    ?assertEqual([], [Failed || #{failures := Failed} <- Reports, Failed =/= []]),
    Operations = lists:sum([Done || #{operations := Done} <- Reports]),
    ?assert(Operations > ?WORKERS),
    ok = settled(?SIZE, 200),
    ?assertMatch(#{borrowed := 0, waiting := 0, disconnects := 0}, minato:stats(?POOL)).

-spec load_survives_the_server_dropping_backends([{atom(), term()}]) -> ok.
load_survives_the_server_dropping_backends(_Config) ->
    Killer = spawn(fun() -> kill_backends(seconds()) end),
    Reports = load(?WORKERS, seconds()),
    ok = buried([Killer], 500),
    Operations = lists:sum([Done || #{operations := Done} <- Reports]),
    ?assert(Operations > ?WORKERS),
    ?assertEqual([], [Wrong || #{wrong := Wrong} <- Reports, Wrong =/= []]),
    ok = settled(?SIZE, 500),
    ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])).

-spec callers_that_die_do_not_leak_connections([{atom(), term()}]) -> ok.
callers_that_die_do_not_leak_connections(_Config) ->
    Dying = [
        spawn(fun() ->
            {ok, _Conn} = minato_pool:checkout(?POOL, ?TIMEOUT),
            exit(kill)
        end)
     || _Each <- lists:seq(1, ?SIZE * 4)
    ],
    ok = buried(Dying, 200),
    ok = settled(?SIZE, 500),
    ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])).

%%----------------------------------------------------------------------
%% The load
%%----------------------------------------------------------------------

load(Workers, Seconds) ->
    Test = self(),
    Deadline = erlang:monotonic_time(millisecond) + Seconds * 1000,
    Running = [
        spawn_link(fun() -> Test ! {report, self(), worked(Worker, Deadline)} end)
     || Worker <- lists:seq(1, Workers)
    ],
    [reported(Pid) || Pid <- Running].

reported(Pid) ->
    receive
        {report, Pid, Report} -> Report
    after seconds() * 1000 + ?TIMEOUT * 3 -> error({worker_never_reported, Pid})
    end.

worked(Worker, Deadline) ->
    worked(Worker, Deadline, #{operations => 0, failures => [], wrong => []}).

worked(Worker, Deadline, Report) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true -> worked(Worker, Deadline, operation(Worker, Report));
        false -> Report
    end.

operation(Worker, #{operations := Done} = Report) ->
    Name = <<"worker-", (integer_to_binary(Worker))/binary, "-", (integer_to_binary(Done))/binary>>,
    Counted = Report#{operations := Done + 1},
    case Done rem 4 of
        0 -> written(Name, Counted);
        1 -> written_then_read(Name, Counted);
        2 -> in_a_transaction(Name, Counted);
        3 -> refused(Counted)
    end.

written(Name, Report) ->
    judged(minato:query(?POOL, ~"INSERT INTO minato_soak (name) VALUES ($1)", [Name]), Report).

written_then_read(Name, Report) ->
    case minato:query(?POOL, ~"INSERT INTO minato_soak (name) VALUES ($1)", [Name]) of
        {ok, _Result} -> read_back(Name, Report);
        {error, {socket, _Reason}} -> Report;
        {error, {pgsql_error, _Fields}} -> Report;
        {error, Reason} -> failed(Report, {write, Reason})
    end.

read_back(Name, Report) ->
    Answer = minato:query(?POOL, ~"SELECT name FROM minato_soak WHERE name = $1", [Name]),
    case Answer of
        {ok, #{rows := [{Name}]}} -> Report;
        {ok, Other} -> mistaken(Report, {read_back, Name, Other});
        {error, {socket, _Reason}} -> Report;
        {error, Reason} -> failed(Report, {read_back, Reason})
    end.

in_a_transaction(Name, Report) ->
    Answer = minato:transaction(?POOL, fun(Conn) ->
        case minato_query:query(Conn, ~"INSERT INTO minato_soak (name) VALUES ($1)", [Name]) of
            {ok, _Result, Written} -> {ok, done, Written};
            {error, Reason, Failed} -> {rollback, Reason, Failed};
            {error, Reason} -> {error, Reason}
        end
    end),
    case Answer of
        {ok, done} -> Report;
        {rollback, _Reason} -> Report;
        {error, {socket, _Reason}} -> Report;
        {error, Reason} -> failed(Report, {transaction, Reason})
    end.

refused(Report) ->
    case minato:query(?POOL, ~"SELECT * FROM minato_no_such_table", []) of
        {error, {pgsql_error, #{code := ~"42P01"}}} -> Report;
        {error, {socket, _Reason}} -> Report;
        Other -> mistaken(Report, {expected_a_refusal, Other})
    end.

judged({ok, _Result}, Report) -> Report;
judged({error, {pgsql_error, _Fields}}, Report) -> Report;
judged({error, {socket, _Reason}}, Report) -> Report;
judged({error, Reason}, Report) -> failed(Report, Reason).

failed(#{failures := Failures} = Report, Reason) ->
    Report#{failures := [Reason | Failures]}.

mistaken(#{wrong := Wrong} = Report, What) ->
    Report#{wrong := [What | Wrong]}.

%%----------------------------------------------------------------------
%% Making the server misbehave
%%----------------------------------------------------------------------

kill_backends(Seconds) ->
    kill_backends(erlang:monotonic_time(millisecond) + Seconds * 1000, connection()).

kill_backends(Deadline, Opts) ->
    timer:sleep(700),
    case erlang:monotonic_time(millisecond) < Deadline of
        true ->
            _ = killed(Opts),
            kill_backends(Deadline, Opts);
        false ->
            ok
    end.

killed(Opts) ->
    Sql =
        ~"""
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE application_name = 'minato_soak' AND pid <> pg_backend_pid()
        LIMIT 2
        """,
    case minato_conn:connect(Opts) of
        {ok, Conn} -> terminating(Conn, Sql);
        {error, _Reason} -> ok
    end.

terminating(Conn, Sql) ->
    case minato_query:query(Conn, Sql, []) of
        {ok, _Result, Read} -> minato_conn:close(Read);
        {error, _Reason, Read} -> minato_conn:close(Read);
        {error, _Reason} -> ok
    end.

%%----------------------------------------------------------------------
%% Waiting for things to be over
%%----------------------------------------------------------------------

settled(_Size, 0) ->
    {error, never_settled};
settled(Size, Attempts) ->
    case minato:stats(?POOL) of
        #{idle := Idle, borrowed := 0} when Idle >= Size -> ok;
        _Busy ->
            timer:sleep(20),
            settled(Size, Attempts - 1)
    end.

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

seconds() ->
    list_to_integer(env("MINATO_SOAK_SECONDS", "5")).

schema() ->
    ~"""
    DROP TABLE IF EXISTS minato_soak;
    CREATE TABLE minato_soak (name text PRIMARY KEY)
    """.

connection() ->
    #{
        host => env("MINATO_PG_HOST", "127.0.0.1"),
        port => list_to_integer(env("MINATO_PG_PORT", "55432")),
        user => list_to_binary(env("MINATO_PG_USER", "minato")),
        password => list_to_binary(env("MINATO_PG_PASSWORD", "minato")),
        database => list_to_binary(env("MINATO_PG_DATABASE", "minato_test")),
        parameters => #{~"application_name" => ~"minato_soak"},
        timeout => ?TIMEOUT
    }.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
