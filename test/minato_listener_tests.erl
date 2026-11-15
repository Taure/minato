-module(minato_listener_tests).
-moduledoc """
`m:minato_listener` against a server that says exactly what each case needs.

`minato_listener_SUITE` has a real PostgreSQL publish and end backends. What is
asked here is which statements the listener sends for each subscriber that
comes and goes, and what it makes of answers a real server only gives when
something has already gone wrong.
""".

-include_lib("eunit/include/eunit.hrl").

-export([served/1, published/1, published_at_length/1, refusing/1, garbled/1, deaf/1]).

-define(LISTENER, minato_listener_tests_listener).

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).
-define(IDLE, {ready_for_query, idle}).

%%----------------------------------------------------------------------
%% Subscribing
%%----------------------------------------------------------------------

a_channel_is_listened_to_once_however_many_subscribe_test_() ->
    listening({?MODULE, served}, fun(Server) ->
        Other = subscriber(~"jobs"),
        ?assertEqual(ok, minato_listener:listen(?LISTENER, ~"jobs")),
        ?assertEqual(ok, minato_listener:listen(?LISTENER, ~"jobs")),
        ?assertEqual(#{~"jobs" => 2}, minato_listener:channels(?LISTENER)),
        ?assertEqual([~"LISTEN \"jobs\""], statements(Server)),
        ok = stopped(Other)
    end).

a_channel_is_left_when_its_last_subscriber_goes_test_() ->
    listening({?MODULE, served}, fun(Server) ->
        Other = subscriber(~"jobs"),
        ok = minato_listener:listen(?LISTENER, ~"jobs"),
        ?assertEqual(ok, minato_listener:unlisten(?LISTENER, ~"jobs")),
        ?assertEqual(ok, minato_listener:unlisten(?LISTENER, ~"jobs")),
        ?assertEqual(#{~"jobs" => 1}, minato_listener:channels(?LISTENER)),
        ?assertEqual([~"LISTEN \"jobs\""], statements(Server)),
        ok = stopped(Other),
        ?assertEqual(#{}, channels_once_quiet()),
        ?assertEqual([~"UNLISTEN \"jobs\""], statements(Server))
    end).

leaving_a_channel_nobody_listens_to_asks_nothing_test_() ->
    listening({?MODULE, served}, fun(Server) ->
        ?assertEqual(ok, minato_listener:unlisten(?LISTENER, ~"jobs")),
        ?assertEqual([], statements(Server))
    end).

a_subscriber_that_dies_is_dropped_from_every_channel_test_() ->
    listening({?MODULE, served}, fun(Server) ->
        Other = subscriber(~"jobs"),
        Other ! {listen, ~"mail"},
        ok = minato_listener:listen(?LISTENER, ~"mail"),
        ?assertEqual(#{~"jobs" => 1, ~"mail" => 2}, channels_once(2)),
        ok = stopped(Other),
        ?assertEqual(#{~"mail" => 1}, channels_once_quiet()),
        ?assertEqual(
            [~"LISTEN \"jobs\"", ~"LISTEN \"mail\"", ~"UNLISTEN \"jobs\""], statements(Server)
        )
    end).

a_channel_name_is_quoted_test_() ->
    listening({?MODULE, served}, fun(Server) ->
        ok = minato_listener:listen(?LISTENER, ~"a \"b\"; DROP TABLE t"),
        ?assertEqual([~"LISTEN \"a \"\"b\"\"; DROP TABLE t\""], statements(Server))
    end).

a_listen_the_server_refuses_is_an_error_and_no_subscription_test_() ->
    listening({?MODULE, refusing}, fun(_Server) ->
        ?assertMatch(
            {error, {pgsql_error, #{code := ~"42501"}}}, minato_listener:listen(?LISTENER, ~"jobs")
        ),
        ?assertEqual(#{}, minato_listener:channels(?LISTENER))
    end).

what_is_not_a_request_is_answered_as_one_test_() ->
    listening({?MODULE, served}, fun(_Server) ->
        ?assertEqual(
            {error, {unknown_call, hello}}, gen_server:call(?LISTENER, hello)
        ),
        ok = gen_server:cast(?LISTENER, hello),
        ?LISTENER ! hello,
        ?assertEqual(#{}, minato_listener:channels(?LISTENER))
    end).

%%----------------------------------------------------------------------
%% Delivering
%%----------------------------------------------------------------------

a_notification_reaches_every_subscriber_of_its_channel_test_() ->
    listening({?MODULE, published}, fun(_Server) ->
        ok = minato_listener:listen(?LISTENER, ~"quiet"),
        Other = subscriber(~"jobs"),
        ok = minato_listener:listen(?LISTENER, ~"jobs"),
        ?assertEqual([{~"jobs", ~"ready", 7}], notifications(1)),
        ?assertEqual([{~"jobs", ~"ready", 7}], told(Other)),
        ok = stopped(Other)
    end).

%% What a subscriber is sent is cut out of what was read off the socket. Kept
%% as it came, it would keep the whole read alive for as long as the subscriber
%% keeps the payload.
a_notification_holds_on_to_nothing_but_itself_test_() ->
    listening({?MODULE, published_at_length}, fun(_Server) ->
        ok = minato_listener:listen(?LISTENER, ~"jobs"),
        [{Channel, Payload, 7}] = notifications(1),
        ?assertEqual(~"jobs", Channel),
        ?assertEqual(200, byte_size(Payload)),
        ?assertEqual(byte_size(Payload), binary:referenced_byte_size(Payload)),
        ?assertEqual(byte_size(Channel), binary:referenced_byte_size(Channel))
    end).

%%----------------------------------------------------------------------
%% Losing the connection
%%----------------------------------------------------------------------

a_listener_with_nothing_to_connect_to_says_so_and_goes_on_trying_test_() ->
    {timeout, 30, fun() ->
        Server = minato_backend_server:start(script({?MODULE, served})),
        Port = minato_backend_server:port(Server),
        minato_backend_server:stop(Server),
        {ok, Pid} = minato_listener:start_link(?LISTENER, #{
            connection => (connection(Port))#{connect_timeout => 200}
        }),
        try
            ?assertEqual({error, not_connected}, minato_listener:listen(?LISTENER, ~"jobs")),
            ?assertEqual(ok, minato_listener:unlisten(?LISTENER, ~"jobs")),
            Pid ! {tcp, port, ~"nothing to read it"},
            ?assertEqual(#{}, minato_listener:channels(?LISTENER))
        after
            ok = minato_listener:stop(?LISTENER)
        end
    end}.

%% Every listener that lost the same server would otherwise ask for it again
%% at the same instants, each time the wait doubled. The first wait is over
%% before anybody can watch, so the ones after it are what is looked at.
a_listener_that_cannot_connect_waits_a_time_of_its_own_test_() ->
    {timeout, 30, fun() ->
        Server = minato_backend_server:start(script({?MODULE, served})),
        Port = minato_backend_server:port(Server),
        minato_backend_server:stop(Server),
        {ok, Pid} = minato_listener:start_link(?LISTENER, #{
            connection => (connection(Port))#{connect_timeout => 200}
        }),
        try
            Waits = waits(Pid, 3),
            Longest = [200, 400, 800],
            ?assert(
                lists:all(
                    fun({Wait, Most}) -> Wait >= Most div 2 andalso Wait =< Most end,
                    lists:zip(Waits, Longest)
                ),
                Waits
            ),
            ?assertNotEqual(Longest, Waits)
        after
            ok = minato_listener:stop(?LISTENER)
        end
    end}.

a_connection_that_drops_is_listened_on_again_and_announced_test_() ->
    listening({?MODULE, garbled}, fun(Server) ->
        ok = minato_listener:listen(?LISTENER, ~"jobs"),
        ok = minato_listener:listen(?LISTENER, ~"mail"),
        ?assertMatch({error, _Reason}, minato_listener:listen(?LISTENER, ~"garbled")),
        ?assertEqual([resubscribed, resubscribed], announcements(2)),
        ?assertEqual(#{~"jobs" => 1, ~"mail" => 1}, minato_listener:channels(?LISTENER)),
        ?assertEqual(
            [
                ~"LISTEN \"garbled\"",
                ~"LISTEN \"jobs\"",
                ~"LISTEN \"jobs\"",
                ~"LISTEN \"mail\"",
                ~"LISTEN \"mail\""
            ],
            lists:sort(statements(Server))
        )
    end).

a_listen_that_gets_no_answer_loses_the_connection_test_() ->
    listening({?MODULE, deaf}, #{timeout => 200}, fun(Server) ->
        ?assertMatch({error, _Reason}, minato_listener:listen(?LISTENER, ~"jobs")),
        ?assertEqual(#{}, minato_listener:channels(?LISTENER)),
        ?assert(lists:member(terminate, minato_backend_server:received(Server)))
    end).

an_invalid_connection_stops_the_listener_without_its_options_test_() ->
    [
        fun() ->
            Trapping = process_flag(trap_exit, true),
            try
                ?assertEqual(
                    {error, invalid_connection}, minato_listener:start_link(?LISTENER, Opts)
                ),
                receive
                    {'EXIT', _Pid, Reason} -> ?assertEqual(invalid_connection, Reason)
                after 1000 -> ok
                end
            after
                process_flag(trap_exit, Trapping)
            end
        end
     || Opts <- invalid()
    ].

invalid() ->
    [#{}, #{connection => #{host => "127.0.0.1"}}, #{connection => []}].

the_password_is_not_in_the_status_test_() ->
    listening({?MODULE, served}, fun(_Server) ->
        {status, _Pid, _Module, Items} = sys:get_status(?LISTENER),
        ?assertEqual(nomatch, string:find(io_lib:format("~p", [Items]), "s3cret"))
    end).

%%----------------------------------------------------------------------
%% What the server says
%%----------------------------------------------------------------------

served({query, <<"LISTEN ", _/binary>>}) -> [{command_complete, ~"LISTEN"}, ?IDLE];
served({query, <<"UNLISTEN ", _/binary>>}) -> [{command_complete, ~"UNLISTEN"}, ?IDLE];
served(_Message) -> [].

%% A server on which somebody publishes to `jobs` as soon as it is listened to.
published({query, ~"LISTEN \"jobs\""} = Listen) ->
    {then, served(Listen), 50, [
        {notification_response, 7, ~"jobs", ~"ready"},
        {notification_response, 8, ~"nobody", ~"unheard"}
    ]};
published(Message) ->
    served(Message).

published_at_length({query, ~"LISTEN \"jobs\""} = Listen) ->
    {then, served(Listen), 50, [{notification_response, 7, ~"jobs", binary:copy(~"x", 200)}]};
published_at_length(Message) ->
    served(Message).

refusing({query, _Sql}) ->
    [
        {error_response, #{severity => ~"ERROR", code => ~"42501", message => ~"denied"}},
        ?IDLE
    ];
refusing(_Message) ->
    [].

%% A server whose answer to one channel is not a message.
garbled({query, ~"LISTEN \"garbled\""}) -> {raw, <<"?", 0, 0, 0, 1>>};
garbled(Message) -> served(Message).

deaf(_Message) -> [].

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

script(Reply) ->
    [?READY | lists:duplicate(50, {reply, Reply})].

listening(Reply, Fun) ->
    listening(Reply, #{}, Fun).

listening(Reply, Opts, Fun) ->
    {timeout, 30, fun() ->
        Server = minato_backend_server:start(script(Reply)),
        Connection = maps:merge(connection(minato_backend_server:port(Server)), Opts),
        {ok, _Pid} = minato_listener:start_link(?LISTENER, #{connection => Connection}),
        try
            Fun(Server)
        after
            ok = minato_listener:stop(?LISTENER),
            minato_backend_server:stop(Server)
        end
    end}.

connection(Port) ->
    #{
        host => "127.0.0.1",
        port => Port,
        user => ~"minato",
        password => ~"s3cret",
        timeout => 1000
    }.

%% The listener answers its caller once the server has answered it, and what
%% it sends on its own is waited for before this is asked.
statements(Server) ->
    [Sql || {query, Sql} <- minato_backend_server:received(Server, 20)].

%% Another process subscribed to a channel, which reports what it is sent.
subscriber(Channel) ->
    Self = self(),
    Pid = spawn_link(fun() ->
        ok = minato_listener:listen(?LISTENER, Channel),
        Self ! {subscribed, self()},
        subscribed(Self)
    end),
    receive
        {subscribed, Pid} -> Pid
    after 5000 -> error(not_subscribed)
    end.

subscribed(Owner) ->
    receive
        {listen, Channel} ->
            ok = minato_listener:listen(?LISTENER, Channel),
            subscribed(Owner);
        {minato_notification, Channel, Payload, From} ->
            Owner ! {told, self(), {Channel, Payload, From}},
            subscribed(Owner);
        stop ->
            ok
    end.

told(Pid) ->
    receive
        {told, Pid, Notification} -> [Notification]
    after 2000 -> []
    end.

stopped(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    Pid ! stop,
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 5000 -> error(not_stopped)
    end.

notifications(Count) ->
    [
        receive
            {minato_notification, Channel, Payload, From} -> {Channel, Payload, From}
        after 2000 -> missing
        end
     || _Each <- lists:seq(1, Count)
    ].

%% How long the listener waits before each of its next attempts, read off the
%% timers it starts.
waits(Pid, Count) ->
    _ = erlang:trace_pattern({erlang, send_after, 3}, true, []),
    _ = erlang:trace(Pid, true, [call]),
    try
        [
            receive
                {trace, Pid, call, {erlang, send_after, [Wait, Pid, reconnect]}} -> Wait
            after 1000 -> missing
            end
         || _Each <- lists:seq(1, Count)
        ]
    after
        _ = erlang:trace(Pid, false, [call]),
        _ = erlang:trace_pattern({erlang, send_after, 3}, false, [])
    end.

announcements(Count) ->
    [
        receive
            {minato_listener, ?LISTENER, What} -> What
        after 5000 -> missing
        end
     || _Each <- lists:seq(1, Count)
    ].

channels_once(Count) ->
    channels_once(Count, 50).

channels_once(Count, Tries) ->
    case minato_listener:channels(?LISTENER) of
        Channels when map_size(Channels) =:= Count; Tries =:= 0 ->
            Channels;
        _Other ->
            timer:sleep(20),
            channels_once(Count, Tries - 1)
    end.

%% The listener hears of a subscriber's death in a message of its own, so the
%% question is asked after it has had the chance to read it.
channels_once_quiet() ->
    timer:sleep(100),
    minato_listener:channels(?LISTENER).
