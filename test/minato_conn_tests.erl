-module(minato_conn_tests).
-moduledoc """
The opening exchange, against a server written to be awkward.

`minato_connection_SUITE` proves the exchange against a real PostgreSQL, which
is the only thing that can prove it works. What it cannot do is ask PostgreSQL
to misbehave: a container will not demand a cleartext password on a plain
socket, decline TLS on request, send a `BindComplete` in the middle of a
startup, or go silent. `m:minato_backend_server` will, and every decision
`m:minato_conn` makes about a server it should not trust is tested here.

The assertions are about what the client sent as much as what it returned. A
client that refuses a cleartext password and returns an error but writes the
password first has not refused anything, so the tests read back the frontend
messages the server received and require the password not to be among them.
""".

-include_lib("eunit/include/eunit.hrl").

-export([log/2, exception/4]).

-define(WINDOWS, {win32, nt}).
-define(POSIX, {unix, linux}).

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).

an_option_that_decides_how_a_connection_is_secured_is_checked_before_a_socket_opens_test_() ->
    {setup, fun() -> gen_tcp:listen(0, [binary, {active, false}, {ip, loopback}]) end,
        fun({ok, Listen}) -> gen_tcp:close(Listen) end, fun({ok, Listen}) ->
            {ok, Port} = inet:port(Listen),
            [
                {lists:flatten(io_lib:format("~p as ~p", [Key, Value])), fun() ->
                    ?assertError(
                        {minato_conn, #{
                            message := options, reason := {invalid_option, Key}, data := Key
                        }},
                        minato_conn:connect(asking(Port, #{Key => Value}))
                    ),
                    ?assertEqual({error, timeout}, gen_tcp:accept(Listen, 0))
                end}
             || {Key, Value} <- unknown_options()
            ]
        end}.

%% Options the type may forbid, because what is checked is that they are
%% refused at run time too.
-spec asking(inet:port_number(), #{term() => term()}) -> dynamic().
asking(Port, #{ssl_options := _} = Options) when not is_map_key(ssl, Options) ->
    maps:merge(opts(Port, #{ssl => true}), Options);
asking(Port, Options) ->
    maps:merge(opts(Port, #{}), Options).

%% A key that is not an option was skipped, so one that was misspelt left the
%% default in force and nothing said so.
an_option_minato_has_no_name_for_is_refused_before_a_socket_opens_test_() ->
    {setup, fun() -> gen_tcp:listen(0, [binary, {active, false}, {ip, loopback}]) end,
        fun({ok, Listen}) -> gen_tcp:close(Listen) end, fun({ok, Listen}) ->
            {ok, Port} = inet:port(Listen),
            [
                {lists:flatten(io_lib:format("~p", [Key])), fun() ->
                    ?assertError(
                        {minato_conn, #{
                            message := options, reason := {invalid_option, Key}, data := Key
                        }},
                        minato_conn:connect(asking(Port, #{Key => Value}))
                    ),
                    ?assertEqual({error, timeout}, gen_tcp:accept(Listen, 0))
                end}
             || {Key, Value} <- [
                    {sslmode, require},
                    {tls, true},
                    {ssl_opts, [{verify, verify_peer}]},
                    {chanel_binding, require},
                    {channel_bindings, require},
                    {pasword, ~"secret"},
                    {username, ~"minato"}
                ]
            ]
        end}.

%% A map made from a file of secrets the wrong way round has them as its keys,
%% and a key that is refused goes into the reason, the exception and the event.
a_key_that_is_not_an_atom_is_refused_without_being_repeated_test_() ->
    [
        {lists:flatten(io_lib:format("~p", [Key])), fun() ->
            Opts = asking(5432, #{Key => true}),
            Handler = {?MODULE, self()},
            {ok, _Started} = application:ensure_all_started(telemetry),
            ok = telemetry:attach(
                Handler, [minato, connect, exception], fun ?MODULE:exception/4, self()
            ),
            try
                ?assertEqual({error, {invalid_option, not_an_atom}}, minato_conn:validate(Opts)),
                ?assertEqual(
                    {error, {minato_conn, {invalid_option, not_an_atom}}},
                    minato_conn:attempt(Opts)
                ),
                Raised = raised(Opts),
                ?assertMatch(
                    {error,
                        {minato_conn, #{
                            message := options,
                            reason := {invalid_option, not_an_atom},
                            data := not_an_atom
                        }},
                        _Stacktrace},
                    Raised
                ),
                Events = exceptions(),
                ?assertMatch([_Attempt, _Connect], Events),
                Printed = io_lib:format("~0tp", [{Raised, Events}]),
                ?assertEqual(nomatch, string:find(Printed, "s3cret-key"))
            after
                ok = telemetry:detach(Handler)
            end
        end}
     || Key <- [
            ~"postgres://minato:s3cret-key@db.example.invalid/minato",
            "s3cret-key",
            {password, ~"s3cret-key"},
            5432
        ]
    ].

raised(Opts) ->
    try minato_conn:connect(Opts) of
        Returned -> {returned, Returned, []}
    catch
        Class:Reason:Stacktrace -> {Class, Reason, Stacktrace}
    end.

exceptions() ->
    receive
        {exception, Metadata} -> [Metadata | exceptions()]
    after 100 -> []
    end.

every_option_there_is_has_a_name_test() ->
    Every = #{
        host => "db",
        port => 5432,
        user => ~"minato",
        password => ~"secret",
        database => ~"minato",
        parameters => #{},
        ssl => true,
        ssl_options => [],
        channel_binding => prefer,
        auth => [scram_sha_256],
        connect_timeout => 5000,
        timeout => 15000,
        socket_options => [],
        transport => socket,
        prepared_statements => 0,
        cancel_timeout => 5000,
        frame_opts => #{}
    },
    ?assertEqual(ok, minato_conn:validate(Every)).

%% Options for a TLS session that nobody asked for are a session the caller
%% believes it has.
tls_options_without_tls_are_refused_test_() ->
    [
        ?_assertEqual({error, {invalid_option, ssl_options}}, minato_conn:validate(Opts))
     || Opts <- [
            #{user => ~"minato", ssl_options => [{verify, verify_peer}]},
            #{user => ~"minato", ssl_options => []},
            #{user => ~"minato", ssl => false, ssl_options => [{verify, verify_peer}]}
        ]
    ] ++
        [
            ?_assertEqual(ok, minato_conn:validate(#{user => ~"minato", ssl => false})),
            ?_assertEqual(
                ok,
                minato_conn:validate(#{
                    user => ~"minato", ssl => true, ssl_options => [{verify, verify_peer}]
                })
            )
        ].

a_value_that_cannot_be_read_does_not_hide_an_option_that_is_wrong_test() ->
    ?assertError(
        {minato_conn, #{message := options, reason := {invalid_option, channel_binding}}},
        minato_conn:connect(asking(5432, #{channel_binding => required, password => [nope]}))
    ).

%% A list that does not end in one, which a list's type cannot say.
-spec ending_in(term(), dynamic()) -> dynamic().
ending_in(Head, Tail) ->
    [Head | Tail].

unknown_options() ->
    [
        {channel_binding, required},
        {channel_binding, ~"require"},
        {channel_binding, "require"},
        {channel_binding, true},
        {ssl, yes},
        {ssl, ~"true"},
        {ssl, verify_peer},
        {auth, scram_sha_256},
        {auth, []},
        {auth, [scram]},
        {auth, [scram_sha_256, ~"md5"]},
        {auth, ending_in(scram_sha_256, md5)},
        {ssl_options, #{verify => verify_peer}},
        {ssl_options, [{verify, verify_pear}]},
        {ssl_options, [{verify, true}]},
        {ssl_options, [{handshake, hello}]},
        {ssl_options, [{reuse_sessions, true}]},
        {ssl_options, [{reuse_sessions, save}]},
        {ssl_options, [{reuse_session, ~"an id"}]},
        {ssl_options, [{session_tickets, auto}]},
        {ssl_options, [{session_tickets, manual}]},
        {ssl_options, [{use_ticket, [~"a ticket"]}]},
        {ssl_options, [~"verify"]},
        {ssl_options, ending_in({verify, verify_peer}, cacerts)},
        {password, 42},
        {password, undefined},
        {host, ~"db.example.invalid"},
        {host, 5432},
        {host, {127, 0, 1}},
        {host, {127, 0, 0, 256}},
        {host, {local, socket}}
    ] ++
        [
            {Key, Value}
         || Key <- [connect_timeout, timeout, cancel_timeout],
            Value <- ["5000", ~"5000", -1, 1.5, 5.0e3, never, undefined, {5, seconds}]
        ].

every_value_an_option_can_have_is_accepted_test_() ->
    [
        ?_assertEqual(ok, minato_conn:validate(asking(5432, #{Key => Value})))
     || {Key, Value} <- [
            {channel_binding, prefer},
            {channel_binding, require},
            {channel_binding, disable},
            {ssl, true},
            {ssl, false},
            {auth, [scram_sha_256]},
            {auth, [scram_sha_256, md5, cleartext, none]},
            {ssl_options, []},
            {ssl_options, [{verify, verify_none}]},
            {ssl_options, [{verify, verify_peer}, {cacertfile, "ca.pem"}, {handshake, full}]},
            {ssl_options, [{reuse_sessions, false}, {session_tickets, disabled}]},
            {ssl_options, fun() -> [{verify, verify_peer}] end},
            {password, ~"secret"},
            {password, "secret"},
            {password, fun() -> ~"secret" end},
            {host, "db"},
            {host, db},
            {host, loopback},
            {host, {127, 0, 0, 1}},
            {host, {0, 0, 0, 0, 0, 0, 0, 1}},
            {host, {local, "/var/run/postgresql/.s.PGSQL.5432"}},
            {host, {local, ~"/var/run/postgresql/.s.PGSQL.5432"}}
        ]
    ] ++ [?_assertEqual(ok, minato_conn:validate(#{user => ~"minato"}))].

every_time_an_option_can_have_is_accepted_test_() ->
    [
        ?_assertEqual(ok, minato_conn:validate(asking(5432, #{Key => Value})))
     || Key <- [connect_timeout, timeout, cancel_timeout],
        Value <- [0, 1, 5000, infinity]
    ].

the_first_option_that_is_wrong_is_the_one_named_test() ->
    ?assertEqual(
        {error, {invalid_option, channel_binding}},
        minato_conn:validate(asking(5432, #{channel_binding => required, ssl => yes}))
    ),
    ?assertEqual(
        {error, {invalid_option, ssl_options}},
        minato_conn:validate(asking(5432, #{ssl_options => secure, password => 42}))
    ),
    ?assertEqual(
        {error, {invalid_option, password}},
        minato_conn:validate(asking(5432, #{password => 42, timeout => "5000"}))
    ),
    ?assertEqual(
        {error, {invalid_option, connect_timeout}},
        minato_conn:validate(asking(5432, #{connect_timeout => -1, cancel_timeout => "5000"}))
    ).

%% A time read from the environment is text, and it was taken as it came: the
%% connection opened, and the first statement to run out of time raised
%% `badarith` in the middle of its answer. A pool and a listener connect
%% through here, and would have tried again for as long as they ran.
a_time_that_is_not_one_is_refused_by_what_retries_a_connect_test_() ->
    [
        ?_assertEqual(
            {error, {minato_conn, {invalid_option, Key}}},
            minato_conn:attempt(asking(5432, #{Key => "5000"}))
        )
     || Key <- [connect_timeout, timeout, cancel_timeout]
    ].

startup_carries_the_configured_parameters_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{
        database => ~"minato_test", parameters => #{~"application_name" => ~"tests"}
    }),
    ok = minato_conn:close(Conn),
    ?assertMatch(
        [
            {startup, #{
                ~"user" := ~"minato",
                ~"database" := ~"minato_test",
                ~"application_name" := ~"tests",
                ~"client_encoding" := ~"UTF8",
                ~"DateStyle" := ~"ISO, MDY"
            }}
            | _
        ],
        minato_backend_server:received(Server)
    ),
    minato_backend_server:stop(Server).

the_database_defaults_to_the_user_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{}),
    ok = minato_conn:close(Conn),
    [{startup, Parameters} | _] = minato_backend_server:received(Server),
    ?assertEqual(~"minato", maps:get(~"database", Parameters)),
    minato_backend_server:stop(Server).

a_given_parameter_replaces_the_default_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{parameters => #{~"DateStyle" => ~"ISO, DMY"}}),
    ok = minato_conn:close(Conn),
    [{startup, Parameters} | _] = minato_backend_server:received(Server),
    ?assertEqual(~"ISO, DMY", maps:get(~"DateStyle", Parameters)),
    minato_backend_server:stop(Server).

the_parameters_and_the_key_the_server_sent_are_kept_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{}),
    ?assertEqual(~"17.4", minato_conn:parameter(Conn, ~"server_version")),
    ?assertEqual(undefined, minato_conn:parameter(Conn, ~"TimeZone")),
    ?assertEqual(#{~"server_version" => ~"17.4"}, minato_conn:parameters(Conn)),
    ?assertEqual({4242, 777}, minato_conn:backend_key(Conn)),
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server).

a_null_byte_in_a_startup_parameter_is_refused_before_connecting_test_() ->
    Smuggled = <<"minato_test", 0, "options", 0, "-c statement_timeout=1">>,
    [
        {Label, fun() ->
            Server = minato_backend_server:start([?READY]),
            Port = minato_backend_server:port(Server),
            ?assertError(
                {minato_conn, #{reason := null_byte_in_parameter, data := Name}},
                minato_conn:connect(opts(Port, Opts))
            ),
            ?assertEqual(
                {error, {minato_conn, null_byte_in_parameter}},
                minato_conn:attempt(opts(Port, Opts))
            ),
            ?assertEqual([], minato_backend_server:received(Server)),
            minato_backend_server:stop(Server)
        end}
     || {Label, Name, Opts} <- [
            {"database", ~"database", #{database => Smuggled}},
            {"user", ~"user", #{user => <<"mina", 0, "to">>, database => ~"minato_test"}},
            {"options", ~"options", #{parameters => #{~"options" => <<"-c a=b", 0>>}}},
            {"a name", <<"application", 0, "name">>, #{
                parameters => #{<<"application", 0, "name">> => ~"tests"}
            }}
        ]
    ].

a_notice_during_startup_is_read_past_test() ->
    Script = [
        [
            authentication_ok,
            {notice_response, #{message => ~"hello"}},
            {parameter_status, ~"server_version", ~"17.4"},
            {backend_key_data, 4242, 777},
            {ready_for_query, idle}
        ]
    ],
    {Server, Result} = connects(Script, #{}),
    ?assertMatch({ok, _Conn}, Result),
    {ok, Conn} = Result,
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server).

a_cleartext_password_is_refused_on_a_plain_socket_test() ->
    {Server, Result} = connects([[authentication_cleartext_password]], #{
        password => ~"pencil"
    }),
    ?assertEqual({error, cleartext_password_refused}, Result),
    ?assertMatch([{startup, _Parameters}, terminate], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

an_md5_password_is_answered_test() ->
    Script = [[{authentication_md5_password, ~"salt"}], ?READY],
    {Server, {ok, Conn}} = connects(Script, #{password => ~"pencil"}),
    ok = minato_conn:close(Conn),
    ?assertMatch(
        [{startup, _Parameters}, {password_message, _Digest} | _],
        minato_backend_server:received(Server)
    ),
    minato_backend_server:stop(Server).

a_password_given_as_a_string_is_answered_as_its_binary_test() ->
    Script = [[{authentication_md5_password, ~"salt"}], ?READY],
    {Text, {ok, AsText}} = connects(Script, #{password => "pencil"}),
    {Binary, {ok, AsBinary}} = connects(Script, #{password => ~"pencil"}),
    ok = minato_conn:close(AsText),
    ok = minato_conn:close(AsBinary),
    ?assertEqual(digest(Binary), digest(Text)),
    minato_backend_server:stop(Text),
    minato_backend_server:stop(Binary).

a_password_fun_answering_a_string_is_answered_as_its_binary_test() ->
    Script = [[{authentication_md5_password, ~"salt"}], ?READY],
    {Text, {ok, AsText}} = connects(Script, #{password => fun text_password/0}),
    {Binary, {ok, AsBinary}} = connects(Script, #{password => ~"pencil"}),
    ok = minato_conn:close(AsText),
    ok = minato_conn:close(AsBinary),
    ?assertEqual(digest(Binary), digest(Text)),
    minato_backend_server:stop(Text),
    minato_backend_server:stop(Binary).

a_password_fun_answering_something_else_raises_without_it_test() ->
    Server = minato_backend_server:start([[{authentication_md5_password, ~"salt"}]]),
    Opts = opts(minato_backend_server:port(Server), #{password => fun garbled_password/0}),
    Handler = {?MODULE, self()},
    {ok, _Started} = application:ensure_all_started(telemetry),
    ok = telemetry:attach(Handler, [minato, connect, exception], fun ?MODULE:exception/4, self()),
    try
        {Class, Reason, Stacktrace} =
            try minato_conn:connect(Opts) of
                Returned -> {returned, Returned, []}
            catch
                C:R:S -> {C, R, S}
            end,
        ?assertMatch({error, {minato_conn, #{reason := not_text}}}, {Class, Reason}),
        Metadata =
            receive
                {exception, Seen} -> Seen
            after 1000 -> error(no_exception_event)
            end,
        ?assertEqual(
            nomatch,
            string:find(io_lib:format("~0tp", [{Reason, Stacktrace, Metadata}]), "s3cr3t-garbled")
        )
    after
        ok = telemetry:detach(Handler),
        minato_backend_server:stop(Server)
    end.

-doc false.
exception(_Event, _Measurements, Metadata, Test) ->
    Test ! {exception, Metadata},
    ok.

a_raise_during_connect_is_returned_by_attempt_test() ->
    Server = minato_backend_server:start([[authentication_ok, bind_complete]]),
    Opts = opts(minato_backend_server:port(Server), #{}),
    ?assertEqual({error, {minato_conn, unexpected_during_startup}}, minato_conn:attempt(Opts)),
    minato_backend_server:stop(Server).

an_authentication_raise_is_returned_by_attempt_test() ->
    Server = minato_backend_server:start([[{authentication_sasl, [~"SCRAM-SHA-512"]}]]),
    Opts = opts(minato_backend_server:port(Server), #{password => ~"pencil"}),
    ?assertEqual(
        {error, {minato_auth, {no_supported_mechanism, [~"SCRAM-SHA-512"]}}},
        minato_conn:attempt(Opts)
    ),
    minato_backend_server:stop(Server).

a_scram_raise_is_returned_by_attempt_test() ->
    Server = minato_backend_server:start([
        [{authentication_sasl, [~"SCRAM-SHA-256"]}],
        [{authentication_sasl_continue, ~"r=forged,s=c2FsdA==,i=4096"}]
    ]),
    Opts = opts(minato_backend_server:port(Server), #{
        password => ~"pencil", channel_binding => disable
    }),
    ?assertMatch({error, {minato_scram, _Reason}}, minato_conn:attempt(Opts)),
    minato_backend_server:stop(Server).

an_atom_raised_during_connect_is_kept_by_attempt_test() ->
    Server = minato_backend_server:start([[{authentication_md5_password, ~"salt"}]]),
    Opts = opts(minato_backend_server:port(Server), #{password => fun raising_password/0}),
    ?assertEqual(
        {error, {connect_raised, error, password_store_down}}, minato_conn:attempt(Opts)
    ),
    minato_backend_server:stop(Server).

any_other_raise_is_returned_by_attempt_as_its_class_test() ->
    Server = minato_backend_server:start([[{authentication_md5_password, ~"salt"}]]),
    Opts = opts(minato_backend_server:port(Server), #{password => fun throwing_password/0}),
    ?assertEqual({error, {connect_raised, throw}}, minato_conn:attempt(Opts)),
    minato_backend_server:stop(Server).

a_successful_attempt_is_a_connection_test() ->
    Server = minato_backend_server:start([?READY]),
    {ok, Conn} = minato_conn:attempt(opts(minato_backend_server:port(Server), #{})),
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server).

raising_password() ->
    error(password_store_down).

throwing_password() ->
    throw({store, ~"s3cr3t-thrown"}).

text_password() ->
    "pencil".

garbled_password() ->
    ["s3cr3t-garbled", nope].

digest(Server) ->
    [Digest] = [D || {password_message, D} <- minato_backend_server:received(Server)],
    Digest.

a_method_outside_the_allowed_list_is_refused_test() ->
    {Server, Result} = connects([[{authentication_md5_password, ~"salt"}]], #{
        password => ~"pencil", auth => [scram_sha_256]
    }),
    ?assertEqual({error, {auth_method_refused, md5}}, Result),
    ?assertMatch([{startup, _Parameters}, terminate], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

a_trust_server_is_refused_when_a_password_was_required_test() ->
    {Server, Result} = connects([?READY], #{auth => [scram_sha_256]}),
    ?assertEqual({error, {auth_method_refused, none}}, Result),
    minato_backend_server:stop(Server).

a_server_that_declines_tls_is_refused_test() ->
    {Server, Result} = connects([{raw, ~"N"}], #{ssl => true}),
    ?assertEqual({error, tls_refused}, Result),
    ?assertEqual([ssl_request], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

an_error_response_during_startup_is_returned_test() ->
    Refusal = #{code => ~"28P01", message => ~"password authentication failed"},
    {Server, Result} = connects([[{error_response, Refusal}]], #{password => ~"wrong"}),
    ?assertMatch({error, {pgsql_error, #{code := ~"28P01"}}}, Result),
    minato_backend_server:stop(Server).

a_message_that_does_not_belong_in_a_startup_raises_test() ->
    Script = [[authentication_ok, bind_complete]],
    ?assertError(
        {minato_conn, #{reason := unexpected_during_startup}},
        element(2, connects(Script, #{}))
    ).

a_read_that_times_out_is_reported_test() ->
    {Server, Result} = connects([], #{timeout => 100}),
    ?assertEqual({error, {socket, timeout}}, Result),
    minato_backend_server:stop(Server).

a_server_that_closes_during_startup_is_reported_test() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, Port} = inet:port(Listen),
    spawn_link(fun() ->
        {ok, Socket} = gen_tcp:accept(Listen, 5000),
        ok = gen_tcp:close(Socket)
    end),
    %% Which word the machine uses for a peer that hung up mid-exchange is the
    %% machine's: Linux says the socket closed, Windows says the connection was
    %% aborted. What is being tested is that it is reported at all, and reported
    %% as a socket failure rather than as a connection.
    ?assertMatch({error, {socket, _Hung_up}}, minato_conn:connect(opts(Port, #{}))),
    ok = gen_tcp:close(Listen).

what_the_server_sent_beyond_ready_is_readable_test() ->
    Notification = {notification_response, 4242, ~"channel", ~"payload"},
    {Server, {ok, Conn}} = connects([?READY ++ [Notification]], #{}),
    ?assertMatch({ok, Notification, _Conn}, minato_conn:next(Conn)),
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server).

a_message_too_long_for_its_length_field_is_refused_unsent_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{}),
    Chunk = binary:copy(~"a", 16#1000000),
    TooLong = [Chunk || _ <- lists:seq(1, 257)],
    ?assertError(
        {minato_protocol, #{reason := message_too_long}},
        minato_conn:send(Conn, [{bind, ~"", ~"", [binary], [TooLong], []}, sync])
    ),
    ok = minato_conn:close(Conn),
    ?assertMatch([{startup, _Parameters}, terminate], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

close_sends_terminate_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{}),
    ok = minato_conn:close(Conn),
    ?assertMatch([{startup, _Parameters}, terminate], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

cancel_opens_a_second_connection_and_sends_the_key_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{}),
    ?assertEqual(ok, minato_conn:cancel(Conn)),
    ok = minato_conn:close(Conn),
    Received = minato_backend_server:received(Server),
    ?assert(lists:member({cancel_request, 4242, 777}, Received)),
    minato_backend_server:stop(Server).

a_deadline_cancels_and_then_gives_up_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{timeout => 2000, cancel_timeout => 150}),
    Bounded = minato_conn:deadline(Conn, 100),
    ok = minato_conn:send(Bounded, {query, ~"SELECT 1"}),
    ?assertEqual({error, {socket, timeout}}, minato_conn:next(Bounded)),
    Received = minato_backend_server:received(Server),
    ?assert(lists:member({cancel_request, 4242, 777}, Received)),
    ok = minato_conn:close(Bounded),
    minato_backend_server:stop(Server).

a_deadline_is_cleared_when_the_statement_ends_test() ->
    Ready = {ready_for_query, idle},
    {Server, {ok, Conn}} = connects([?READY ++ [Ready]], #{timeout => 2000}),
    Bounded = minato_conn:deadline(Conn, 100),
    {ok, Ready, Cleared} = minato_conn:next(Bounded),
    ?assertEqual({error, {socket, timeout}}, minato_conn:next(Cleared, 100)),
    ok = minato_conn:close(Cleared),
    minato_backend_server:stop(Server).

close_sends_terminate_over_inet_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{transport => inet}),
    ok = minato_conn:close(Conn),
    ?assertMatch([{startup, _Parameters}, terminate], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

a_message_read_but_not_taken_is_not_usable_test() ->
    Notification = {notification_response, 4242, ~"channel", ~"payload"},
    {Server, {ok, Conn}} = connects([?READY ++ [Notification]], #{}),
    Usable = minato_conn:usable(Conn),
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server),
    ?assertNot(Usable).

cancel_without_a_key_is_refused_test() ->
    Script = [[authentication_ok, {ready_for_query, idle}]],
    {Server, {ok, Conn}} = connects(Script, #{}),
    ?assertEqual({error, {socket, no_backend_key}}, minato_conn:cancel(Conn)),
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server).

an_idle_connection_is_usable_test() ->
    lists:foreach(
        fun(Transport) ->
            {Server, {ok, Conn}} = connects([?READY], #{transport => Transport}),
            ?assert(minato_conn:usable(Conn)),
            ok = minato_conn:close(Conn),
            minato_backend_server:stop(Server)
        end,
        [socket, inet]
    ).

bytes_the_server_sent_later_are_not_usable_test() ->
    lists:foreach(
        fun(Transport) ->
            Script = [?READY, [{notice_response, #{message => ~"hello"}}]],
            {Server, {ok, Conn}} = connects(Script, #{transport => Transport}),
            ok = minato_conn:send(Conn, sync),
            ?assert(eventually(fun() -> not minato_conn:usable(Conn) end, 100)),
            ok = minato_conn:close(Conn),
            minato_backend_server:stop(Server)
        end,
        [socket, inet]
    ).

a_connection_waiting_for_a_message_is_not_usable_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{}),
    {ok, Waiting} = minato_conn:activate(Conn),
    Usable = minato_conn:usable(Waiting),
    {ok, Read} = minato_conn:deactivate(Waiting),
    ok = minato_conn:close(Read),
    minato_backend_server:stop(Server),
    ?assertNot(Usable).

%%----------------------------------------------------------------------
%% Closing a TLS session, as Windows does it and as everything else does
%%----------------------------------------------------------------------

a_tls_session_is_closed_once_the_server_has_test() ->
    {Server, {ok, Conn}} = tls_connects(#{}, #{}),
    {Took, ok} = timed(fun() -> minato_conn:close(Conn, ?WINDOWS) end),
    ?assert(Took < 500),
    ?assertMatch([ssl_request, {startup, _}, terminate], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

on_windows_a_tls_close_waits_for_the_server_test() ->
    {Server, {ok, Conn}} = tls_connects(#{after_terminate => hold}, #{cancel_timeout => 300}),
    {Took, ok} = timed(fun() -> minato_conn:close(Conn, ?WINDOWS) end),
    ?assert(Took >= 300),
    ?assert(Took < 1000),
    ?assertMatch([_, _, terminate, closed], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

the_wait_is_bounded_in_total_not_per_read_test() ->
    {Server, {ok, Conn}} = tls_connects(#{after_terminate => chatter}, #{cancel_timeout => 300}),
    {Took, ok} = timed(fun() -> minato_conn:close(Conn, ?WINDOWS) end),
    ?assert(Took >= 300),
    ?assert(Took < 1000),
    minato_backend_server:stop(Server).

no_cancel_timeout_is_no_wait_test() ->
    {Server, {ok, Conn}} = tls_connects(#{after_terminate => hold}, #{cancel_timeout => 0}),
    {Took, ok} = timed(fun() -> minato_conn:close(Conn, ?WINDOWS) end),
    ?assert(Took < 200),
    minato_backend_server:stop(Server).

the_wait_never_exceeds_a_second_test() ->
    lists:foreach(
        fun(Grace) ->
            {Server, {ok, Conn}} = tls_connects(#{after_terminate => hold}, Grace),
            {Took, ok} = timed(fun() -> minato_conn:close(Conn, ?WINDOWS) end),
            ?assert(Took >= 1000),
            ?assert(Took < 1500),
            minato_backend_server:stop(Server)
        end,
        [#{}, #{cancel_timeout => infinity}]
    ).

a_tls_session_reading_for_messages_is_drained_too_test() ->
    {Server, {ok, Conn}} = tls_connects(#{after_terminate => hold}, #{cancel_timeout => 300}),
    {ok, Active} = minato_conn:activate(Conn),
    {Took, ok} = timed(fun() -> minato_conn:close(Active, ?WINDOWS) end),
    ?assert(Took >= 300),
    minato_backend_server:stop(Server).

elsewhere_a_tls_close_does_not_wait_test() ->
    {Server, {ok, Conn}} = tls_connects(#{after_terminate => hold}, #{}),
    {Took, ok} = timed(fun() -> minato_conn:close(Conn, ?POSIX) end),
    ?assert(Took < 200),
    ?assertMatch([_, _, terminate, closed], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

%% Set aside by a process that exits straight away, as a pool's caller might: the
%% session outlives it only if the closer really took it over.
a_tls_close_set_aside_does_not_wait_test() ->
    {Server, {ok, Conn}} = tls_connects(#{after_terminate => hold}, #{}),
    Test = self(),
    Owner = spawn(fun() -> set_aside(Test) end),
    ok = minato_conn:give_away(Conn, Owner),
    Started = erlang:monotonic_time(millisecond),
    Owner ! {close_aside, Conn},
    receive
        {set_aside, Answer} -> ?assertEqual(ok, Answer)
    end,
    ?assert(erlang:monotonic_time(millisecond) - Started < 200),
    ?assertEqual(ok, said(Server, closed, 3000)),
    ?assert(erlang:monotonic_time(millisecond) - Started >= 1000),
    minato_backend_server:stop(Server).

set_aside(Test) ->
    receive
        {close_aside, Conn} -> Test ! {set_aside, minato_conn:close_aside(Conn, ?WINDOWS)}
    end.

a_close_that_cannot_be_set_aside_leaves_no_closer_test() ->
    {Server, {ok, Conn}} = tls_connects(#{}, #{}),
    ok = minato_conn:close(Conn, ?POSIX),
    Closers = closers(),
    {Took, ok} = timed(fun() -> minato_conn:close_aside(Conn, ?WINDOWS) end),
    ?assert(Took < 500),
    timer:sleep(100),
    ?assertEqual(Closers, closers()),
    minato_backend_server:stop(Server).

%% The session the closer is handed may already be gone, and `m:ssl` answers
%% a write to one of those by exiting the caller as readily as with an error.
a_closer_handed_a_session_that_is_gone_ends_quietly_test() ->
    {Server, {ok, Conn}} = tls_connects(#{}, #{}),
    Closer = proc_lib:spawn(minato_conn, closer, [?WINDOWS]),
    Ref = monitor(process, Closer),
    ok = minato_conn:give_away(Conn, Closer),
    Session = ended(Conn),
    Closer ! {minato_conn, close, Session, 100},
    receive
        {'DOWN', Ref, process, Closer, Reason} -> ?assertEqual(normal, Reason)
    after 4000 -> error(closer_lives_on)
    end,
    minato_backend_server:stop(Server).

a_close_of_a_session_that_is_gone_is_still_ok_test_() ->
    [
        {Label, fun() ->
            {Server, {ok, Conn}} = tls_connects(#{}, Given),
            _ = ended(Conn),
            ?assertEqual(ok, minato_conn:close(Conn, ?POSIX)),
            ?assertEqual(ok, minato_conn:close(Conn, ?WINDOWS)),
            ?assertEqual(ok, minato_conn:close_aside(Conn, ?POSIX)),
            ?assertEqual(ok, minato_conn:close_aside(Conn, ?WINDOWS)),
            minato_backend_server:stop(Server)
        end}
     || {Label, Given} <- [{"socket", #{}}, {"driver", #{transport => inet}}]
    ].

%% Kills the processes of the TLS session a connection holds, and answers the
%% session. The connection is opaque, and so is the session: both are searched.
ended(Conn) ->
    [Session] = [
        Field
     || Field <- tuple_to_list(Conn), is_tuple(Field), element(1, Field) =:= sslsocket
    ],
    Pids = [Pid || Pid <- tuple_to_list(Session), is_pid(Pid)],
    Monitors = [monitor(process, Pid) || Pid <- Pids],
    _ = [exit(Pid, kill) || Pid <- Pids],
    _ = [
        receive
            {'DOWN', Monitor, process, _Pid, _Reason} -> ok
        end
     || Monitor <- Monitors
    ],
    Session.

an_overdue_closer_is_killed_and_logged_test() ->
    _ = logger:remove_handler(overdue_capture),
    ok = logger:add_handler(overdue_capture, ?MODULE, #{config => self()}),
    Closer = spawn(fun() ->
        receive
            never -> ok
        end
    end),
    Ref = monitor(process, Closer),
    try
        ok = minato_conn:overdue(Closer),
        receive
            {logged, warning, #{what := tls_close_overdue, closer := Closer}} -> ok
        after 1000 -> error(not_logged)
        end,
        receive
            {'DOWN', Ref, process, Closer, Reason} -> ?assertEqual(killed, Reason)
        after 1000 -> error(closer_not_killed)
        end,
        ?assertEqual(ok, minato_conn:overdue(Closer))
    after
        logger:remove_handler(overdue_capture)
    end.

a_closer_never_told_to_close_is_killed_test_() ->
    {timeout, 15, fun() ->
        Closer = proc_lib:spawn(minato_conn, closer, [?WINDOWS]),
        Ref = monitor(process, Closer),
        receive
            {'DOWN', Ref, process, Closer, Reason} -> ?assertEqual(killed, Reason)
        after 7000 -> error(closer_lives_on)
        end
    end}.

log(#{level := Level, msg := {report, Report}}, #{config := Test}) ->
    Test ! {logged, Level, Report};
log(_Event, _Config) ->
    ok.

closers() ->
    length([
        Pid
     || Pid <- processes(), proc_lib:initial_call(Pid) =:= {minato_conn, closer, ['Argument__1']}
    ]).

elsewhere_a_close_is_not_set_aside_test() ->
    ok = plain_close_aside(?WINDOWS),
    ok = plain_close_aside(?POSIX),
    {Server, {ok, Conn}} = tls_connects(#{after_terminate => hold}, #{}),
    {Took, ok} = timed(fun() -> minato_conn:close_aside(Conn, ?POSIX) end),
    ?assert(Took < 200),
    ?assertMatch([_, _, terminate, closed], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

the_machine_it_runs_on_decides_whether_to_set_a_close_aside_test() ->
    {Server, {ok, Conn}} = connects([?READY], #{}),
    ok = minato_conn:close_aside(Conn),
    ?assertMatch([{startup, _}, terminate], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

plain_close_aside(Os) ->
    {Server, {ok, Conn}} = connects([?READY], #{}),
    ok = minato_conn:close_aside(Conn, Os),
    ?assertMatch([{startup, _}, terminate], minato_backend_server:received(Server)),
    minato_backend_server:stop(Server).

on_windows_a_tls_cancel_waits_for_the_server_test() ->
    {Server, {ok, Conn}} = tls_connects(#{after_terminate => hold}, #{cancel_timeout => 300}),
    {Took, ok} = timed(fun() -> minato_conn:cancel(Conn, ?WINDOWS) end),
    ?assert(Took >= 300),
    ?assert(Took < 1000),
    Received = minato_backend_server:received(Server),
    ?assert(lists:member({cancel_request, 4242, 777}, Received)),
    ok = minato_conn:close(Conn, ?POSIX),
    minato_backend_server:stop(Server).

a_tls_cancel_sends_the_key_test() ->
    {Server, {ok, Conn}} = tls_connects(#{}, #{}),
    {Took, ok} = timed(fun() -> minato_conn:cancel(Conn) end),
    ?assert(Took < 500),
    Received = minato_backend_server:received(Server),
    ?assert(lists:member({cancel_request, 4242, 777}, Received)),
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server).

elsewhere_a_tls_cancel_does_not_wait_test() ->
    {Server, {ok, Conn}} = tls_connects(#{after_terminate => hold}, #{}),
    {Took, ok} = timed(fun() -> minato_conn:cancel(Conn, ?POSIX) end),
    ?assert(Took < 200),
    ok = minato_conn:close(Conn, ?POSIX),
    minato_backend_server:stop(Server).

%%----------------------------------------------------------------------
%% Talking to the server
%%----------------------------------------------------------------------

connects(Script, Opts) ->
    Server = minato_backend_server:start(Script),
    Port = minato_backend_server:port(Server),
    {Server, minato_conn:connect(opts(Port, Opts))}.

opts(Port, Opts) ->
    maps:merge(
        #{host => "127.0.0.1", port => Port, user => ~"minato", timeout => 5000},
        Opts
    ).

tls_connects(ServerOpts, Opts) ->
    {ok, _Started} = application:ensure_all_started(ssl),
    Server = minato_backend_server:start([?READY], ServerOpts#{tls => true}),
    Port = minato_backend_server:port(Server),
    Tls = #{ssl => true, ssl_options => minato_backend_server:client_tls(Server)},
    {Server, minato_conn:connect(opts(Port, maps:merge(Tls, Opts)))}.

timed(Fun) ->
    Started = erlang:monotonic_time(millisecond),
    Result = Fun(),
    {erlang:monotonic_time(millisecond) - Started, Result}.

said(Server, Message, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    said(Server, Message, Deadline, minato_backend_server:received(Server)).

said(Server, Message, Deadline, Received) ->
    case lists:member(Message, Received) of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> said(Server, Message, Deadline, minato_backend_server:received(Server));
                false -> {error, never_said}
            end
    end.

eventually(_Check, 0) ->
    false;
eventually(Check, Attempts) ->
    case Check() of
        true ->
            true;
        false ->
            timer:sleep(10),
            eventually(Check, Attempts - 1)
    end.
