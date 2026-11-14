-module(minato_hostile_server_tests).
-moduledoc """
A server that is trying, against a client that has to stay standing.

`m:minato_conn_tests` covers a server that is awkward. These cover one that is
hostile, or one with somebody in the middle: it answers within the protocol and
chooses every answer to cost the client something. Each test states what the
client must still have afterwards.
""".

-include_lib("eunit/include/eunit.hrl").

-define(POOL, minato_hostile_server_tests_pool).
-define(LISTENER, minato_hostile_server_tests_listener).

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
%% An opening exchange that does not end
%%----------------------------------------------------------------------

a_server_that_keeps_talking_without_finishing_is_given_up_on_test_() ->
    [
        {timeout, 30,
            {Label, fun() ->
                Started = erlang:monotonic_time(millisecond),
                {Server, Result} = connects([dripping(Before, Message, 100)], #{timeout => 300}),
                Elapsed = erlang:monotonic_time(millisecond) - Started,
                minato_backend_server:stop(Server),
                ?assertEqual({error, {socket, timeout}}, Result),
                ?assert(Elapsed < 2000)
            end}}
     || {Label, Before, Message} <- [
            {"notices before it has authenticated", [], notice()},
            {"notices after", [authentication_ok], notice()},
            {"parameters after", [authentication_ok], {parameter_status, ~"TimeZone", ~"UTC"}}
        ]
    ].

%% One message every 50 milliseconds, which is inside any read timeout, for
%% five seconds, which is outside the one the test gives the exchange.
dripping(Before, _Message, 0) ->
    Before;
dripping(Before, Message, Count) ->
    {then, Before, 50, dripping([Message], Message, Count - 1)}.

notice() ->
    {notice_response, #{severity => ~"NOTICE", code => ~"00000", message => ~"still here"}}.

an_opening_exchange_with_no_timeout_is_not_given_up_on_test() ->
    Slow = {then, [authentication_ok], 300, tl(?READY)},
    {Server, Result} = connects([Slow], #{timeout => infinity}),
    ?assertMatch({ok, _Conn}, Result),
    {ok, Conn} = Result,
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server).

the_parameters_a_server_reports_are_kept_up_to_a_bound_test() ->
    Flood = [
        {parameter_status, <<"invented_", (integer_to_binary(N))/binary>>, ~"on"}
     || N <- lists:seq(1, 500)
    ],
    Long = {parameter_status, ~"search_path", binary:copy(~"x", 5000)},
    Script = [
        [authentication_ok, {parameter_status, ~"server_version", ~"17.4"}, Long] ++ Flood ++
            [{parameter_status, ~"server_version", ~"17.5"}, {ready_for_query, idle}]
    ],
    {Server, {ok, Conn}} = connects(Script, #{}),
    Parameters = minato_conn:parameters(Conn),
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server),
    ?assertEqual(64, map_size(Parameters)),
    ?assertEqual(~"17.5", maps:get(~"server_version", Parameters)),
    ?assertNot(is_map_key(~"search_path", Parameters)),
    ?assert(is_map_key(~"invented_1", Parameters)),
    ?assertNot(is_map_key(~"invented_500", Parameters)).

a_parameter_does_not_keep_the_read_it_arrived_in_test() ->
    Padding = {notice_response, #{message => binary:copy(~"x", 100000)}},
    {Server, {ok, Conn}} = connects([[Padding | ?READY]], #{}),
    #{~"server_version" := Version} = minato_conn:parameters(Conn),
    ok = minato_conn:close(Conn),
    minato_backend_server:stop(Server),
    ?assertEqual(byte_size(Version), binary:referenced_byte_size(Version)).

a_connect_timeout_covers_the_tls_request_and_the_handshake_together_test_() ->
    {timeout, 30, fun() ->
        {ok, _Started} = application:ensure_all_started(ssl),
        {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}]),
        {ok, Port} = inet:port(Listen),
        Stalling = spawn_link(fun() ->
            {ok, Socket} = gen_tcp:accept(Listen, 5000),
            {ok, _Request} = gen_tcp:recv(Socket, 8, 5000),
            ok = timer:sleep(600),
            ok = gen_tcp:send(Socket, ~"S"),
            receive
                stop -> gen_tcp:close(Socket)
            end
        end),
        Started = erlang:monotonic_time(millisecond),
        Result = minato_conn:connect(
            opts(Port, #{
                ssl => true, ssl_options => [{verify, verify_none}], connect_timeout => 1000
            })
        ),
        Elapsed = erlang:monotonic_time(millisecond) - Started,
        Stalling ! stop,
        ok = gen_tcp:close(Listen),
        ?assertEqual({error, {tls, timeout}}, Result),
        ?assert(Elapsed < 1400)
    end}.

%%----------------------------------------------------------------------
%% A certificate for somebody else
%%----------------------------------------------------------------------

%% The server's certificate is for `localhost`. Leaving the name out of the
%% handshake must not also leave it out of what the certificate is checked for.
the_hostname_is_checked_with_no_server_name_sent_test_() ->
    [
        {Label, fun() ->
            Server = tls_server([?READY]),
            Trusted = proplists:lookup_all(cacerts, minato_backend_server:client_tls(Server)),
            Opts = opts(minato_backend_server:port(Server), #{
                host => Host,
                socket_options => [inet],
                ssl => true,
                ssl_options => Trusted ++ [{server_name_indication, disable} | Given]
            }),
            Result = minato_conn:connect(Opts),
            _ = [minato_conn:close(Conn) || {ok, Conn} <- [Result]],
            minato_backend_server:stop(Server),
            ?assertMatch(Expected, element(1, Result), Result)
        end}
     || {Label, Host, Given, Expected} <- [
            {"the name the certificate carries", "localhost", [], ok},
            {"another name", "127.0.0.1", [], error},
            {"another name, with verification turned off", "127.0.0.1", [{verify, verify_none}],
                ok},
            {"another name, with a check of the caller's own", "127.0.0.1",
                [{customize_hostname_check, [{match_fun, fun any_hostname/2}]}], ok}
        ]
    ].

