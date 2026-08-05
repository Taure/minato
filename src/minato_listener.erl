-module(minato_listener).
-moduledoc """
`LISTEN` on a connection of its own, delivered to subscribing processes.

A notification arrives when the server decides, not when a caller asks, so
somebody has to be holding the connection and reading it. That is what this
process is. It owns one connection, keeps it under `minato_conn:activate/1` so
the bytes arrive as messages, and sends what it decodes to whoever subscribed.

```erlang
ok = minato_listener:listen(events, ~"job_ready"),
receive
    {minato_notification, ~"job_ready", Payload, _Pid} -> Payload
end.
```

The connection is this process's and nothing else runs on it. `LISTEN` is
session state: a notification is delivered to the session that registered for
it, so a pooled connection would deliver to whichever caller happened to hold it
next, which is to say nowhere.

## Subscribers

Subscribing is per process, and the process is monitored: a subscriber that dies
is dropped, and a channel nobody is left listening to is `UNLISTEN`ed. Otherwise
a supervisor restarting a worker in a loop leaves the server delivering to a
session where nothing is waiting.

## Notifications get missed

A connection that drops takes its subscriptions with it, and anything the server
published while it was gone is gone: `NOTIFY` is fire and forget, with no
replay. This process reconnects with backoff, `LISTEN`s again for every channel
that still has a subscriber, and then tells each subscriber
`{minato_listener, Name, resubscribed}`.

That message is the point. A consumer that treats notifications as the only way
it learns anything will silently stall; one that is told it was disconnected can
go and look. `NOTIFY` is a hint that something changed, and a poll it makes
faster - never the only path.
""".

-behaviour(gen_server).

