-module(minato_sup_tests).
-moduledoc """
What `m:minato_sup` keeps, and the names it keeps for itself.
""".

-include_lib("eunit/include/eunit.hrl").

-define(POOL, minato_sup_tests_pool).
-define(LISTENER, minato_sup_tests_listener).

%%----------------------------------------------------------------------
%% Names that are minato's own
%%----------------------------------------------------------------------

a_pool_cannot_take_a_name_of_minatos_own_test_() ->
    [
        running(fun() ->
            Kept = whereis(Name),
            ?assert(is_pid(Kept)),
            ?assertEqual({error, {reserved_name, Name}}, minato:start_pool(Name, pool())),
            ?assertEqual(
                {error, {reserved_name, Name}},
                minato:start_listener(Name, #{connection => connection()})
            ),
            ?assertEqual({error, not_found}, minato:stop_pool(Name)),
            ?assertEqual({error, not_found}, minato:stop_listener(Name)),
            ?assertEqual(Kept, whereis(Name)),
            ?assertEqual(1, length([Id || {Id, _, _, _} <- children(), Id =:= minato_overdue]))
        end)
     || Name <- [minato_overdue, minato_sup]
    ].

only_minatos_own_names_are_reserved_test_() ->
    [
        ?_assert(minato_sup:reserved(minato_overdue)),
        ?_assert(minato_sup:reserved(minato_sup)),
        ?_assertNot(minato_sup:reserved(?POOL)),
        ?_assertNot(minato_sup:reserved(minato_pool)),
        ?_assertNot(minato_sup:reserved(~"minato_overdue"))
    ].

a_pool_declared_under_a_name_of_minatos_own_stops_the_application_test_() ->
    [
        {timeout, 30, fun() ->
            _ = application:stop(minato),
            ok = application:set_env(minato, Key, #{Name => Opts}),
            try
                ?assertMatch(
                    {error, {{reserved_name, Name}, _Start}}, application:start(minato)
                )
            after
                ok = application:unset_env(minato, Key),
                {ok, _Started} = application:ensure_all_started(minato)
            end
        end}
     || {Key, Opts} <- [{pools, pool()}, {listeners, #{connection => connection()}}],
        Name <- [minato_overdue, minato_sup]
    ].

%%----------------------------------------------------------------------
%% Starting and stopping
%%----------------------------------------------------------------------

what_the_environment_declares_is_started_test_() ->
    {timeout, 30, fun() ->
        _ = application:stop(minato),
        ok = application:set_env(minato, pools, #{?POOL => pool()}),
        ok = application:set_env(minato, listeners, #{?LISTENER => #{connection => connection()}}),
        try
            {ok, _Started} = application:ensure_all_started(minato),
            ?assertEqual(
                lists:sort([?LISTENER, ?POOL, minato_overdue]),
                lists:sort([Id || {Id, _, _, _} <- children()])
            ),
            ?assert(is_pid(whereis(?POOL))),
            ?assert(is_pid(whereis(?LISTENER))),
            ?assertEqual(ok, minato:stop_pool(?POOL)),
            ?assertEqual(ok, minato:stop_listener(?LISTENER))
        after
            ok = application:unset_env(minato, pools),
            ok = application:unset_env(minato, listeners),
            _ = application:stop(minato),
            {ok, _Again} = application:ensure_all_started(minato)
        end
    end}.

an_environment_that_declares_nothing_usable_starts_only_minatos_own_test_() ->
    {timeout, 30, fun() ->
        _ = application:stop(minato),
        ok = application:set_env(minato, pools, [not_a_map]),
        try
            {ok, _Started} = application:ensure_all_started(minato),
            ?assertEqual([minato_overdue], [Id || {Id, _, _, _} <- children()])
        after
            ok = application:unset_env(minato, pools)
        end
    end}.

a_pool_is_started_once_and_stopped_once_test_() ->
    running(fun() ->
        {ok, Pid} = minato:start_pool(?POOL, pool()),
        ?assertEqual({error, {already_started, Pid}}, minato:start_pool(?POOL, pool())),
        ?assertEqual(ok, minato:stop_pool(?POOL)),
        ?assertEqual({error, not_found}, minato:stop_pool(?POOL)),
        ?assertEqual(undefined, whereis(?POOL))
    end).

a_pool_that_does_not_start_answers_without_its_options_test_() ->
    running(fun() ->
        ?assertEqual(
            {error, {invalid_size, 0.5}}, minato:start_pool(?POOL, sized(0.5))
        ),
        ?assertEqual({error, not_found}, minato:stop_pool(?POOL))
    end).

what_is_kept_is_restarted_ten_times_a_minute_and_given_five_seconds_to_stop_test() ->
    ok = application:unset_env(minato, pools),
    ok = application:unset_env(minato, listeners),
    ?assertEqual(
        {ok,
            {
                #{strategy => one_for_one, intensity => 10, period => 60},
                [
                    #{
                        id => minato_overdue,
                        start => {minato_overdue, start_link, []},
                        restart => permanent,
                        shutdown => 5000,
                        type => worker
                    }
                ]
            }},
        minato_sup:init([])
    ).

the_password_is_not_in_a_child_spec_test_() ->
    running(fun() ->
        {ok, _Pid} = minato:start_pool(?POOL, pool()),
        try
            {ok, Spec} = supervisor:get_childspec(minato_sup, ?POOL),
            ?assertMatch(
                #{id := ?POOL, restart := permanent, shutdown := 5000, type := worker}, Spec
            ),
            ?assertEqual(nomatch, string:find(io_lib:format("~p", [Spec]), "s3cret"))
        after
            ok = minato:stop_pool(?POOL)
        end
    end).

%%----------------------------------------------------------------------
%% What a test started
%%----------------------------------------------------------------------

what_a_test_started_goes_when_the_test_does_test_() ->
    [
        running(fun() ->
            {Test, Started} = started_by_a_test(Kind, keep),
            Monitor = erlang:monitor(process, Started),
            exit(Test, kill),
            receive
                {'DOWN', Monitor, process, Started, Reason} -> ?assertEqual(shutdown, Reason)
            after 5000 -> error(still_running)
            end
        end)
     || Kind <- [pool, listener]
    ].

%% Every test of a module runs in one process, so what watches for that process
%% acts when the whole run ends, which is when the next run starts the same
%% names.
what_a_test_stopped_is_not_stopped_again_under_the_next_to_have_its_name_test_() ->
    [
        running(fun() ->
            {Test, Stopped} = started_by_a_test(Kind, stop),
            ?assertNot(is_process_alive(Stopped)),
            {ok, Next} = start(Kind),
            Monitor = erlang:monitor(process, Next),
            try
                exit(Test, kill),
                receive
                    {'DOWN', Monitor, process, Next, Reason} -> error({stopped, Reason})
                after 300 -> ok
                end,
                ?assertEqual(Next, whereis(name(Kind)))
            after
                _ = minato_sup:stop_pool(name(Kind))
            end
        end)
     || Kind <- [pool, listener]
    ].

what_does_not_start_answers_as_it_would_have_test() ->
    ?assertEqual({error, {invalid_size, 0.5}}, minato_owned:pool(?POOL, sized(0.5))),
    ?assertEqual(
        {error, invalid_connection}, minato_owned:listener(?LISTENER, without_a_connection())
    ).

%% Options the type forbids, because what is asked is what refusing them answers.
without_a_connection() ->
    #{}.

%% A process standing in for a test: it starts one through `m:minato_owned`,
%% stops it again when told to, and then stays until it is killed.
started_by_a_test(Kind, Then) ->
    Asking = self(),
    Test = spawn(fun() ->
        {ok, Started} = owned(Kind),
        _ = Then =:= stop andalso minato_sup:stop_pool(name(Kind)),
        Asking ! {started, self(), Started},
        receive
            never -> ok
        end
    end),
    receive
        {started, Test, Started} -> {Test, Started}
    after 5000 -> error(never_started)
    end.

owned(pool) -> minato_owned:pool(?POOL, pool());
owned(listener) -> minato_owned:listener(?LISTENER, #{connection => connection()}).

start(pool) -> minato:start_pool(?POOL, pool());
start(listener) -> minato:start_listener(?LISTENER, #{connection => connection()}).

name(pool) -> ?POOL;
name(listener) -> ?LISTENER.

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

running(Fun) ->
    {timeout, 30, fun() ->
        {ok, _Started} = application:ensure_all_started(minato),
        _ = minato_sup:stop_pool(?POOL),
        _ = minato_sup:stop_pool(?LISTENER),
        Fun()
    end}.

children() ->
    supervisor:which_children(minato_sup).

pool() ->
    #{size => 1, min_size => 0, connection => connection()}.

sized(Size) ->
    #{size => Size, connection => connection()}.

%% Nothing listens there. A pool is up before it has connections.
connection() ->
    #{
        host => "127.0.0.1",
        port => 1,
        user => ~"minato",
        password => ~"s3cret",
        connect_timeout => 100
    }.
