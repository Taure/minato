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

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).

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

cancel_without_a_key_is_refused_test() ->
    Script = [[authentication_ok, {ready_for_query, idle}]],
    {Server, {ok, Conn}} = connects(Script, #{}),
    ?assertEqual({error, {socket, no_backend_key}}, minato_conn:cancel(Conn)),
    ok = minato_conn:close(Conn),
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
