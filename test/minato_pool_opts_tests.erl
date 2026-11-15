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
    ok = ready(),
    Result = minato_owned:pool(?POOL, sized(0.5)),
    ?assertEqual({error, {invalid_size, 0.5}}, Result),
    ?assertEqual(undefined, whereis(?POOL)).

a_running_pool_reports_its_status_without_the_password_test() ->
    ok = ready(),
    {ok, _Pid} = minato_owned:pool(?POOL, (sized(1))#{min_size => 0}),
    try
        Status = sys:get_status(?POOL),
        ?assertEqual(nomatch, string:find(io_lib:format("~0p", [Status]), "s3cret"))
    after
        ok = minato:stop_pool(?POOL)
    end.

a_running_listener_reports_its_status_without_the_password_test() ->
    ok = ready(),
    {ok, _Pid} = minato_owned:listener(minato_pool_opts_tests_listener, #{
        connection => connection()
    }),
    try
        Status = sys:get_status(minato_pool_opts_tests_listener),
        ?assertEqual(nomatch, string:find(io_lib:format("~0p", [Status]), "s3cret"))
    after
        ok = minato:stop_listener(minato_pool_opts_tests_listener)
    end.

a_password_outside_connection_is_refused_without_echoing_it_test() ->
    ?assertEqual(
        {error, invalid_connection}, linked(#{size => 2, user => ~"u", password => ~"s3cret"})
    ).

a_connection_without_a_user_is_refused_test() ->
    ?assertEqual(
        {error, invalid_connection},
        linked(#{size => 2, connection => #{port => 1, password => ~"s3cret"}})
    ).

a_connection_that_is_not_a_map_is_refused_test() ->
    ?assertEqual(
        {error, invalid_connection},
        linked(#{size => 2, connection => [{user, ~"u"}, {password, ~"s3cret"}]})
    ).

a_listener_without_a_connection_returns_no_password_test() ->
    ok = ready(),
    ?assertEqual(
        {error, invalid_connection},
        minato_owned:listener(minato_pool_opts_tests_listener, unnested())
    ).

zero_and_infinity_timeouts_are_accepted_test() ->
    ok = ready(),
    {ok, _Pid} = minato_owned:pool(?POOL, (sized(1))#{
        min_size => 0, max_idle => 0, max_age => 0
    }),
    ok = minato:stop_pool(?POOL),
    {ok, _Pid2} = minato_owned:pool(?POOL, (sized(1))#{min_size => 0, max_idle => infinity}),
    ok = minato:stop_pool(?POOL).

a_pool_whose_connection_could_not_be_secured_as_asked_does_not_start_test_() ->
    [
        ?_assertEqual(
            {error, {invalid_option, Key}},
            linked(#{size => 2, connection => asking(Key, Value)})
        )
     || {Key, Value} <- [
            {channel_binding, required},
            {ssl, yes},
            {auth, [scram]},
            {ssl_options, [{verify, verify_pear}]},
            {password, 42},
            {host, ~"db.example.invalid"}
        ]
    ].

a_listener_whose_connection_could_not_be_secured_as_asked_does_not_start_test() ->
    ok = ready(),
    ?assertEqual(
        {error, {invalid_option, channel_binding}},
        minato_owned:listener(minato_pool_opts_tests_listener, #{
            connection => asking(channel_binding, required)
        })
    ),
    ?assertEqual(
        {error, {invalid_option, host}},
        minato_owned:listener(minato_pool_opts_tests_listener, #{
            connection => asking(host, ~"db.example.invalid")
        })
    ),
    ?assertEqual(
        {error, {invalid_option, auth}},
        minato_owned:pool(?POOL, #{connection => asking(auth, md5)})
    ).

%% A connection that asks for something the type forbids, because what is
%% checked is that it is refused at run time too.
-spec asking(term(), term()) -> dynamic().
asking(ssl_options, Value) ->
    (connection())#{ssl => true, ssl_options => Value};
asking(Key, Value) ->
    (connection())#{Key => Value}.

%% Options with a key the type has no name for, for the same reason.
-spec unknown(map()) -> dynamic().
unknown(Opts) ->
    Opts.

%% A key nobody reads is a setting somebody believes is in force.
an_option_a_pool_has_no_name_for_is_refused_test_() ->
    [
        ?_assertEqual({error, {invalid_option, Key}}, linked(Opts))
     || {Key, Opts} <- [
            {pool_size, #{pool_size => 10, connection => connection()}},
            {max_size, #{size => 2, max_size => 10, connection => connection()}},
            {ssl, #{size => 2, ssl => true, connection => connection()}},
            {~"size", #{~"size" => 2, connection => connection()}},
            {sslmode, #{size => 2, connection => asking(sslmode, require)}},
            {ssl_options, #{size => 2, connection => (connection())#{ssl_options => []}}}
        ]
    ].

an_option_a_listener_has_no_name_for_is_refused_test_() ->
    [
        fun() ->
            ok = ready(),
            ?assertEqual(
                {error, {invalid_option, Key}},
                minato_owned:listener(minato_pool_opts_tests_listener, Opts)
            )
        end
     || {Key, Opts} <- [
            {channel, unknown(#{channel => ~"jobs", connection => connection()})},
            {size, unknown(#{size => 1, connection => connection()})},
            {sslmode, #{connection => asking(sslmode, require)}}
        ]
    ].

linked(Opts) ->
    Trapping = process_flag(trap_exit, true),
    try
        minato_pool:start_link(?POOL, Opts)
    after
        process_flag(trap_exit, Trapping)
    end.

started(Opts) ->
    Trapping = process_flag(trap_exit, true),
    try
        minato_pool:start_link(?POOL, Opts#{connection => connection()})
    after
        process_flag(trap_exit, Trapping)
    end.

unnested() ->
    #{user => ~"u", password => ~"s3cret"}.

proplist() ->
    [{size, 2}, {connection, connection()}].

sized(Size) ->
    #{size => Size, connection => connection()}.

connection() ->
    #{host => "127.0.0.1", port => 1, user => ~"u", password => ~"s3cret", database => ~"d"}.

%% A run that was cut short leaves what it started under the supervisor, and
%% the next run would find the name taken.
ready() ->
    {ok, _Started} = application:ensure_all_started(minato),
    _ = minato:stop_pool(?POOL),
    _ = minato:stop_listener(minato_pool_opts_tests_listener),
    ok.
