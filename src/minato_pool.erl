-module(minato_pool).
-moduledoc """
A pool of connections, handed out one caller at a time.

The pool holds connections and lends them; it does not run queries. That follows
from the caller owning the socket: a pool that ran the query would be back to
one process serialising every caller, which is the arrangement the whole client
is written to avoid. `checkout/2` hands over the socket as well as the
connection term, `checkin/2` hands it back, and `m:minato` wraps both so that
the ordinary case is one call.

## Waiting

A checkout with no connection free waits in a FIFO queue until one is checked in
or the timeout runs out. First in, first served, and a caller that gives up is
taken out of the queue rather than handed a connection nobody is waiting for.

The queue is deliberately plain. A CoDel queue, which drops from the head when
the *minimum* delay over a window stays above target, is the thing to build here
when there is a load to measure it against; a bounded FIFO with a timeout is
what that will replace, and it is honest in the meantime.

## Connections come and go

Connecting happens in the background and is retried with exponential backoff, so
a pool started before its database is a pool that fills up when the database
arrives rather than a supervisor that gives up. `checkout/2` waits for that
exactly as it waits for a busy connection.

A borrower that dies takes the socket with it, because the socket belongs to the
process that holds it: the pool notices through its monitor and starts a
replacement.

## What a connection is like when it comes back

Checked in with a transaction open, it is rolled back before it is lent again.
A caller that returns a connection mid-transaction has already made a mistake,
and the alternative is the next borrower silently joining a transaction it did
not open. A connection that cannot be rolled back is closed and replaced,
because there is nothing else to be sure of about it.
""".

-behaviour(gen_server).

-export([
    start_link/2,
    checkout/1,
    checkout/2,
    checkin/2,
    give_away/3,
    discard/2,
    stop/1,
    stats/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_SIZE, 10).
-define(DEFAULT_CHECKOUT_TIMEOUT, 5000).
-define(MINIMUM_BACKOFF, 100).
-define(MAXIMUM_BACKOFF, 30000).

-record(borrowed, {monitor :: reference()}).

-record(state, {
    name :: name(),
    opts :: minato_conn:opts(),
    size :: pos_integer(),
    idle = [] :: [minato_conn:conn()],
    borrowed = #{} :: #{pid() => #borrowed{}},
    waiting = queue:new() :: queue:queue(waiter()),
    connecting = 0 :: non_neg_integer(),
    backoff = ?MINIMUM_BACKOFF :: pos_integer(),
    counters :: counters:counters_ref()
}).

-doc "How the pool is registered and asked for.".
-type name() :: atom().

-doc """
What to open, and how many.

```erlang
#{size => pos_integer(),
  connection => minato_conn:opts()}
```

`connection` is passed to `minato_conn:connect/1` unchanged. `size` is how many
connections the pool keeps. How long to wait for a free one is the caller's to
say, in `checkout/2`.
""".
-type opts() :: #{
    size => pos_integer(),
    connection := minato_conn:opts()
}.

-doc "What the pool has been doing since it started.".
-type stats() :: #{
    size := non_neg_integer(),
    idle := non_neg_integer(),
    borrowed := non_neg_integer(),
    waiting := non_neg_integer(),
    checkouts := non_neg_integer(),
    waits := non_neg_integer(),
    timeouts := non_neg_integer(),
    disconnects := non_neg_integer()
}.

-export_type([name/0, opts/0, stats/0]).

-define(CHECKOUTS, 1).
-define(WAITS, 2).
-define(TIMEOUTS, 3).
-define(DISCONNECTS, 4).
-define(COUNTERS, 4).

-type waiter() :: {gen_server:from(), pid(), reference()}.

-type cast() ::
    {checkin, pid(), minato_conn:conn()}
    | {discard, pid(), minato_conn:conn()}
    | {gave_up, pid()}.

-type info() ::
    {connected, minato_conn:conn()}
    | {connect_failed, term()}
    | retry
    | {'DOWN', reference(), process, pid(), term()}.

