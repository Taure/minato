-module(minato_pool_opts_tests).
-moduledoc """
Pool options that cannot describe a pool stop it before it connects.
""".

-include_lib("eunit/include/eunit.hrl").

-define(POOL, minato_pool_opts_tests).

a_fractional_size_is_refused_test() ->
    ?assertEqual({error, {invalid_size, 0.5}}, started(#{size => 0.5})).

a_size_of_zero_is_refused_test() ->
    ?assertEqual({error, {invalid_size, 0}}, started(#{size => 0})).

a_negative_min_size_is_refused_test() ->
    ?assertEqual({error, {invalid_min_size, -1}}, started(#{size => 2, min_size => -1})).

a_non_integer_min_size_is_refused_test() ->
    ?assertEqual({error, {invalid_min_size, two}}, started(#{size => 2, min_size => two})).

a_size_given_as_text_is_refused_test() ->
    ?assertEqual({error, {invalid_size, ~"10"}}, started(#{size => ~"10"})),
    ?assertEqual({error, {invalid_size, "10"}}, started(#{size => "10"})).

a_max_idle_given_as_text_is_refused_test() ->
    ?assertEqual({error, {invalid_max_idle, "60000"}}, started(#{max_idle => "60000"})).

a_negative_max_age_is_refused_test() ->
    ?assertEqual({error, {invalid_max_age, -1}}, started(#{max_age => -1})).

an_unknown_disconnected_mode_is_refused_test() ->
    ?assertEqual({error, {invalid_disconnected, retry}}, started(#{disconnected => retry})).

options_that_are_not_a_map_are_refused_without_echoing_them_test() ->
    Trapping = process_flag(trap_exit, true),
    try
        ?assertEqual(
            {error, invalid_opts},
            minato_pool:start_link(?POOL, proplist())
        )
    after
        process_flag(trap_exit, Trapping)
    end.

a_refused_pool_under_the_supervisor_returns_only_the_reason_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    Result = minato:start_pool(?POOL, sized(0.5)),
    ?assertEqual({error, {invalid_size, 0.5}}, Result),
    ?assertEqual(nomatch, string:find(io_lib:format("~0p", [Result]), "s3cret")),
    ?assertEqual(undefined, whereis(?POOL)).

a_running_pool_reports_its_status_without_the_password_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    {ok, _Pid} = minato:start_pool(?POOL, (sized(1))#{min_size => 0}),
    try
        Status = sys:get_status(?POOL),
        ?assertEqual(nomatch, string:find(io_lib:format("~0p", [Status]), "s3cret"))
    after
        ok = minato:stop_pool(?POOL)
    end.

a_running_listener_reports_its_status_without_the_password_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    {ok, _Pid} = minato:start_listener(minato_pool_opts_tests_listener, #{
        connection => connection()
    }),
    try
        Status = sys:get_status(minato_pool_opts_tests_listener),
        ?assertEqual(nomatch, string:find(io_lib:format("~0p", [Status]), "s3cret"))
    after
        ok = minato:stop_listener(minato_pool_opts_tests_listener)
    end.

started(Opts) ->
    Trapping = process_flag(trap_exit, true),
    try
        minato_pool:start_link(?POOL, Opts#{connection => connection()})
    after
        process_flag(trap_exit, Trapping)
    end.

proplist() ->
    [{size, 2}, {connection, connection()}].

sized(Size) ->
    #{size => Size, connection => connection()}.

connection() ->
    #{host => "127.0.0.1", port => 1, user => ~"u", password => ~"s3cret", database => ~"d"}.
