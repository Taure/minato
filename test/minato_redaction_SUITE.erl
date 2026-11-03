-module(minato_redaction_SUITE).
-moduledoc """
A password given as a binary, and a private key in `ssl_options`, against a real
PostgreSQL that accepts the password.

`minato_secret_tests` covers what the supervisor prints for a pool that never
connects. This covers the processes that hold live connections: a connected
pool and listener, a borrower that crashes holding a connection, a pool killed
while its connections are open, and a pool and listener that reconnect after a
hot upgrade of the module that sealed their secrets. The connections are plain,
so the key is carried in the options without being used.

The role is created here with a password nothing else uses, so a match in any
report can only be the leak under test. Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, log/2]).
-export([
    a_connected_pool_and_listener_hold_no_password/1,
    a_borrower_that_crashes_holding_a_connection_reports_no_password/1,
    a_connected_pool_that_is_killed_logs_no_password/1,
    a_pool_reconnects_after_the_sealing_module_is_upgraded/1
]).

-define(TIMEOUT, 10000).
-define(PROBE, ~"s3cr3t-minato-probe").
-define(KEY, ~"s3cr3t-minato-key-der").
-define(ROLE, ~"minato_redaction_probe").
-define(POOL, minato_redaction_pool).
-define(LISTENER, minato_redaction_listener).
-define(HANDLER, minato_redaction_SUITE).

-spec all() -> [atom()].
all() ->
    [
        a_connected_pool_and_listener_hold_no_password,
        a_borrower_that_crashes_holding_a_connection_reports_no_password,
        a_connected_pool_that_is_killed_logs_no_password,
        a_pool_reconnects_after_the_sealing_module_is_upgraded
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

-doc """
A hot upgrade that changes `minato_secret` and purges the old version leaves
every fun it made raising `badfun` when called. minato reads what such a fun
holds rather than calling it, so connections the server ends are opened again,
and a pool the supervisor restarts from the child spec it already held connects.
""".
-spec a_pool_reconnects_after_the_sealing_module_is_upgraded([{atom(), term()}]) -> ok.
a_pool_reconnects_after_the_sealing_module_is_upgraded(_Config) ->
    {ok, Pid} = minato:start_pool(?POOL, pool()),
    {ok, Listener} = minato:start_listener(?LISTENER, #{connection => connection()}),
    try
        ok = filled(?POOL, 2, 100),
        ok = minato:listen(?LISTENER, ~"minato_redaction"),
        ok = upgraded(minato_secret),
        ok = ended_backends(),
        ok = queried(?POOL, 100),
        ok = killed(Pid),
        ok = restarted(Pid, 100),
        ok = filled(?POOL, 2, 100),
        ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1", [])),
        receive
            {minato_listener, ?LISTENER, resubscribed} -> ok
        after ?TIMEOUT -> error(listener_not_resubscribed)
        end,
        ?assertEqual(Listener, whereis(?LISTENER))
    after
        ok = minato:stop_listener(?LISTENER),
        ok = minato:stop_pool(?POOL),
        _ = code:purge(minato_secret),
        {module, minato_secret} = code:load_file(minato_secret),
        _ = code:purge(minato_secret)
    end.

%% A new version of the module, loaded and the old one purged, as a release
%% upgrade that changed it would leave things.
-spec upgraded(module()) -> ok.
upgraded(Module) ->
    case code:lib_dir(minato) of
        Lib when is_list(Lib) ->
            Path = Lib ++ "/src/" ++ atom_to_list(Module) ++ ".erl",
            loaded(Module, Path, changed(Path))
    end.

%% The forms epp reads are what the compiler is given back, and go no further.
-spec changed(file:filename()) -> dynamic().
changed(Path) ->
    {ok, Forms} = epp:parse_file(Path, []),
    {Head, [Eof]} = lists:split(length(Forms) - 1, Forms),
    Head ++ [{function, 1, upgraded, 0, [{clause, 1, [], [], [{atom, 1, true}]}]}, Eof].

-spec loaded(module(), file:filename(), [erl_parse:abstract_form()]) -> ok.
loaded(Module, Path, Forms) ->
    case compile:forms(Forms, [nowarn_unused_function]) of
        {ok, Module, Binary} when is_binary(Binary) ->
            _ = code:purge(Module),
            {module, Module} = code:load_binary(Module, Path, Binary),
            _ = code:purge(Module),
            ok
    end.

killed(Pid) when is_pid(Pid) ->
    true = exit(Pid, kill),
    ok.

ended_backends() ->
    {ok, Admin} = minato_conn:connect(admin()),
    SQL = iolist_to_binary([
        ~"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '", ?ROLE, ~"'"
    ]),
    {ok, _Result, Used} = minato_query:query(Admin, SQL, []),
    ok = minato_conn:close(Used),
    timer:sleep(200).

queried(Pool, 0) ->
    error({no_answer, minato_pool:stats(Pool)});
queried(Pool, Tries) ->
    case minato:query(Pool, ~"SELECT 1", []) of
        {ok, #{rows := [{1}]}} ->
            ok;
        _NotYet ->
            timer:sleep(50),
            queried(Pool, Tries - 1)
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
    Printed = io_lib:format("~0tp", [Term]),
    [Secret || Secret <- [?PROBE, ?KEY], string:find(Printed, binary_to_list(Secret)) =/= nomatch] =/=
        [].

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
    (admin())#{
        user => ?ROLE,
        password => ?PROBE,
        ssl_options => [{key, {'RSAPrivateKey', ?KEY}}, {password, ?PROBE}]
    }.

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
