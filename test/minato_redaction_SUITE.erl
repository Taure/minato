-module(minato_redaction_SUITE).
-moduledoc """
A password given as a binary, against a real PostgreSQL that accepts it.

`minato_secret_tests` covers what the supervisor prints for a pool that never
connects. This covers the processes that hold live connections: a connected
pool and listener, a borrower that crashes holding a connection, and a pool
killed while its connections are open.

The role is created here with a password nothing else uses, so a match in any
report can only be the leak under test. Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, log/2]).
-export([
    a_connected_pool_and_listener_hold_no_password/1,
    a_borrower_that_crashes_holding_a_connection_reports_no_password/1,
    a_connected_pool_that_is_killed_logs_no_password/1
]).

-define(TIMEOUT, 10000).
-define(PROBE, ~"s3cr3t-minato-probe").
-define(ROLE, ~"minato_redaction_probe").
-define(POOL, minato_redaction_pool).
-define(LISTENER, minato_redaction_listener).
-define(HANDLER, minato_redaction_SUITE).

-spec all() -> [atom()].
all() ->
    [
        a_connected_pool_and_listener_hold_no_password,
        a_borrower_that_crashes_holding_a_connection_reports_no_password,
        a_connected_pool_that_is_killed_logs_no_password
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(admin()) of
        {ok, Conn} ->
            {ok, _Results, Ready} = minato_query:simple(Conn, role()),
            ok = minato_conn:close(Ready),
            {ok, _Started} = application:ensure_all_started(minato),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok = application:stop(minato).

-doc false.
-spec log(logger:log_event(), logger:handler_config()) -> ok.
log(Event, #{config := #{pid := Pid}}) when is_pid(Pid) ->
    Pid ! {logged, Event},
    ok.

-spec a_connected_pool_and_listener_hold_no_password([{atom(), term()}]) -> ok.
a_connected_pool_and_listener_hold_no_password(_Config) ->
    Logged = captured(fun() ->
        {ok, _Pool} = minato:start_pool(?POOL, pool()),
        {ok, _Listener} = minato:start_listener(?LISTENER, #{connection => connection()}),
        ok = filled(?POOL, 2, 100)
    end),
    try
        ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])),
        ?assertNot(holds(sys:get_status(?POOL))),
        ?assertNot(holds(sys:get_status(?LISTENER))),
        ?assertNot(holds(sys:get_status(minato_sup))),
        ?assertEqual([], leaking(Logged))
    after
        ok = minato:stop_listener(?LISTENER),
        ok = minato:stop_pool(?POOL)
    end.

-spec a_borrower_that_crashes_holding_a_connection_reports_no_password([{atom(), term()}]) ->
    ok.
a_borrower_that_crashes_holding_a_connection_reports_no_password(_Config) ->
    {ok, _Pool} = minato:start_pool(?POOL, pool()),
    try
        ok = filled(?POOL, 2, 100),
        Logged = captured(fun() ->
            {Borrower, Monitor} = proc_lib:spawn_opt(
                fun() ->
                    {ok, Conn} = minato_pool:checkout(?POOL),
                    error({crash_probe, Conn})
                end,
                [monitor]
            ),
            receive
                {'DOWN', Monitor, process, Borrower, _Reason} -> ok
            after ?TIMEOUT -> error(timeout)
            end
        end),
        ?assert(lists:any(fun crash_report/1, Logged)),
        ?assertEqual([], leaking(Logged))
    after
        ok = minato:stop_pool(?POOL)
    end.

-spec a_connected_pool_that_is_killed_logs_no_password([{atom(), term()}]) -> ok.
a_connected_pool_that_is_killed_logs_no_password(_Config) ->
    {ok, Pid} = minato:start_pool(?POOL, pool()),
    try
        ok = filled(?POOL, 2, 100),
        Logged = captured(fun() ->
            ok = sys:terminate(Pid, crash_probe),
            ok = restarted(Pid, 100),
            ok = filled(?POOL, 2, 100)
        end),
        ?assert(lists:any(fun crash_report/1, Logged)),
        ?assertEqual([], leaking(Logged)),
        ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", []))
    after
        ok = minato:stop_pool(?POOL)
    end.

restarted(_Old, 0) ->
    error(not_restarted);
restarted(Old, Tries) ->
    case whereis(?POOL) of
        New when is_pid(New), New =/= Old ->
            ok;
        _NotYet ->
            timer:sleep(20),
            restarted(Old, Tries - 1)
    end.

filled(Pool, Size, 0) ->
    error({not_filled, Pool, Size, minato_pool:stats(Pool)});
filled(Pool, Size, Tries) ->
    case minato_pool:stats(Pool) of
        #{idle := Size} ->
            ok;
        _NotYet ->
            timer:sleep(20),
            filled(Pool, Size, Tries - 1)
    end.

captured(Run) ->
    #{level := Level} = logger:get_primary_config(),
    ok = logger:set_primary_config(level, debug),
    ok = logger:add_handler(?HANDLER, ?MODULE, #{level => all, config => #{pid => self()}}),
    try
        Run(),
        timer:sleep(100)
    after
        _ = logger:remove_handler(?HANDLER),
        ok = logger:set_primary_config(level, Level)
    end,
    drained([]).

drained(Logged) ->
    receive
        {logged, Event} -> drained([Event | Logged])
    after 0 -> lists:reverse(Logged)
    end.

leaking(Logged) ->
    [Event || Event <- Logged, holds(Event) orelse holds(formatted(Event))].

formatted(Event) ->
    logger_formatter:format(Event, #{single_line => true, max_size => unlimited, depth => unlimited}).

crash_report(#{msg := {report, #{label := {gen_server, terminate}}}}) -> true;
crash_report(#{msg := {report, #{label := {proc_lib, crash}}}}) -> true;
crash_report(_Event) -> false.

holds(Term) ->
    string:find(io_lib:format("~0tp", [Term]), binary_to_list(?PROBE)) =/= nomatch.

role() ->
    iolist_to_binary([
        ~"DO $$ BEGIN CREATE ROLE ",
        ?ROLE,
        ~"; EXCEPTION WHEN duplicate_object THEN NULL; END $$; ALTER ROLE ",
        ?ROLE,
        ~" LOGIN PASSWORD '",
        ?PROBE,
        ~"'"
    ]).

pool() ->
    #{size => 2, min_size => 2, connection => connection()}.

connection() ->
    (admin())#{user => ?ROLE, password => ?PROBE}.

admin() ->
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
