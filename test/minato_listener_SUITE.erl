-module(minato_listener_SUITE).
-moduledoc """
`LISTEN` and `NOTIFY`, against a real PostgreSQL.

Notifications are the one thing in the client that arrives without being asked
for, so nothing about them can be proved without a server that sends them at a
time of its own choosing. Every case here notifies from a second connection and
waits for the message on the first.

The case that matters most is the reconnect. A listener whose connection drops
has missed whatever was published while it was away, because `NOTIFY` has no
replay, and a consumer that is not told will wait forever for news that already
happened. `pg_terminate_backend` makes the server drop it on demand, and the
suite requires both the resubscribe and the message that announces it.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    a_notification_reaches_a_subscriber/1,
    a_payload_arrives_unchanged/1,
    two_subscribers_both_get_it/1,
    an_unsubscribed_process_gets_nothing/1,
    a_channel_nobody_listens_to_is_dropped/1,
    a_subscriber_that_dies_is_dropped/1,
    a_channel_name_is_quoted_not_interpolated/1,
    a_dropped_connection_comes_back_and_says_so/1
]).

-define(TIMEOUT, 10000).
-define(LISTENER, minato_test_listener).
-define(POOL, minato_test_notify_pool).

-spec all() -> [atom()].
all() ->
    [
        a_notification_reaches_a_subscriber,
        a_payload_arrives_unchanged,
        two_subscribers_both_get_it,
        an_unsubscribed_process_gets_nothing,
        a_channel_nobody_listens_to_is_dropped,
        a_subscriber_that_dies_is_dropped,
        a_channel_name_is_quoted_not_interpolated,
        a_dropped_connection_comes_back_and_says_so
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(connection()) of
        {ok, Conn} ->
            ok = minato_conn:close(Conn),
            {ok, _Started} = application:ensure_all_started(minato),
            {ok, _Pool} = minato:start_pool(?POOL, #{size => 1, connection => connection()}),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok = application:stop(minato).

-spec init_per_testcase(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_testcase(_Case, Config) ->
    {ok, _Pid} = minato:start_listener(?LISTENER, #{connection => connection()}),
    Config.

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(_Case, _Config) ->
    ok = minato:stop_listener(?LISTENER).

-spec a_notification_reaches_a_subscriber([{atom(), term()}]) -> ok.
a_notification_reaches_a_subscriber(_Config) ->
    ok = minato:listen(?LISTENER, ~"minato_events"),
    ok = notify(~"minato_events", ~"one"),
    ?assertMatch({minato_notification, ~"minato_events", ~"one", _From}, waited()).

-spec a_payload_arrives_unchanged([{atom(), term()}]) -> ok.
a_payload_arrives_unchanged(_Config) ->
    ok = minato:listen(?LISTENER, ~"minato_events"),
    Payload = ~"{\"id\":1,\"name\":\"a b\"}",
    ok = notify(~"minato_events", Payload),
    {minato_notification, _Channel, Delivered, _From} = waited(),
    ?assertEqual(Payload, Delivered).

-spec two_subscribers_both_get_it([{atom(), term()}]) -> ok.
two_subscribers_both_get_it(_Config) ->
    Test = self(),
    Other = spawn(fun() ->
        ok = minato:listen(?LISTENER, ~"minato_events"),
        Test ! subscribed,
        Test ! {other, waited()}
    end),
    receive
        subscribed -> ok
    after ?TIMEOUT -> error(timeout)
    end,
    ok = minato:listen(?LISTENER, ~"minato_events"),
    ?assertEqual(#{~"minato_events" => 2}, minato_listener:channels(?LISTENER)),
    ok = notify(~"minato_events", ~"both"),
    ?assertMatch({minato_notification, _Channel, ~"both", _From}, waited()),
    receive
        {other, Delivered} -> ?assertMatch({minato_notification, _C, ~"both", _F}, Delivered)
    after ?TIMEOUT -> error(other_never_got_it)
    end,
    true = exit(Other, kill),
    ok.

-spec an_unsubscribed_process_gets_nothing([{atom(), term()}]) -> ok.
an_unsubscribed_process_gets_nothing(_Config) ->
    ok = minato:listen(?LISTENER, ~"minato_events"),
    ok = minato:unlisten(?LISTENER, ~"minato_events"),
    ok = notify(~"minato_events", ~"gone"),
    ?assertEqual(timeout, waited(500)).

-spec a_channel_nobody_listens_to_is_dropped([{atom(), term()}]) -> ok.
a_channel_nobody_listens_to_is_dropped(_Config) ->
    ok = minato:listen(?LISTENER, ~"minato_events"),
    ?assertEqual(#{~"minato_events" => 1}, minato_listener:channels(?LISTENER)),
    ok = minato:unlisten(?LISTENER, ~"minato_events"),
    ?assertEqual(#{}, minato_listener:channels(?LISTENER)).

-spec a_subscriber_that_dies_is_dropped([{atom(), term()}]) -> ok.
a_subscriber_that_dies_is_dropped(_Config) ->
    Test = self(),
    Subscriber = spawn(fun() ->
        ok = minato:listen(?LISTENER, ~"minato_events"),
        Test ! subscribed,
        receive
            never -> ok
        end
    end),
    receive
        subscribed -> ok
    after ?TIMEOUT -> error(timeout)
    end,
    true = exit(Subscriber, kill),
    ?assertEqual(ok, emptied(100)).

-spec a_channel_name_is_quoted_not_interpolated([{atom(), term()}]) -> ok.
a_channel_name_is_quoted_not_interpolated(_Config) ->
    Awkward = ~"minato; DROP TABLE nothing",
    ok = minato:listen(?LISTENER, Awkward),
    ok = notify(Awkward, ~"still here"),
    ?assertMatch({minato_notification, Awkward, ~"still here", _From}, waited()).

-spec a_dropped_connection_comes_back_and_says_so([{atom(), term()}]) -> ok.
a_dropped_connection_comes_back_and_says_so(_Config) ->
    ok = minato:listen(?LISTENER, ~"minato_events"),
    ok = terminated(),
    ?assertEqual({minato_listener, ?LISTENER, resubscribed}, resubscribed()),
    ?assertEqual(#{~"minato_events" => 1}, minato_listener:channels(?LISTENER)),
    ok = notify(~"minato_events", ~"after"),
    ?assertMatch({minato_notification, ~"minato_events", ~"after", _From}, waited()).

%%----------------------------------------------------------------------
%% Making the server do things
%%----------------------------------------------------------------------

notify(Channel, Payload) ->
    {ok, _Result} = minato:query(?POOL, ~"SELECT pg_notify($1, $2)", [Channel, Payload]),
    ok.

terminated() ->
    Sql =
        ~"""
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE application_name = 'minato_listener_test' AND pid <> pg_backend_pid()
        """,
    {ok, #{rows := Rows}} = minato:query(?POOL, Sql, []),
    ?assertMatch([_Killed | _Rest], Rows),
    ok.

waited() ->
    waited(?TIMEOUT).

waited(Timeout) ->
    receive
        {minato_notification, _Channel, _Payload, _From} = Notification -> Notification
    after Timeout -> timeout
    end.

resubscribed() ->
    receive
        {minato_listener, _Name, resubscribed} = Announced -> Announced
    after ?TIMEOUT -> timeout
    end.

emptied(0) ->
    {error, still_subscribed};
emptied(Attempts) ->
    case minato_listener:channels(?LISTENER) of
        Empty when map_size(Empty) =:= 0 -> ok;
        _Waiting ->
            timer:sleep(20),
            emptied(Attempts - 1)
    end.

connection() ->
    #{
        host => env("MINATO_PG_HOST", "127.0.0.1"),
        port => list_to_integer(env("MINATO_PG_PORT", "55432")),
        user => list_to_binary(env("MINATO_PG_USER", "minato")),
        password => list_to_binary(env("MINATO_PG_PASSWORD", "minato")),
        database => list_to_binary(env("MINATO_PG_DATABASE", "minato_test")),
        parameters => #{~"application_name" => ~"minato_listener_test"},
        timeout => ?TIMEOUT
    }.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
