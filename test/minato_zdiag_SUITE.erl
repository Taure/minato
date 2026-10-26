-module(minato_zdiag_SUITE).
-moduledoc """
Temporary diagnostics for #55, Windows only. Not for merging.
""".

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([fresh_pools/1, sustained/1]).

-define(TIMEOUT, 10000).

all() -> [fresh_pools, sustained].

init_per_suite(Config) ->
    case {wanted(), minato_conn:connect(connection())} of
        {true, {ok, Conn}} ->
            Done = lists:foldl(
                fun(Sql, C) ->
                    {_, _, Next} = minato_query:simple(C, Sql),
                    Next
                end,
                Conn,
                case os:type() of
                    {win32, _} ->
                        [
                            ~"ALTER SYSTEM SET log_connections = on",
                            ~"ALTER SYSTEM SET log_disconnections = on",
                            ~"SELECT pg_reload_conf()"
                        ];
                    _ ->
                        []
                end
            ),
            ct:pal("server: ~p~n", [settings(Done)]),
            ok = minato_conn:close(Done),
            {ok, _} = application:ensure_all_started(minato),
            Config;
        {false, _} ->
            {skip, not_windows};
        {_, {error, Reason}} ->
            {skip, {no_server, Reason}}
    end.

end_per_suite(_Config) ->
    ok = application:stop(minato).

wanted() ->
    os:type() =:= {win32, nt} orelse os:getenv("MINATO_DIAG") =:= "1".

settings(Conn) ->
    {_, Results, _} = minato_query:simple(
        Conn,
        ~"SELECT version(); SHOW logging_collector; SHOW log_destination; SELECT pg_current_logfile(); SHOW max_connections"
    ),
    [Rows || #{rows := Rows} <- Results].

fresh_pools(_Config) ->
    Deadline = erlang:monotonic_time(millisecond) + 45000,
    {Rounds, Errors} = fresh(Deadline, 0, []),
    ct:pal("fresh pool rounds: ~p, errors: ~p", [Rounds, length(Errors)]),
    ct:fail({summary, Rounds, Errors}).

fresh(Deadline, Rounds, Errors) when length(Errors) >= 3 ->
    _ = Deadline,
    {Rounds, Errors};
fresh(Deadline, Rounds, Errors) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        false ->
            {Rounds, Errors};
        true ->
            {ok, _} = minato:start_pool(diag_pool, #{
                size => 2, min_size => 2, connection => connection()
            }),
            ok = filled(diag_pool, 2, 500),
            Found = [cycle(diag_pool, {Rounds, Step}) || Step <- [1, 2, 3, 4]],
            ok = minato:stop_pool(diag_pool),
            fresh(Deadline, Rounds + 1, Errors ++ [E || {error, _} = E <- Found])
    end.

sustained(_Config) ->
    {ok, _} = minato:start_pool(diag_load, #{
        size => 8, min_size => 8, connection => connection()
    }),
    ok = filled(diag_load, 8, 500),
    Test = self(),
    Deadline = erlang:monotonic_time(millisecond) + 30000,
    Workers = [
        spawn_link(fun() -> Test ! {done, self(), worked(Deadline, W, 0, [])} end)
     || W <- lists:seq(1, 16)
    ],
    Reports = [
        receive
            {done, Pid, Report} -> Report
        end
     || Pid <- Workers
    ],
    Stats = minato:stats(diag_load),
    ok = minato:stop_pool(diag_load),
    Errors = lists:append([E || {_, E} <- Reports]),
    ct:pal("sustained ops: ~p, errors: ~p, stats: ~p", [
        lists:sum([N || {N, _} <- Reports]), length(Errors), Stats
    ]),
    ct:fail({summary, lists:sum([N || {N, _} <- Reports]), Stats, Errors}).

worked(Deadline, Worker, Done, Errors) ->
    case erlang:monotonic_time(millisecond) < Deadline andalso length(Errors) < 2 of
        false ->
            {Done, Errors};
        true ->
            case cycle(diag_load, {Worker, Done}) of
                ok -> worked(Deadline, Worker, Done + 1, Errors);
                {error, _} = E -> worked(Deadline, Worker, Done + 1, [E | Errors])
            end
    end.

cycle(Pool, Where) ->
    case minato_pool:checkout(Pool, ?TIMEOUT) of
        {ok, Conn} ->
            Age = minato_conn:age(Conn),
            Key = minato_conn:backend_key(Conn),
            Before = info(Conn),
            At = erlang:system_time(millisecond),
            case raw(Conn) of
                {ok, Read} ->
                    ok = minato_pool:checkin(Pool, Read);
                {error, Step, Reason} ->
                    After = info(Conn),
                    ok = minato_pool:discard(Pool, Conn),
                    Report = #{
                        where => Where,
                        step => Step,
                        reason => Reason,
                        age_ms => Age,
                        key => Key,
                        at => calendar:system_time_to_rfc3339(At, [{unit, millisecond}]),
                        socket_before => Before,
                        socket_after => After,
                        server => server(Key)
                    },
                    ct:pal("FAILED: ~p", [Report]),
                    {error, Report}
            end;
        {error, Reason} ->
            ct:pal("CHECKOUT FAILED: ~p ~p", [Where, Reason]),
            {error, #{where => Where, step => checkout, reason => Reason}}
    end.

raw(Conn) ->
    case minato_conn:send(Conn, {query, ~"SELECT pg_backend_pid()"}) of
        ok -> read(Conn, []);
        {error, Reason} -> {error, send, Reason}
    end.

read(Conn, Seen) ->
    case minato_conn:next(Conn, ?TIMEOUT) of
        {ok, {ready_for_query, _}, Read} -> {ok, Read};
        {ok, {error_response, Fields}, Read} -> read(Read, [Fields | Seen]);
        {ok, _Other, Read} -> read(Read, Seen);
        {error, Reason} -> {error, recv, {Reason, Seen}}
    end.

info(Conn) ->
    try
        Info = socket:info(element(3, Conn)),
        maps:with([rstates, wstates, counters, ctype], Info)
    catch
        C:E -> {C, E}
    end.

server(Key) ->
    Pid =
        case Key of
            {P, _} -> P;
            _ -> 0
        end,
    case minato_conn:connect(connection()) of
        {ok, Admin} ->
            {_, R1, A1} = minato_query:query(
                Admin,
                ~"SELECT pid, state, backend_start::text, state_change::text, wait_event FROM pg_stat_activity WHERE pid = $1",
                [Pid]
            ),
            {_, R2, A2} = minato_query:simple(A1, ~"SELECT pg_current_logfile()"),
            Tail =
                case R2 of
                    [#{rows := [{File}]}] when is_binary(File) ->
                        case
                            minato_query:query(
                                A2,
                                ~"SELECT pg_read_file($1, greatest(0, (pg_stat_file($1)).size - 12000), 12000)",
                                [File]
                            )
                        of
                            {ok, #{rows := [{Text}]}, A3} ->
                                ok = minato_conn:close(A3),
                                Text;
                            Other ->
                                ok = minato_conn:close(A2),
                                {no_tail, Other}
                        end;
                    Other ->
                        ok = minato_conn:close(A2),
                        {no_logfile, Other}
                end,
            #{activity => R1, log_tail => Tail};
        {error, Reason} ->
            {admin_connect_failed, Reason}
    end.

filled(_Pool, _Size, 0) ->
    {error, never_filled};
filled(Pool, Size, Attempts) ->
    case minato_pool:stats(Pool) of
        #{idle := Idle} when Idle >= Size -> ok;
        _ ->
            timer:sleep(10),
            filled(Pool, Size, Attempts - 1)
    end.

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