-doc "Start a pool under a supervisor.".
-spec start_link(name(), opts()) -> gen_server:start_ret().
start_link(Name, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

-doc "`checkout/2` with the default timeout of five seconds.".
-spec checkout(name()) -> {ok, minato_conn:conn()} | {error, term()}.
checkout(Name) ->
    checkout(Name, ?DEFAULT_CHECKOUT_TIMEOUT).

-doc """
Borrow a connection, waiting for one if they are all out.

The socket is handed over with it, so the calling process can read and write it.
Give it back with `checkin/2`; a caller that dies instead is noticed, and the
connection is replaced rather than leaked.
""".
-spec checkout(name(), timeout()) -> {ok, minato_conn:conn()} | {error, term()}.
checkout(Name, Timeout) ->
    try call(Name, checkout, Timeout) of
        {ok, Conn} -> {ok, Conn};
        {error, Reason} -> {error, Reason}
    catch
        exit:{timeout, _Call} ->
            ok = gen_server:cast(Name, {gave_up, self()}),
            {error, checkout_timeout};
        exit:{noproc, _Call} ->
            {error, {no_pool, Name}}
    end.

-doc """
Give a connection back.

The socket goes back to the pool first, because the pool cannot read a socket it
does not own. A connection with a transaction open is rolled back before it is
lent again, and one that cannot be is closed and replaced.
""".
-spec checkin(name(), minato_conn:conn()) -> ok.
checkin(Name, Conn) ->
    case whereis(Name) of
        Pid when is_pid(Pid) ->
            _ = minato_conn:give_away(Conn, Pid),
            gen_server:cast(Name, {checkin, self(), Conn});
        _Gone ->
            minato_conn:close(Conn)
    end.

-doc """
Hand a borrowed connection to another process, which then owes it back.

Two things move and both have to: the socket, which belongs to whoever holds it,
and the pool's idea of who to watch. The pool stops watching the caller and
starts watching the new owner, so the connection is replaced if that process
dies rather than the one that borrowed it.

The connection term itself is the caller's to send on. Sending it without
calling this leaves the receiver holding a term whose socket belongs to somebody
else, and the pool waiting on a process that has moved on.

For a worker that borrows a connection and hands it to the process that will use
it, and for `LISTEN` on a connection taken out of the pool.
""".
-spec give_away(name(), minato_conn:conn(), pid()) -> ok | {error, term()}.
give_away(Name, Conn, Pid) ->
    case call(Name, {give_away, self(), Pid}, ?DEFAULT_CHECKOUT_TIMEOUT) of
        ok -> minato_conn:give_away(Conn, Pid);
        {error, Reason} -> {error, Reason}
    end.

-doc """
Give a connection back to be closed rather than lent again.

For a borrower that knows the connection is no longer trustworthy: a read that
timed out, an exception part way through a result set, anything that leaves the
stream at an offset nobody knows. The pool closes it and opens another.
""".
-spec discard(name(), minato_conn:conn()) -> ok.
discard(Name, Conn) ->
    case whereis(Name) of
        Pid when is_pid(Pid) ->
            _ = minato_conn:give_away(Conn, Pid),
            gen_server:cast(Name, {discard, self(), Conn});
        _Gone ->
            minato_conn:close(Conn)
    end.

-doc "Stop the pool and close every connection it holds.".
-spec stop(name()) -> ok.
stop(Name) ->
    gen_server:stop(Name).

-doc "What the pool holds and what it has done.".
-spec stats(name()) -> stats().
stats(Name) ->
    call(Name, stats, ?DEFAULT_CHECKOUT_TIMEOUT).

-spec call(name(), term(), timeout()) -> dynamic().
call(Name, Message, Timeout) ->
    gen_server:call(Name, Message, Timeout).

%%----------------------------------------------------------------------
%% gen_server
%%----------------------------------------------------------------------

-spec init({name(), opts()}) -> {ok, #state{}}.
init({Name, Opts}) ->
    process_flag(trap_exit, true),
    Size = maps:get(size, Opts, ?DEFAULT_SIZE),
    State = #state{
        name = Name,
        opts = maps:get(connection, Opts),
        size = Size,
        counters = counters:new(?COUNTERS, [write_concurrency])
    },
    {ok, fill(State)}.

-type request() :: checkout | stats | {give_away, pid(), pid()}.

-spec handle_call(request(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.
handle_call(checkout, {Pid, _Tag}, #state{idle = [Conn | Rest]} = State) ->
    lending(State#state{idle = Rest}, Conn, Pid);
handle_call(checkout, {Pid, _Tag} = From, State) ->
    ok = counters:add(State#state.counters, ?WAITS, 1),
    Waiting = queue:in({From, Pid, erlang:monitor(process, Pid)}, State#state.waiting),
    {noreply, State#state{waiting = Waiting}};
handle_call({give_away, From, To}, _From, State) ->
    handed_over(State, From, To);
handle_call(stats, _From, State) ->
    {reply, reported(State), State};
handle_call(Message, _From, State) ->
    {reply, {error, {unknown_call, Message}}, State}.

-spec handle_cast(cast(), #state{}) -> {noreply, #state{}}.
handle_cast({checkin, Pid, Conn}, State) ->
    {noreply, returned(State, Pid, Conn)};
handle_cast({discard, Pid, Conn}, State) ->
    {noreply, dropped(State, Pid, Conn)};
handle_cast({gave_up, Pid}, State) ->
    ok = counters:add(State#state.counters, ?TIMEOUTS, 1),
    {noreply, State#state{waiting = without(State#state.waiting, Pid)}};
handle_cast(_Message, State) ->
    {noreply, State}.

-spec handle_info(info(), #state{}) -> {noreply, #state{}}.
handle_info({connected, Conn}, #state{connecting = Connecting} = State) ->
    Ready = State#state{connecting = fewer(Connecting), backoff = ?MINIMUM_BACKOFF},
    {noreply, hand_out(Ready, Conn)};
handle_info({connect_failed, _Reason}, #state{connecting = Connecting} = State) ->
    ok = counters:add(State#state.counters, ?DISCONNECTS, 1),
    Delay = State#state.backoff,
    _ = erlang:send_after(Delay, self(), retry),
    {noreply, State#state{connecting = fewer(Connecting), backoff = longer(Delay)}};
handle_info(retry, State) ->
    {noreply, fill(State)};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    {noreply, lost(State, Pid)};
handle_info(_Message, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{idle = Idle}) ->
    _ = [minato_conn:close(Conn) || Conn <- Idle],
    ok.

%%----------------------------------------------------------------------
%% Lending
%%----------------------------------------------------------------------

-spec lending(#state{}, minato_conn:conn(), pid()) -> {reply, term(), #state{}}.
lending(State, Conn, Pid) ->
    case minato_conn:give_away(Conn, Pid) of
        ok ->
            ok = counters:add(State#state.counters, ?CHECKOUTS, 1),
            {reply, {ok, Conn}, borrow(State, Pid)};
        {error, Reason} ->
            {reply, {error, Reason}, discarded(State, Conn)}
    end.

-spec handed_over(#state{}, pid(), pid()) -> {reply, ok | {error, term()}, #state{}}.
handed_over(#state{borrowed = Borrowed} = State, From, To) ->
    case maps:get(From, Borrowed, undefined) of
        undefined ->
            {reply, {error, not_borrowed}, State};
        #borrowed{monitor = Monitor} ->
            true = erlang:demonitor(Monitor, [flush]),
            Moved = State#state{borrowed = maps:remove(From, Borrowed)},
            {reply, ok, borrow(Moved, To)}
    end.

-spec borrow(#state{}, pid()) -> #state{}.
borrow(#state{borrowed = Borrowed} = State, Pid) ->
    Monitor = erlang:monitor(process, Pid),
    State#state{borrowed = Borrowed#{Pid => #borrowed{monitor = Monitor}}}.

-spec hand_out(#state{}, minato_conn:conn()) -> #state{}.
hand_out(#state{waiting = Waiting} = State, Conn) ->
    case queue:out(Waiting) of
        {{value, {From, Pid, Monitor}}, Rest} ->
            true = erlang:demonitor(Monitor, [flush]),
            {reply, Answer, Lent} = lending(State#state{waiting = Rest}, Conn, Pid),
            gen_server:reply(From, Answer),
            Lent;
        {empty, _Rest} ->
            State#state{idle = [Conn | State#state.idle]}
    end.

-spec returned(#state{}, pid(), minato_conn:conn()) -> #state{}.
returned(#state{borrowed = Borrowed} = State, Pid, Conn) ->
    case maps:find(Pid, Borrowed) of
        {ok, #borrowed{monitor = Monitor}} ->
            true = erlang:demonitor(Monitor, [flush]),
            reset(State#state{borrowed = maps:remove(Pid, Borrowed)}, Conn);
        error ->
            ok = minato_conn:close(Conn),
            State
    end.

-spec dropped(#state{}, pid(), minato_conn:conn()) -> #state{}.
dropped(#state{borrowed = Borrowed} = State, Pid, Conn) ->
    case maps:find(Pid, Borrowed) of
        {ok, #borrowed{monitor = Monitor}} ->
            true = erlang:demonitor(Monitor, [flush]),
            discarded(State#state{borrowed = maps:remove(Pid, Borrowed)}, Conn);
        error ->
            ok = minato_conn:close(Conn),
            State
    end.

-spec reset(#state{}, minato_conn:conn()) -> #state{}.
reset(State, Conn) ->
    case minato_conn:transaction_status(Conn) of
        idle -> hand_out(State, Conn);
        _Open -> rolled_back(State, minato_txn:rollback(Conn))
    end.

-spec rolled_back(
    #state{},
    {ok, minato_conn:conn()}
    | {error, minato_txn:error(), minato_conn:conn()}
    | {error, minato_txn:error()}
) -> #state{}.
rolled_back(State, {ok, Conn}) ->
    hand_out(State, Conn);
rolled_back(State, {error, _Reason, Conn}) ->
    discarded(State, Conn);
rolled_back(State, {error, _Reason}) ->
    fill(State).

-spec discarded(#state{}, minato_conn:conn()) -> #state{}.
discarded(State, Conn) ->
    ok = minato_conn:close(Conn),
    ok = counters:add(State#state.counters, ?DISCONNECTS, 1),
    fill(State).

-spec lost(#state{}, pid()) -> #state{}.
lost(#state{borrowed = Borrowed} = State, Pid) ->
    case maps:find(Pid, Borrowed) of
        {ok, #borrowed{}} ->
            ok = counters:add(State#state.counters, ?DISCONNECTS, 1),
            fill(State#state{borrowed = maps:remove(Pid, Borrowed)});
        error ->
            State#state{waiting = without(State#state.waiting, Pid)}
    end.

-spec without(queue:queue(waiter()), pid()) -> queue:queue(waiter()).
without(Waiting, Pid) ->
    queue:filter(fun({_From, Waiter, _Monitor}) -> Waiter =/= Pid end, Waiting).

%%----------------------------------------------------------------------
%% Filling up
%%----------------------------------------------------------------------

-spec fill(#state{}) -> #state{}.
fill(#state{size = Size, idle = Idle, borrowed = Borrowed, connecting = Connecting} = State) ->
    Held = length(Idle) + map_size(Borrowed) + Connecting,
    case Size - Held of
        Missing when Missing > 0 ->
            lists:foreach(fun(_) -> connect(State#state.opts) end, lists:seq(1, Missing)),
            State#state{connecting = Connecting + Missing};
        _Enough ->
            State
    end.

-spec connect(minato_conn:opts()) -> ok.
connect(Opts) ->
    Pool = self(),
    _ = spawn(fun() -> connected(Pool, Opts) end),
    ok.

-spec connected(pid(), minato_conn:opts()) -> ok.
connected(Pool, Opts) ->
    case minato_conn:connect(Opts) of
        {ok, Conn} -> handed(Pool, Conn);
        {error, Reason} -> refused(Pool, Reason)
    end.

-spec handed(pid(), minato_conn:conn()) -> ok.
handed(Pool, Conn) ->
    case minato_conn:give_away(Conn, Pool) of
        ok ->
            Pool ! {connected, Conn},
            ok;
        {error, Reason} ->
            ok = minato_conn:close(Conn),
            refused(Pool, Reason)
    end.

-spec refused(pid(), term()) -> ok.
refused(Pool, Reason) ->
    Pool ! {connect_failed, Reason},
    ok.

-spec longer(pos_integer()) -> pos_integer().
longer(Delay) when Delay * 2 >= ?MAXIMUM_BACKOFF ->
    ?MAXIMUM_BACKOFF;
longer(Delay) ->
    Delay * 2.

-spec fewer(non_neg_integer()) -> non_neg_integer().
fewer(0) ->
    0;
fewer(Connecting) ->
    Connecting - 1.

-spec reported(#state{}) -> stats().
reported(#state{} = State) ->
    #state{idle = Idle, borrowed = Borrowed, waiting = Waiting, counters = Counters} = State,
    #{
        size => State#state.size,
        idle => length(Idle),
        borrowed => map_size(Borrowed),
        waiting => queue:len(Waiting),
        checkouts => counters:get(Counters, ?CHECKOUTS),
        waits => counters:get(Counters, ?WAITS),
        timeouts => counters:get(Counters, ?TIMEOUTS),
        disconnects => counters:get(Counters, ?DISCONNECTS)
    }.