-export([start_link/2, listen/2, unlisten/2, channels/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MINIMUM_BACKOFF, 100).
-define(MAXIMUM_BACKOFF, 30000).
-define(CALL_TIMEOUT, 5000).

-record(state, {
    name :: name(),
    opts :: minato_conn:opts(),
    conn :: minato_conn:conn() | undefined,
    channels = #{} :: #{binary() => #{pid() => reference()}},
    backoff = ?MINIMUM_BACKOFF :: pos_integer()
}).

-doc "How the listener is registered and asked for.".
-type name() :: atom().

-doc """
What to connect to.

```erlang
#{connection := minato_conn:opts()}
```

Passed to `minato_conn:connect/1` unchanged. One connection, held for the life
of the listener.
""".
-type opts() :: #{connection := minato_conn:opts()}.

-doc """
What a subscriber receives.

The payload is whatever `NOTIFY` was given, and the pid is the server side
process that sent it, which is how a subscriber tells its own writes from
somebody else's.
""".
-type notification() ::
    {minato_notification, Channel :: binary(), Payload :: binary(), From :: integer()}.

-export_type([name/0, opts/0, notification/0]).

-doc "Start a listener under a supervisor.".
-spec start_link(name(), opts()) -> gen_server:start_ret().
start_link(Name, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

-doc """
Subscribe the calling process to a channel.

Answers `ok` once the server has acknowledged the `LISTEN`, so a caller that
gets `ok` is registered rather than about to be. A channel already listened to
costs no round trip.

The name is quoted rather than interpolated, so a channel name from outside is
a channel name and not a statement.
""".
-spec listen(name(), binary()) -> ok | {error, term()}.
listen(Name, Channel) ->
    call(Name, {listen, Channel, self()}).

-doc """
Stop the calling process's subscription.

The channel is `UNLISTEN`ed when the last subscriber to it goes.
""".
-spec unlisten(name(), binary()) -> ok | {error, term()}.
unlisten(Name, Channel) ->
    call(Name, {unlisten, Channel, self()}).

-doc "Every channel with a subscriber, and how many each has.".
-spec channels(name()) -> #{binary() => non_neg_integer()}.
channels(Name) ->
    call(Name, channels).

-spec call(name(), term()) -> dynamic().
call(Name, Message) ->
    gen_server:call(Name, Message, ?CALL_TIMEOUT).

-doc "Stop the listener and close its connection.".
-spec stop(name()) -> ok.
stop(Name) ->
    gen_server:stop(Name).

%%----------------------------------------------------------------------
%% gen_server
%%----------------------------------------------------------------------

-spec init({name(), opts()}) -> {ok, #state{}}.
init({Name, Opts}) ->
    process_flag(trap_exit, true),
    State = #state{name = Name, opts = maps:get(connection, Opts)},
    {ok, connect(State)}.

-type request() ::
    {listen, binary(), pid()}
    | {unlisten, binary(), pid()}
    | channels.

-spec handle_call(request(), gen_server:from(), #state{}) -> {reply, term(), #state{}}.
handle_call({listen, Channel, Pid}, _From, State) ->
    subscribe(State, Channel, Pid);
handle_call({unlisten, Channel, Pid}, _From, State) ->
    unsubscribe(State, Channel, Pid);
handle_call(channels, _From, #state{channels = Channels} = State) ->
    {reply, maps:map(fun(_Channel, Subscribers) -> map_size(Subscribers) end, Channels), State};
handle_call(Message, _From, State) ->
    {reply, {error, {unknown_call, Message}}, State}.

-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Message, State) ->
    {noreply, State}.

-type info() ::
    reconnect
    | {'DOWN', reference(), process, pid(), term()}
    | {tcp | ssl, term(), binary()}
    | {tcp_closed | ssl_closed, term()}
    | {tcp_error | ssl_error, term(), term()}.

-spec handle_info(info(), #state{}) -> {noreply, #state{}}.
handle_info(reconnect, State) ->
    {noreply, connect(State)};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    {noreply, reactivated(gone(State, Pid))};
handle_info(_Message, #state{conn = undefined} = State) ->
    {noreply, State};
handle_info(Message, #state{conn = Conn} = State) ->
    case minato_conn:handle_message(Conn, Message) of
        {messages, Messages, Read} -> {noreply, delivered(State#state{conn = Read}, Messages)};
        {closed, _Reason} -> {noreply, dropped(State)};
        ignore -> {noreply, State}
    end.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{conn = undefined}) ->
    ok;
terminate(_Reason, #state{conn = Conn}) ->
    minato_conn:close(Conn).

%%----------------------------------------------------------------------
%% Subscribing
%%----------------------------------------------------------------------

-spec subscribe(#state{}, binary(), pid()) -> {reply, ok | {error, term()}, #state{}}.
subscribe(#state{channels = Channels} = State, Channel, Pid) ->
    case maps:get(Channel, Channels, unlistened) of
        unlistened ->
            listened(State, Channel, Pid);
        Subscribers ->
            Watching = State#state{channels = Channels#{Channel => watched(Subscribers, Pid)}},
            {reply, ok, reactivated(Watching)}
    end.

-spec listened(#state{}, binary(), pid()) -> {reply, ok | {error, term()}, #state{}}.
listened(#state{conn = undefined} = State, _Channel, _Pid) ->
    {reply, {error, not_connected}, State};
listened(#state{channels = Channels} = State, Channel, Pid) ->
    case statement(State, <<"LISTEN ", (quoted(Channel))/binary>>) of
        {ok, Listening} ->
            Subscribers = watched(#{}, Pid),
            Watching = Listening#state{channels = Channels#{Channel => Subscribers}},
            {reply, ok, reactivated(Watching)};
        {error, Reason, Failed} ->
            {reply, {error, Reason}, reactivated(Failed)}
    end.

-spec unsubscribe(#state{}, binary(), pid()) -> {reply, ok, #state{}}.
unsubscribe(#state{channels = Channels} = State, Channel, Pid) ->
    case maps:get(Channel, Channels, unlistened) of
        unlistened -> {reply, ok, reactivated(State)};
        Subscribers -> {reply, ok, reactivated(without(State, Channel, Subscribers, Pid))}
    end.

-spec without(#state{}, binary(), #{pid() => reference()}, pid()) -> #state{}.
without(#state{channels = Channels} = State, Channel, Subscribers, Pid) ->
    case maps:get(Pid, Subscribers, unsubscribed) of
        unsubscribed ->
            State#state{channels = Channels};
        Monitor ->
            true = erlang:demonitor(Monitor, [flush]),
            remaining(State, Channel, maps:remove(Pid, Subscribers))
    end.

-spec remaining(#state{}, binary(), #{pid() => reference()}) -> #state{}.
remaining(#state{channels = Channels} = State, Channel, Subscribers) when
    map_size(Subscribers) > 0
->
    State#state{channels = Channels#{Channel => Subscribers}};
remaining(#state{channels = Channels} = State, Channel, _None) ->
    Dropped = State#state{channels = maps:remove(Channel, Channels)},
    case statement(Dropped, <<"UNLISTEN ", (quoted(Channel))/binary>>) of
        {ok, Quiet} -> Quiet;
        {error, _Reason, Failed} -> Failed
    end.

-spec watched(#{pid() => reference()}, pid()) -> #{pid() => reference()}.
watched(Subscribers, Pid) ->
    case maps:is_key(Pid, Subscribers) of
        true -> Subscribers;
        false -> Subscribers#{Pid => erlang:monitor(process, Pid)}
    end.

-spec gone(#state{}, pid()) -> #state{}.
gone(#state{channels = Channels} = State, Pid) ->
    Listening = [Channel || Channel := Subscribers <- Channels, maps:is_key(Pid, Subscribers)],
    dropped_from(State, Listening, Pid).

-spec dropped_from(#state{}, [binary()], pid()) -> #state{}.
dropped_from(State, [], _Pid) ->
    State;
dropped_from(#state{channels = Channels} = State, [Channel | Rest], Pid) ->
    Subscribers = maps:get(Channel, Channels, #{}),
    dropped_from(without(State, Channel, Subscribers, Pid), Rest, Pid).

%%----------------------------------------------------------------------
%% Delivering
%%----------------------------------------------------------------------

-spec delivered(#state{}, [minato_protocol:backend()]) -> #state{}.
delivered(State, []) ->
    reactivated(State);
delivered(State, [{notification_response, From, Channel, Payload} | Rest]) ->
    ok = notify(State, Channel, Payload, From),
    delivered(State, Rest);
delivered(State, [_Message | Rest]) ->
    delivered(State, Rest).

-spec notify(#state{}, binary(), binary(), integer()) -> ok.
notify(#state{channels = Channels}, Channel, Payload, From) ->
    Subscribers = maps:get(Channel, Channels, #{}),
    _ = [Pid ! {minato_notification, Channel, Payload, From} || Pid := _Monitor <- Subscribers],
    ok.

-spec announce(#state{}) -> ok.
announce(#state{name = Name, channels = Channels}) ->
    _ = [
        Pid ! {minato_listener, Name, resubscribed}
     || _Channel := Subscribers <- Channels, Pid := _Monitor <- Subscribers
    ],
    ok.

%%----------------------------------------------------------------------
%% The connection
%%----------------------------------------------------------------------

-spec connect(#state{}) -> #state{}.
connect(#state{opts = Opts} = State) ->
    case minato_conn:connect(Opts) of
        {ok, Conn} -> resubscribe(State#state{conn = Conn, backoff = ?MINIMUM_BACKOFF});
        {error, _Reason} -> retry(State#state{conn = undefined})
    end.

-spec resubscribe(#state{}) -> #state{}.
resubscribe(#state{channels = Channels} = State) ->
    case listening(State, maps:keys(Channels)) of
        {ok, Listening} ->
            ok = announce(Listening),
            reactivated(Listening);
        {error, _Reason, Failed} ->
            retry(disconnected(Failed))
    end.

-spec listening(#state{}, [binary()]) -> {ok, #state{}} | {error, term(), #state{}}.
listening(State, []) ->
    {ok, State};
listening(State, [Channel | Rest]) ->
    case statement(State, <<"LISTEN ", (quoted(Channel))/binary>>) of
        {ok, Listening} -> listening(Listening, Rest);
        {error, Reason, Failed} -> {error, Reason, Failed}
    end.

-spec statement(#state{}, binary()) -> {ok, #state{}} | {error, term(), #state{}}.
statement(#state{conn = undefined} = State, _Sql) ->
    {error, not_connected, State};
statement(#state{conn = Conn} = State, Sql) ->
    case reading(Conn, Sql) of
        {ok, _Results, Ran} -> {ok, State#state{conn = Ran}};
        {error, Reason, Ran} -> {error, Reason, State#state{conn = Ran}};
        {error, Reason} -> {error, Reason, State#state{conn = undefined}}
    end.

-spec reading(minato_conn:conn(), binary()) ->
    {ok, [minato_protocol:result()], minato_conn:conn()}
    | {error, term(), minato_conn:conn()}
    | {error, term()}.
reading(Conn, Sql) ->
    case minato_conn:deactivate(Conn) of
        {ok, Passive} -> minato_query:simple(Passive, Sql);
        {error, Reason} -> {error, Reason}
    end.

-spec reactivated(#state{}) -> #state{}.
reactivated(#state{conn = undefined} = State) ->
    State;
reactivated(#state{conn = Conn} = State) ->
    case minato_conn:activate(Conn) of
        ok -> State;
        {error, _Reason} -> dropped(State)
    end.

-spec dropped(#state{}) -> #state{}.
dropped(State) ->
    retry(disconnected(State)).

-spec disconnected(#state{}) -> #state{}.
disconnected(#state{conn = undefined} = State) ->
    State;
disconnected(#state{conn = Conn} = State) ->
    ok = minato_conn:close(Conn),
    State#state{conn = undefined}.

-spec retry(#state{}) -> #state{}.
retry(#state{backoff = Delay} = State) ->
    _ = erlang:send_after(Delay, self(), reconnect),
    State#state{backoff = longer(Delay)}.

-spec longer(pos_integer()) -> pos_integer().
longer(Delay) when Delay * 2 >= ?MAXIMUM_BACKOFF ->
    ?MAXIMUM_BACKOFF;
longer(Delay) ->
    Delay * 2.

-spec quoted(binary()) -> binary().
quoted(Channel) ->
    Escaped = binary:replace(Channel, ~"\"", ~"\"\"", [global]),
    <<$", Escaped/binary, $">>.
