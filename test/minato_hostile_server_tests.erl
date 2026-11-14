-module(minato_hostile_server_tests).
-moduledoc """
A server that is trying, against a client that has to stay standing.

`m:minato_conn_tests` covers a server that is awkward. These cover one that is
hostile, or one with somebody in the middle: it answers within the protocol and
chooses every answer to cost the client something. Each test states what the
client must still have afterwards.
""".

-include_lib("eunit/include/eunit.hrl").

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).

%%----------------------------------------------------------------------
%% Command tags
%%----------------------------------------------------------------------

command_tags_a_server_invents_make_no_atoms_test() ->
    Warm = [{command_complete, ~"WARM UP"}, {ready_for_query, idle}],
    {Server, {ok, Conn}} = connects([?READY, Warm, invented_tags(1000)], #{}),
    {ok, [_Warm], Warmed} = minato_query:simple(Conn, ~"first"),
    Before = erlang:system_info(atom_count),
    {ok, Results, Read} = minato_query:simple(Warmed, ~"second"),
    After = erlang:system_info(atom_count),
    ok = minato_conn:close(Read),
    minato_backend_server:stop(Server),
    ?assertEqual(1000, length(Results)),
    ?assertMatch(#{command := ~"VERB1", num_rows := ~"NOUN1 OTHER1"}, hd(Results)),
    ?assertEqual(Before, After).

invented_tags(Count) ->
    [
        {command_complete, <<"VERB", N/binary, " NOUN", N/binary, " OTHER", N/binary>>}
     || N <- [integer_to_binary(I) || I <- lists:seq(1, Count)]
    ] ++ [{ready_for_query, idle}].

%%----------------------------------------------------------------------
%% Channel binding that was required
%%----------------------------------------------------------------------

a_required_binding_is_not_talked_down_to_another_method_test_() ->
    [
        {Label, fun() ->
            {Server, Result} = tls_connects([Asks, ?READY], #{
                password => ~"pencil", channel_binding => require
            }),
            Received = minato_backend_server:received(Server),
            minato_backend_server:stop(Server),
            ?assertEqual({error, {channel_binding_required, Method}}, Result),
            ?assertEqual([], [Sent || {password_message, Sent} <- Received])
        end}
     || {Label, Method, Asks} <- [
            {"cleartext over TLS", cleartext, [authentication_cleartext_password]},
            {"md5", md5, [{authentication_md5_password, ~"salt"}]},
            {"a server that asks for nothing", none, ?READY}
        ]
    ].

a_required_binding_is_not_talked_down_to_plain_scram_test() ->
    Server = tls_server([[{authentication_sasl, [~"SCRAM-SHA-256"]}], ?READY]),
    Opts = tls_opts(Server, #{password => ~"pencil", channel_binding => require}),
    ?assertError(
        {minato_auth, #{reason := {channel_binding_not_offered, [~"SCRAM-SHA-256"]}}},
        minato_conn:connect(Opts)
    ),
    Received = minato_backend_server:received(Server),
    minato_backend_server:stop(Server),
    ?assertEqual([], [Sent || {password_message, Sent} <- Received]).

a_required_binding_on_a_plain_socket_answers_nothing_test_() ->
    [
        {Label, fun() ->
            {Server, Result} = connects([Asks, ?READY], #{
                password => ~"pencil", channel_binding => require
            }),
            Received = minato_backend_server:received(Server),
            minato_backend_server:stop(Server),
            ?assertEqual({error, Expected}, Result),
            ?assertEqual([], [Sent || {password_message, Sent} <- Received])
        end}
     || {Label, Expected, Asks} <- [
            {"md5", {channel_binding_required, md5}, [{authentication_md5_password, ~"salt"}]},
            {"a server that asks for nothing", {channel_binding_required, none}, ?READY},
            {"cleartext", cleartext_password_refused, [authentication_cleartext_password]}
        ]
    ].

a_preferred_binding_still_answers_what_the_server_asks_for_test() ->
    {Server, Result} = tls_connects([[authentication_cleartext_password], ?READY], #{
        password => ~"pencil"
    }),
    ?assertMatch({ok, _Conn}, Result),
    {ok, Conn} = Result,
    ok = minato_conn:close(Conn),
    Received = minato_backend_server:received(Server),
    minato_backend_server:stop(Server),
    ?assertEqual([<<"pencil", 0>>], [Sent || {password_message, Sent} <- Received]).

the_allowed_methods_are_still_checked_under_a_required_binding_test() ->
    {Server, Result} = tls_connects([[{authentication_md5_password, ~"salt"}], ?READY], #{
        password => ~"pencil", auth => [scram_sha_256]
    }),
    minato_backend_server:stop(Server),
    ?assertEqual({error, {auth_method_refused, md5}}, Result).

%%----------------------------------------------------------------------
%% Talking to the server
%%----------------------------------------------------------------------

tls_connects(Script, Opts) ->
    Server = tls_server(Script),
    {Server, minato_conn:connect(tls_opts(Server, Opts))}.

tls_server(Script) ->
    {ok, _Started} = application:ensure_all_started(ssl),
    minato_backend_server:start(Script, #{tls => true}).

tls_opts(Server, Opts) ->
    Tls = #{ssl => true, ssl_options => minato_backend_server:client_tls(Server)},
    opts(minato_backend_server:port(Server), maps:merge(Tls, Opts)).

connects(Script, Opts) ->
    Server = minato_backend_server:start(Script),
    Port = minato_backend_server:port(Server),
    {Server, minato_conn:connect(opts(Port, Opts))}.

opts(Port, Opts) ->
    maps:merge(
        #{host => "127.0.0.1", port => Port, user => ~"minato", timeout => 5000},
        Opts
    ).
