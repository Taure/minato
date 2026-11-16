-module(minato_overdue).
-moduledoc """
Ends a write that ran out of time, for the one transport that cannot.

A TLS session over the socket transport is written by `m:ssl`, and `ssl:send/2`
takes no deadline: it waits for the peer for as long as the peer cares to stop
reading, with the caller waiting inside it. Nothing the caller holds can end
that, because the caller is the one that is blocked.

So the caller starts a timer before the write and cancels it after, and this
process is where the timer is addressed. It hears only of a write that ran
out, and shuts the socket under the session down in both directions, which is
what makes `m:ssl` give the writer an answer. Shutting down, not closing: a
socket is closed by its owner, which is `m:ssl`, and can be shut down by
anyone holding it.

A write that finishes in time costs its timer and nothing here. There is one of
these for the node, started by `m:minato_sup`.

## Without the application

A connection can be opened with `minato_conn:connect/1` on a node where the
`minato` application was never started, or has been stopped, and then nobody
is registered here for a timer to be addressed to. The deadline holds there as
well: the write is given a process of its own to end it, which lives until the
write comes back or the writer dies. That is a process started per write
where the application would have cost a timer, so start the application.

## The name

`minato_overdue` is this process's registered name and its child id under
`m:minato_sup`, and `minato_sup` is the supervisor's. Neither can be the name
of a pool or a listener: `minato:start_pool/2` and `minato:start_listener/2`
answer `{error, {reserved_name, Name}}`, and `minato:stop_pool/1` answers
`{error, not_found}` rather than stopping what bounds every TLS write.
""".

-behaviour(gen_server).

-export([start_link/0, watch/2, finished/1, ran_out/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-doc "A write being timed, from `watch/2`.".
-opaque watch() :: reference() | {reference(), pid()}.

-export_type([watch/0]).

-doc "Start the process the timers are addressed to.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Give a write on the session over `Socket` this long, starting now.".
-spec watch(minato_socket:socket(), non_neg_integer()) -> watch().
watch(Socket, Timeout) ->
    case whereis(?MODULE) of
        undefined ->
            Writer = self(),
            Alone = spawn(fun() -> alone(erlang:monitor(process, Writer)) end),
            {erlang:send_after(Timeout, Alone, {overdue, Socket}), Alone};
        _Registered ->
            erlang:send_after(Timeout, ?MODULE, {overdue, Socket})
    end.

-doc "The write came back in time.".
-spec finished(watch()) -> ok.
finished({Timer, Alone}) ->
    Alone ! finished,
    finished(Timer);
finished(Timer) ->
    _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
    ok.

-doc "Whether the write that just failed is one that was ended for running out.".
-spec ran_out(watch()) -> boolean().
ran_out({Timer, Alone}) ->
    Alone ! finished,
    ran_out(Timer);
ran_out(Timer) ->
    erlang:cancel_timer(Timer) =:= false.

-spec alone(reference()) -> ok.
alone(Writer) ->
    receive
        {overdue, Socket} -> shut(Socket);
        finished -> ok;
        {'DOWN', Writer, process, _Pid, _Reason} -> ok
    end.

%% Anything can be sent to a registered name, and what is sent here is handed
%% to `socket:shutdown/2`, which raises on what is not a socket.
-spec shut(dynamic()) -> ok.
shut(Socket) ->
    try socket:shutdown(Socket, read_write) of
        _Shut -> ok
    catch
        _Class:_Reason -> ok
    end.

-doc false.
-spec init([]) -> {ok, []}.
init([]) ->
    {ok, []}.

-doc false.
-spec handle_call(term(), gen_server:from(), []) -> {reply, ok, []}.
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

-doc false.
-spec handle_cast(term(), []) -> {noreply, []}.
handle_cast(_Message, State) ->
    {noreply, State}.

-doc false.
-spec handle_info(dynamic(), []) -> {noreply, []}.
handle_info({overdue, Socket}, State) ->
    ok = shut(Socket),
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.
