-module(minato_hostile_server_tests).
-moduledoc """
A server that is trying, against a client that has to stay standing.

`m:minato_conn_tests` covers a server that is awkward. These cover one that is
hostile, or one with somebody in the middle: it answers within the protocol and
chooses every answer to cost the client something. Each test states what the
client must still have afterwards.
""".

-include_lib("eunit/include/eunit.hrl").

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
%% Column names
%%----------------------------------------------------------------------

%% The server picks the names of the columns it describes, and
%% `column_name_as_atom` used to make an atom of each.
column_names_a_server_invents_make_no_atoms_test_() ->
    [
        {atom_to_list(Path), fun() ->
            Invented = [
                column(<<"invented_", (integer_to_binary(N))/binary>>)
             || N <- lists:seq(1, 2000)
            ],
            Described = [column(~"id") | Invented],
            {Server, {ok, Conn}} = connects([?READY | described(Path, Described)], #{}),
            Opts = #{return_rows_as_maps => true, column_name_as_atom => true},
            Before = erlang:system_info(atom_count),
            {Row, Read} = asked(Path, Conn, Opts),
            After = erlang:system_info(atom_count),
            ok = minato_conn:close(Read),
            minato_backend_server:stop(Server),
            ?assertEqual(Before, After),
            ?assertEqual(2001, map_size(Row)),
            ?assertEqual([id], [Name || Name := _Value <- Row, is_atom(Name)]),
            ?assertMatch(#{id := ~"7", ~"invented_1" := ~"x", ~"invented_2000" := ~"x"}, Row)
        end}
     || Path <- [simple, extended]
    ].

column_names_that_are_atoms_already_come_back_as_atoms_test() ->
    Row = [{data_row, [~"7", ~"x"]}],
    Described = [column(~"id"), column(~"never_an_atom_before_this_row")],
    Script = [
        ?READY,
        [{row_description, Described}] ++ Row ++
            [{command_complete, ~"SELECT 1"}, {ready_for_query, idle}]
    ],
    {Server, {ok, Conn}} = connects(Script, #{}),
    {ok, [#{rows := Rows}], Read} = minato_query:simple(
        Conn, ~"q", #{return_rows_as_maps => true, column_name_as_atom => true}
    ),
    ok = minato_conn:close(Read),
    minato_backend_server:stop(Server),
    ?assertEqual([#{id => ~"7", ~"never_an_atom_before_this_row" => ~"x"}], Rows).

described(simple, Columns) ->
    [
        [
            {row_description, Columns},
            {data_row, one_row(Columns)},
            {command_complete, ~"SELECT 1"},
            {ready_for_query, idle}
        ]
    ];
described(extended, Columns) ->
    [
        [parse_complete],
        [{parameter_description, []}, {row_description, Columns}],
        [],
        [bind_complete],
        [{data_row, one_row(Columns)}, {command_complete, ~"SELECT 1"}],
        [{ready_for_query, idle}]
    ].

one_row([_Id | Invented]) ->
    [~"7" | [~"x" || _Column <- Invented]].

asked(simple, Conn, Opts) ->
    {ok, [#{rows := [Row]}], Read} = minato_query:simple(Conn, ~"q", Opts),
    {Row, Read};
asked(extended, Conn, Opts) ->
    {ok, #{rows := [Row]}, Read} = minato_query:query(Conn, ~"q", [], Opts),
    {Row, Read}.

column(Name) ->
    #{
        name => Name,
        table_oid => 0,
        column => 0,
        type_oid => 25,
        type_size => -1,
        type_modifier => -1,
        format => text
    }.

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
%% A server that stops reading
%%----------------------------------------------------------------------

a_write_to_a_server_that_stopped_reading_gives_up_test_() ->
    [
        {timeout, 60,
            {Label, fun() ->
                {Listen, Port, Deaf} = deaf_server(),
                {ok, Conn} = minato_conn:connect(
                    opts(Port, maps:merge(#{timeout => 500}, Given))
                ),
                Started = erlang:monotonic_time(millisecond),
                Result = filled(Conn, binary:copy(~"x", 1 bsl 20), 256),
                Elapsed = erlang:monotonic_time(millisecond) - Started,
                Deaf ! stop,
                ok = gen_tcp:close(Listen),
                ?assertEqual({error, {socket, timeout}}, Result),
                ?assert(Elapsed < 10000),
                ?assertMatch({error, {socket, _Closed}}, minato_conn:send(Conn, sync))
            end}}
     || {Label, Given} <- [
            {"on the socket transport", #{}},
            {"on the driver", #{transport => inet}},
            {"with a bound of the caller's own", #{
                timeout => 60000, socket_options => [{send_timeout, 300}]
            }}
        ]
    ].

%% The same peer behind TLS. `ssl:send/2` takes no deadline, and over the
%% socket transport there is no driver under it with one either, so that write
%% is ended from outside by `m:minato_overdue`, or by what stands in for it
%% where the application is not running. The read timeout is a minute:
%% whatever ends the write inside the assertion is the bound on the write.
a_tls_write_to_a_server_that_stopped_reading_gives_up_test_() ->
    [
        {timeout, 120,
            {Label, fun() ->
                {ok, _Started} = application:ensure_all_started(minato),
                _ = Application =:= stopped andalso application:stop(minato),
                Server = minato_backend_server:start([?READY], #{tls => true, after_script => stall}),
                {ok, Conn} = minato_conn:connect(
                    tls_opts(Server, maps:merge(#{timeout => 60000}, Given))
                ),
                Started = erlang:monotonic_time(millisecond),
                Result = filled(Conn, binary:copy(~"x", 1 bsl 20), 256),
                Elapsed = erlang:monotonic_time(millisecond) - Started,
                Again = minato_conn:send(Conn, sync),
                ok = minato_conn:close(Conn),
                minato_backend_server:stop(Server),
                {ok, _Restarted} = application:ensure_all_started(minato),
                ?assertEqual({error, {socket, timeout}}, Result),
                ?assert(Elapsed < 20000, Elapsed),
                ?assertMatch({error, {socket, _Closed}}, Again)
            end}}
     || {Label, Given, Application} <- [
            {"on the socket transport", #{socket_options => [{send_timeout, 500}]}, running},
            {"on the socket transport, left open by the caller",
                #{socket_options => [{send_timeout, 500}, {send_timeout_close, false}]}, running},
            {"on the socket transport, with the application stopped",
                #{socket_options => [{send_timeout, 500}]}, stopped},
            {"on the driver", #{transport => inet, socket_options => [{send_timeout, 500}]},
                running}
        ]
    ].

%% `Terminate` is a courtesy, and a peer that has stopped reading is not owed
%% a wait for it. The connection asks for no bound on a write, and another
%% process is already waiting in one, so nothing but the close's own bound can
%% end it. The last case is bounded by `m:ssl` and not by minato: its goodbye
%% is a write through a driver that is not taking any.
a_close_does_not_wait_on_a_server_that_stopped_reading_test_() ->
    [
        {timeout, 60,
            {Label, fun() ->
                {ok, _Started} = application:ensure_all_started(minato),
                Stalls = Server#{after_script => stall},
                Peer = minato_backend_server:start([?READY], Stalls),
                Unbounded = #{socket_options => [{send_timeout, infinity}]},
                Opts = maps:merge(Unbounded, Given),
                {ok, Conn} = minato_conn:connect(
                    case Server of
                        #{tls := true} -> tls_opts(Peer, Opts);
                        #{} -> opts(minato_backend_server:port(Peer), Opts)
                    end
                ),
                Megabyte = binary:copy(~"x", 1 bsl 20),
                Writer = spawn(fun() -> filled(Conn, Megabyte, 256) end),
                ok = timer:sleep(500),
                Started = erlang:monotonic_time(millisecond),
                Closed = minato_conn:close(Conn),
                Elapsed = erlang:monotonic_time(millisecond) - Started,
                exit(Writer, kill),
                minato_backend_server:stop(Peer),
                ?assertEqual(ok, Closed),
                ?assertEqual({ok, true}, {Closed, Elapsed < Bound orelse Elapsed})
            end}}
     || {Label, Server, Given, Bound} <- [
            {"on the socket transport", #{}, #{}, 3000},
            {"on the driver", #{}, #{transport => inet}, 3000},
            {"behind TLS on the socket transport", #{tls => true}, #{}, 3000},
            {"behind TLS on the driver, where ssl closes in its own time", #{tls => true},
                #{transport => inet}, 20000}
        ]
    ].

a_tls_write_that_is_in_time_is_left_alone_test() ->
    {ok, _Started} = application:ensure_all_started(minato),
    Answer = [{command_complete, ~"SELECT 0"}, {ready_for_query, idle}],
    {Server, {ok, Conn}} = tls_connects([?READY, Answer, Answer], #{
        socket_options => [{send_timeout, 100}]
    }),
    {ok, [_First], Read} = minato_query:simple(Conn, ~"first"),
    ok = timer:sleep(300),
    {ok, [_Second], Again} = minato_query:simple(Read, ~"second"),
    ok = minato_conn:close(Again),
    minato_backend_server:stop(Server).

%% Answers the startup and then reads nothing more, with a small receive
%% buffer so that it takes megabytes rather than gigabytes to fill.
deaf_server() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {recbuf, 4096}]),
    {ok, Port} = inet:port(Listen),
    Deaf = spawn_link(fun() ->
        {ok, Socket} = gen_tcp:accept(Listen, 5000),
        {ok, _Startup} = gen_tcp:recv(Socket, 0, 5000),
        ok = gen_tcp:send(Socket, minato_backend_writer:write_all(?READY)),
        receive
            stop -> gen_tcp:close(Socket)
        end
    end),
    {Listen, Port, Deaf}.

filled(_Conn, _Bytes, 0) ->
    never_filled;
filled(Conn, Bytes, Left) ->
    case minato_conn:send(Conn, {query, Bytes}) of
        ok -> filled(Conn, Bytes, Left - 1);
        {error, Reason} -> {error, Reason}
    end.

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