any_hostname(_Reference, _Presented) ->
    true.

a_hostname_check_refuses_what_validation_refused_test_() ->
    State = {{dns_id, "localhost"}, []},
    [
        ?_assertEqual(
            {fail, {bad_cert, cert_expired}},
            minato_conn:verified(undefined, {bad_cert, cert_expired}, State)
        ),
        ?_assertEqual({unknown, State}, minato_conn:verified(undefined, {extension, any}, State)),
        ?_assertEqual({valid, State}, minato_conn:verified(undefined, valid, State))
    ].

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
%% The limit a pool asks its first connection for
%%----------------------------------------------------------------------

a_limit_is_read_from_a_short_run_of_digits_and_nothing_else_test_() ->
    [
        ?_assertEqual(Expected, minato_pool:limit(Results))
     || {Expected, Results} <- [
            {100, [#{rows => [{~"100"}]}]},
            {0, [#{rows => [{~"0"}]}]},
            {unknown, [#{rows => [{~"plenty"}]}]},
            {unknown, [#{rows => [{~"100 or so"}]}]},
            {unknown, [#{rows => [{~"-1"}]}]},
            {unknown, [#{rows => [{~""}]}]},
            {unknown, [#{rows => [{binary:copy(~"9", 11)}]}]},
            {unknown, [#{rows => [{null}]}]},
            {unknown, [#{rows => [{~"100"}, {~"200"}]}]},
            {unknown, [#{rows => [{~"100", ~"200"}]}]},
            {unknown, [#{rows => []}]},
            {unknown, []}
        ]
    ].

a_pool_outlives_whatever_answers_its_question_test_() ->
    [
        {timeout, 30,
            {Label, fun() ->
                {ok, _Started} = application:ensure_all_started(minato),
                Server = minato_backend_server:start([?READY, Answer]),
                Connection = opts(minato_backend_server:port(Server), #{timeout => 1000}),
                {ok, Pool} = minato:start_pool(?POOL, #{
                    size => 1, min_size => 1, connection => Connection
                }),
                try
                    ok = asked_for_the_limit(Server, 50),
                    timer:sleep(300),
                    ?assertEqual(Pool, whereis(?POOL)),
                    ?assertMatch(#{size := 1}, minato:stats(?POOL))
                after
                    ok = minato:stop_pool(?POOL),
                    minato_backend_server:stop(Server)
                end
            end}}
     || {Label, Answer} <- [
            {"a limit that is not a number", shown(~"plenty")},
            {"a limit of a megabyte of digits", shown(binary:copy(~"9", 1 bsl 20))},
            {"a row with no columns", [{data_row, <<0:16>>}, {ready_for_query, idle}]},
            {"a message that is not one", [{unsupported, $D, ~"x"}, {ready_for_query, idle}]},
            {"a refusal", [
                {error_response, #{severity => ~"ERROR", code => ~"42501"}},
                {ready_for_query, idle}
            ]}
        ]
    ].

a_pool_still_answers_while_its_question_goes_unanswered_test_() ->
    {timeout, 30, fun() ->
        {ok, _Started} = application:ensure_all_started(minato),
        Server = minato_backend_server:start([?READY]),
        Connection = opts(minato_backend_server:port(Server), #{timeout => 5000}),
        {ok, _Pool} = minato:start_pool(?POOL, #{
            size => 1, min_size => 1, connection => Connection
        }),
        try
            ok = asked_for_the_limit(Server, 50),
            {Microseconds, Stats} = timer:tc(fun() -> minato:stats(?POOL) end),
            ?assertMatch(#{size := 1, idle := 0}, Stats),
            ?assert(Microseconds < 1000000)
        after
            ok = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end}.

shown(Limit) ->
    [
        {row_description, [
            #{
                name => ~"max_connections",
                table_oid => 0,
                column => 0,
                type_oid => 25,
                type_size => -1,
                type_modifier => -1,
                format => text
            }
        ]},
        {data_row, [Limit]},
        {command_complete, ~"SHOW"},
        {ready_for_query, idle}
    ].

asked_for_the_limit(_Server, 0) ->
    error(never_asked);
asked_for_the_limit(Server, Tries) ->
    case
        [Sql || {query, ~"SHOW max_connections" = Sql} <- minato_backend_server:received(Server)]
    of
        [] -> asked_for_the_limit(Server, Tries - 1);
        _Asked -> ok
    end.

%%----------------------------------------------------------------------
%% A listener
%%----------------------------------------------------------------------

a_listener_reconnects_after_a_statement_that_lost_its_connection_test_() ->
    [
        {timeout, 30,
            {Label, fun() ->
                {ok, _Started} = application:ensure_all_started(minato),
                Server = minato_backend_server:start([?READY | Answers]),
                Connection = opts(minato_backend_server:port(Server), #{timeout => 300}),
                {ok, Listener} = minato:start_listener(?LISTENER, #{connection => Connection}),
                try
                    ?assertEqual({error, Expected}, minato:listen(?LISTENER, ~"events")),
                    ?assertEqual(2, startups(Server, 2, 50)),
                    ?assertEqual(Listener, whereis(?LISTENER)),
                    ?assertEqual(#{}, minato_listener:channels(?LISTENER))
                after
                    ok = minato:stop_listener(?LISTENER),
                    minato_backend_server:stop(Server)
                end
            end}}
     || {Label, Expected, Answers} <- [
            {"a statement nobody answers", {socket, timeout}, []},
            {"an answer that is not a message", {minato_protocol, malformed}, [
                [{unsupported, $Z, ~"not a status"}]
            ]}
        ]
    ].

a_listener_outlives_bytes_that_are_not_a_message_test_() ->
    {timeout, 30, fun() ->
        {ok, _Started} = application:ensure_all_started(minato),
        Listening = [{command_complete, ~"LISTEN"}, {ready_for_query, idle}],
        Unasked = [{unsupported, $Z, ~"not a status"}],
        Server = minato_backend_server:start([?READY, {then, Listening, 300, Unasked}, Listening]),
        Connection = opts(minato_backend_server:port(Server), #{timeout => 1000}),
        {ok, Listener} = minato:start_listener(?LISTENER, #{connection => Connection}),
        try
            ?assertEqual(ok, minato:listen(?LISTENER, ~"events")),
            receive
                {minato_listener, ?LISTENER, resubscribed} -> ok
            after 5000 -> error(never_resubscribed)
            end,
            ?assertEqual(Listener, whereis(?LISTENER)),
            ?assertEqual(#{~"events" => 1}, minato_listener:channels(?LISTENER))
        after
            ok = minato:stop_listener(?LISTENER),
            minato_backend_server:stop(Server)
        end
    end}.

startups(_Server, Wanted, _Tries) when Wanted =< 0 ->
    0;
startups(_Server, _Wanted, 0) ->
    0;
startups(Server, Wanted, Tries) ->
    Seen = length([Startup || {startup, _} = Startup <- minato_backend_server:received(Server)]),
    Seen + startups(Server, Wanted - Seen, Tries - 1).

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
