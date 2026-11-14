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
these for the node, started by `m:minato_sup`; with the `minato` application
stopped the timer is addressed to nobody and a TLS write is unbounded again.
""".

-behaviour(gen_server).

-export([start_link/0, watch/2, finished/1, ran_out/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-doc "Start the process the timers are addressed to.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Give a write on the session over `Socket` this long, starting now.".
-spec watch(minato_socket:socket(), non_neg_integer()) -> reference().
watch(Socket, Timeout) ->
    erlang:send_after(Timeout, ?MODULE, {overdue, Socket}).

-doc "The write came back in time.".
-spec finished(reference()) -> ok.
finished(Timer) ->
    erlang:cancel_timer(Timer, [{async, true}, {info, false}]).

-doc "Whether the write that just failed is one this process ended.".
-spec ran_out(reference()) -> boolean().
ran_out(Timer) ->
    erlang:cancel_timer(Timer) =:= false.

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
    _ = socket:shutdown(Socket, read_write),
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.
