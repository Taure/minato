-module(minato_secret_tests).
-moduledoc """
A password given as a binary reaches no log, child spec or process status.

The pools point at a port nothing listens on, so nothing here needs a server:
what is under test is what the supervisor and the pool print, not a login.
""".

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

-define(PROBE, ~"s3cr3t-minato-probe").
-define(POOL, minato_secret_tests_pool).
-define(LISTENER, minato_secret_tests_listener).
-define(HANDLER, minato_secret_tests).

-doc false.
-spec log(logger:log_event(), logger:handler_config()) -> ok.
log(Event, #{config := #{pid := Pid}}) when is_pid(Pid) ->
    Pid ! {logged, Event},
    ok.

starting_a_pool_at_debug_level_logs_no_password_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    Logged = captured(fun() ->
        {ok, _Pid} = minato:start_pool(?POOL, pool()),
        ok = minato:stop_pool(?POOL)
    end),
    ?assertNotEqual([], Logged),
    ?assertEqual([], leaking(Logged)).

starting_a_listener_at_debug_level_logs_no_password_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    Logged = captured(fun() ->
        {ok, _Pid} = minato:start_listener(?LISTENER, #{connection => connection()}),
        ok = minato:stop_listener(?LISTENER)
    end),
    ?assertNotEqual([], Logged),
    ?assertEqual([], leaking(Logged)).

the_supervisor_status_holds_no_password_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    {ok, _Pid} = minato:start_pool(?POOL, pool()),
    try
        ?assertNot(holds(sys:get_status(minato_sup))),
        ?assertNot(holds(supervisor:get_childspec(minato_sup, ?POOL)))
    after
        ok = minato:stop_pool(?POOL)
    end.

the_pool_status_holds_no_password_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    {ok, _Pid} = minato:start_pool(?POOL, pool()),
    try
        ?assertNot(holds(sys:get_status(?POOL)))
    after
        ok = minato:stop_pool(?POOL)
    end.

a_pool_that_is_killed_is_restarted_without_logging_the_password_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    {ok, Pid} = minato:start_pool(?POOL, pool()),
    try
        Logged = captured(fun() -> restarted(Pid, kill) end),
        ?assertNotEqual([], Logged),
        ?assertEqual([], leaking(Logged))
    after
        ok = minato:stop_pool(?POOL)
    end.

a_pool_that_crashes_is_reported_without_the_password_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    {ok, Pid} = minato:start_pool(?POOL, pool()),
    try
        Logged = captured(fun() -> restarted(Pid, crash_probe) end),
        ?assert(lists:any(fun crash_report/1, Logged)),
        ?assertEqual([], leaking(Logged))
    after
        ok = minato:stop_pool(?POOL)
    end.

a_pool_declared_in_the_environment_holds_no_password_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    ok = application:stop(minato),
    ok = application:set_env(minato, pools, #{?POOL => pool()}),
    try
        Logged = captured(fun() -> {ok, _Restarted} = application:ensure_all_started(minato) end),
        ?assertNotEqual([], Logged),
        ?assertEqual([], leaking(Logged)),
        ?assertNot(holds(sys:get_status(minato_sup)))
    after
        ok = application:stop(minato),
        ok = application:unset_env(minato, pools)
    end.

a_tls_key_password_is_held_as_a_fun_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    Connection = (connection())#{ssl => true, ssl_options => [{password, ?PROBE}]},
    {ok, _Pid} = minato:start_pool(?POOL, #{size => 1, min_size => 0, connection => Connection}),
    try
        {ok, Spec} = supervisor:get_childspec(minato_sup, ?POOL),
        ?assertNot(holds(Spec)),
        ?assertNot(holds(sys:get_status(?POOL))),
        #{start := {minato_pool, start_link, [?POOL, #{connection := Sealed}]}} = Spec,
        #{password := Password, ssl_options := [{password, KeyPassword}]} = Sealed,
        ?assertEqual(?PROBE, called(Password)),
        ?assertEqual(?PROBE, called(KeyPassword))
    after
        ok = minato:stop_pool(?POOL)
    end.

a_password_given_as_a_fun_is_kept_as_given_test() ->
    Given = fun() -> ?PROBE end,
    Connection = #{user => ~"u", password => Given, ssl_options => [{password, Given}]},
    ?assertEqual(Connection, minato_secret:connection(Connection)).

options_without_a_password_are_unchanged_test() ->
    Connection = #{user => ~"u", ssl => true, ssl_options => [{verify, verify_none}]},
    ?assertEqual(Connection, minato_secret:connection(Connection)),
    ?assertEqual(not_a_map, minato_secret:pool(not_a_map)),
    ?assertEqual(#{connection => []}, minato_secret:pool(#{connection => []})).

called(Sealed) when is_function(Sealed, 0) ->
    Sealed().

restarted(Pid, kill) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    end,
    wait_for_restart(Pid, 50);
restarted(Pid, Reason) ->
    ok = sys:terminate(Pid, Reason),
    wait_for_restart(Pid, 50).

wait_for_restart(_Old, 0) ->
    error(not_restarted);
wait_for_restart(Old, Tries) ->
    case whereis(?POOL) of
        New when is_pid(New), New =/= Old ->
            ok;
        _NotYet ->
            timer:sleep(20),
            wait_for_restart(Old, Tries - 1)
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

pool() ->
    #{size => 1, min_size => 0, connection => connection()}.

connection() ->
    #{
        host => "127.0.0.1",
        port => 1,
        user => ~"u",
        password => ?PROBE,
        database => ~"d",
        connect_timeout => 100
    }.
