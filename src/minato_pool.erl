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

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_SIZE, 10).
-define(DEFAULT_MIN_SIZE, 1).
-define(CROWDED_SHARE, 4).
-define(SWEEP_INTERVAL, 5000).
-define(DEFAULT_CHECKOUT_TIMEOUT, 5000).
-define(MINIMUM_BACKOFF, 100).
-define(MAXIMUM_BACKOFF, 30000).

-record(borrowed, {monitor :: reference(), count = 1 :: pos_integer()}).

-record(state, {
    name :: name(),
    opts :: minato_conn:opts(),
    size :: pos_integer(),
    min_size :: non_neg_integer(),
    max_age :: timeout(),
    disconnected :: fail | wait,
    max_idle :: timeout(),
    failures = 0 :: non_neg_integer(),
    measured = false :: boolean(),
    idle = [] :: [{minato_conn:conn(), integer()}],
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

`min_size` is how many connections the pool opens before anybody asks, and it
defaults to one. The rest are opened when a caller finds none free, so a node
with twenty pools does not want a hundred connections the moment it boots, while
a pool that cannot connect at all still says so at start up rather than at the
first query. `0` opens nothing until asked.

`disconnected` decides what a checkout gets when the pool holds no connections
and the last attempt to open one failed. `fail` is the default and answers
`{error, disconnected}` at once, because a caller that cannot be served should
find out in microseconds rather than after the whole checkout timeout - during
an outage the alternative is every caller in the system holding a process for
five seconds to learn the same thing. `wait` queues anyway, for work that would
rather be slow than fail.

`max_idle` closes a connection that has sat unused for that many milliseconds,
down to `min_size`. A pool that grew to meet a busy hour otherwise holds that
hour's connections until the process dies, which is a cost the server pays and
nobody sees. It is one minute by default, and `infinity` keeps whatever the pool
has grown to.

`max_age` retires a connection when it is checked in older than that many
milliseconds, and opens a replacement. It is `infinity` by default, because a
connection to PostgreSQL itself is good indefinitely and churning them would be
work nobody asked for. Set it when something sits in the middle - a proxy, a
load balancer, a NAT - since those have idle and lifetime limits of their own,
and a connection cut by one of them is discovered by a query failing.
""".
-type opts() :: #{
    size => pos_integer(),
    min_size => non_neg_integer(),
    max_age => timeout(),
    max_idle => timeout(),
    disconnected => fail | wait,
    connection := minato_conn:opts()
}.

-doc """
What the pool has been doing since it started.

`disconnects` is connections lost: a connect that failed, a borrower that died,
a connection given back in a state it could not be reset from. `retired` is
connections closed on purpose because they reached `max_age`. The two are
separate because one of them is a problem and the other is the pool working.
""".
-type stats() :: #{
    size := non_neg_integer(),
    idle := non_neg_integer(),
    borrowed := non_neg_integer(),
    waiting := non_neg_integer(),
    checkouts := non_neg_integer(),
    waits := non_neg_integer(),
    timeouts := non_neg_integer(),
    disconnects := non_neg_integer(),
    retired := non_neg_integer()
}.

-export_type([name/0, opts/0, stats/0]).

-define(CHECKOUTS, 1).
-define(WAITS, 2).
-define(TIMEOUTS, 3).
-define(DISCONNECTS, 4).
-define(RETIRED, 5).
-define(COUNTERS, 5).

-type waiter() :: {gen_server:from(), pid(), reference()}.

-type cast() ::
    {checkin, pid(), minato_conn:conn()}
    | {discard, pid(), minato_conn:conn()}
    | {gave_up, pid()}.

-type info() ::
    {connected, minato_conn:conn()}
    | {connect_failed, term()}
    | retry
    | sweep
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
    minato_telemetry:span([minato, checkout], #{pool => Name}, fun() ->
        borrowed(waited(Name, Timeout))
    end).

-spec borrowed({ok, minato_conn:conn()} | {error, term()}) ->
    {{ok, minato_conn:conn()} | {error, term()}, minato_telemetry:metadata()}.
borrowed({ok, Conn}) -> {{ok, Conn}, #{outcome => ok}};
borrowed({error, Reason}) -> {{error, Reason}, #{outcome => error, reason => Reason}}.

-spec waited(name(), timeout()) -> {ok, minato_conn:conn()} | {error, term()}.
waited(Name, Timeout) ->
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
        min_size = min(maps:get(min_size, Opts, ?DEFAULT_MIN_SIZE), Size),
        disconnected = maps:get(disconnected, Opts, fail),
        max_idle = maps:get(max_idle, Opts, 60000),
        max_age = maps:get(max_age, Opts, infinity),
        counters = counters:new(?COUNTERS, [write_concurrency])
    },
    _ = erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {ok, fill(State)}.

-type request() :: checkout | stats | {give_away, pid(), pid()}.

-spec handle_call(request(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.
handle_call(checkout, {Pid, _Tag} = From, State) ->
    case lendable(State) of
        {ok, Conn, Ready} -> lending(Ready, Conn, Pid);
        {none, Ready} -> asked(Ready, From)
    end;
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
    ok = minato_telemetry:event([minato, connection, opened], #{pool => State#state.name}),
    Ready = State#state{
        connecting = fewer(Connecting), backoff = ?MINIMUM_BACKOFF, failures = 0
    },
    {noreply, hand_out(measured(Ready, Conn), Conn)};
handle_info({connect_failed, Reason}, #state{connecting = Connecting} = State0) ->
    State = State0#state{failures = State0#state.failures + 1},
    ok = counters:add(State#state.counters, ?DISCONNECTS, 1),
    Delay = State#state.backoff,
    ?LOG_WARNING(
        #{
            event => connect_failed,
            pool => State#state.name,
            reason => Reason,
            retry_in_ms => Delay
        },
        #{domain => [minato]}
    ),
    _ = erlang:send_after(Delay, self(), retry),
    {noreply, State#state{connecting = fewer(Connecting), backoff = longer(Delay)}};
handle_info(retry, State) ->
    {noreply, fill(State)};
handle_info(sweep, State) ->
    _ = erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {noreply, swept(State)};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    {noreply, lost(State, Pid)};
handle_info(_Message, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{idle = Idle}) ->
    _ = [minato_conn:close(Conn) || {Conn, _Since} <- Idle],
    ok.

%%----------------------------------------------------------------------
%% Lending
%%----------------------------------------------------------------------

-doc """
The first idle connection a caller can actually use, dropping any that died.

A connection can die while it sits in the pool and nothing announces it, so
handing one over without asking turns a server restart into one failed
statement per pooled connection, for callers that did nothing wrong.
""".
-spec lendable(#state{}) -> {ok, minato_conn:conn(), #state{}} | {none, #state{}}.
lendable(#state{idle = []} = State) ->
    {none, State};
lendable(#state{idle = [{Conn, _Since} | Rest]} = State) ->
    Ready = State#state{idle = Rest},
    case minato_conn:usable(Conn) of
        true -> {ok, Conn, Ready};
        false -> lendable(discarded(Ready, Conn))
    end.

-spec lending(#state{}, minato_conn:conn(), pid()) -> {reply, term(), #state{}}.
lending(State, Conn, Pid) ->
    case minato_conn:give_away(Conn, Pid) of
        ok ->
            ok = counters:add(State#state.counters, ?CHECKOUTS, 1),
            {reply, {ok, Conn}, borrow(State, Pid)};
        {error, Reason} ->
            {reply, {error, Reason}, discarded(State, Conn)}
    end.

-doc """
Check the connection budget once, on the first connection this pool opens.

`size` connections per pool, times the pools on this node, times the nodes, is
the number PostgreSQL compares with `max_connections`, and it is the number
nobody works out until the server starts refusing. The pool asks the server what
its limit is while it holds a connection nobody is using yet, and says something
if one pool alone wants a quarter of it.

Once, not per connection: the answer does not change, and a warning that repeats
is a warning people filter.
""".
-spec measured(#state{}, minato_conn:conn()) -> #state{}.
measured(#state{measured = true} = State, _Conn) ->
    State;
measured(#state{size = Size, name = Name} = State, Conn) ->
    case minato_query:simple(Conn, ~"SHOW max_connections") of
        {ok, [#{rows := [{Limit}]}], _Read} -> crowded(Name, Size, Limit);
        _Unknown -> ok
    end,
    State#state{measured = true}.

-spec crowded(name(), pos_integer(), term()) -> ok.
crowded(Name, Size, Limit) when is_binary(Limit) ->
    crowded(Name, Size, binary_to_integer(Limit));
crowded(Name, Size, Limit) when is_integer(Limit), Size * ?CROWDED_SHARE > Limit ->
    _ = ?LOG_WARNING(
        #{
            event => connection_budget,
            pool => Name,
            size => Size,
            server_max_connections => Limit,
            note => one_pool_wants_a_large_share_of_the_server
        },
        #{domain => [minato]}
    ),
    ok;
crowded(_Name, _Size, _Limit) ->
    ok.

-spec asked(#state{}, gen_server:from()) ->
    {reply, {error, disconnected}, #state{}} | {noreply, #state{}}.
asked(State, {Pid, _Tag} = From) ->
    case unreachable(State) of
        true ->
            {reply, {error, disconnected}, State};
        false ->
            ok = counters:add(State#state.counters, ?WAITS, 1),
            Waiting = queue:in({From, Pid, erlang:monitor(process, Pid)}, State#state.waiting),
            {noreply, grown(State#state{waiting = Waiting})}
    end.

-spec unreachable(#state{}) -> boolean().
unreachable(#state{disconnected = wait}) ->
    false;
unreachable(#state{failures = Failures, idle = Idle, borrowed = Borrowed}) ->
    Failures > 0 andalso Idle =:= [] andalso holders(Borrowed) =:= 0.

-spec grown(#state{}) -> #state{}.
grown(#state{size = Size, connecting = Connecting} = State) ->
    case held(State) < Size andalso Connecting =:= 0 of
        true ->
            ok = connect(State#state.opts),
            State#state{connecting = Connecting + 1};
        false ->
            State
    end.

-spec held(#state{}) -> non_neg_integer().
held(#state{idle = Idle, borrowed = Borrowed, connecting = Connecting}) ->
    length(Idle) + holders(Borrowed) + Connecting.

-spec handed_over(#state{}, pid(), pid()) -> {reply, ok | {error, term()}, #state{}}.
handed_over(#state{borrowed = Borrowed} = State, From, To) ->
    case maps:is_key(From, Borrowed) of
        false -> {reply, {error, not_borrowed}, State};
        true -> {reply, ok, borrow(released(State, From), To)}
    end.

-doc """
Note that `Pid` is holding one more connection.

Counted rather than recorded, because one process may hold several: a worker
with two repos does, and so does anything that checks a connection out on behalf
of somebody else. A map keyed by pid alone would have lost the second
connection at the second checkin, which is a connection leaked per checkout
pair.
""".
-spec borrow(#state{}, pid()) -> #state{}.
borrow(#state{borrowed = Borrowed} = State, Pid) ->
    case maps:find(Pid, Borrowed) of
        {ok, #borrowed{count = Count} = Held} ->
            State#state{borrowed = Borrowed#{Pid => Held#borrowed{count = Count + 1}}};
        error ->
            Monitor = erlang:monitor(process, Pid),
            State#state{borrowed = Borrowed#{Pid => #borrowed{monitor = Monitor}}}
    end.

-spec released(#state{}, pid()) -> #state{}.
released(#state{borrowed = Borrowed} = State, Pid) ->
    case maps:find(Pid, Borrowed) of
        {ok, #borrowed{count = Count} = Held} when Count > 1 ->
            State#state{borrowed = Borrowed#{Pid => Held#borrowed{count = Count - 1}}};
        {ok, #borrowed{monitor = Monitor}} ->
            true = erlang:demonitor(Monitor, [flush]),
            State#state{borrowed = maps:remove(Pid, Borrowed)};
        error ->
            State
    end.

-spec hand_out(#state{}, minato_conn:conn()) -> #state{}.
hand_out(#state{waiting = Waiting} = State, Conn) ->
    case queue:out(Waiting) of
        {{value, {From, Pid, Monitor}}, Rest} ->
            true = erlang:demonitor(Monitor, [flush]),
            {reply, Answer, Lent} = lending(State#state{waiting = Rest}, Conn, Pid),
            gen_server:reply(From, Answer),
            Lent;
        {empty, _Rest} ->
            State#state{idle = [{Conn, erlang:monotonic_time(millisecond)} | State#state.idle]}
    end.

-spec returned(#state{}, pid(), minato_conn:conn()) -> #state{}.
returned(#state{borrowed = Borrowed} = State, Pid, Conn) ->
    case maps:is_key(Pid, Borrowed) of
        true -> reset(released(State, Pid), Conn);
        false -> discarded(State, Conn)
    end.

-spec dropped(#state{}, pid(), minato_conn:conn()) -> #state{}.
dropped(#state{borrowed = Borrowed} = State, Pid, Conn) ->
    case maps:is_key(Pid, Borrowed) of
        true -> discarded(released(State, Pid), Conn);
        false -> discarded(State, Conn)
    end.

-spec reset(#state{}, minato_conn:conn()) -> #state{}.
reset(State, Conn) ->
    case minato_conn:transaction_status(Conn) of
        idle -> aged(State, Conn);
        _Open -> rolled_back(State, minato_txn:rollback(Conn))
    end.

-spec aged(#state{}, minato_conn:conn()) -> #state{}.
aged(#state{max_age = infinity} = State, Conn) ->
    hand_out(State, Conn);
aged(#state{max_age = MaxAge} = State, Conn) ->
    case minato_conn:age(Conn) >= MaxAge of
        true -> retired(State, Conn);
        false -> hand_out(State, Conn)
    end.

-spec retired(#state{}, minato_conn:conn()) -> #state{}.
retired(State, Conn) ->
    ok = minato_conn:close(Conn),
    ok = counters:add(State#state.counters, ?RETIRED, 1),
    ok = minato_telemetry:event(
        [minato, connection, closed], #{pool => State#state.name, reason => max_age}
    ),
    fill(State).

-spec rolled_back(
    #state{},
    {ok, minato_conn:conn()}
    | {error, minato_txn:error(), minato_conn:conn()}
    | {error, minato_txn:error()}
) -> #state{}.
rolled_back(State, {ok, Conn}) ->
    aged(State, Conn);
rolled_back(State, {error, _Reason, Conn}) ->
    discarded(State, Conn);
rolled_back(State, {error, _Reason}) ->
    fill(State).

-spec discarded(#state{}, minato_conn:conn()) -> #state{}.
discarded(State, Conn) ->
    ok = minato_conn:close(Conn),
    ok = counters:add(State#state.counters, ?DISCONNECTS, 1),
    ok = minato_telemetry:event(
        [minato, connection, closed], #{pool => State#state.name, reason => discarded}
    ),
    fill(State).

-spec lost(#state{}, pid()) -> #state{}.
lost(#state{borrowed = Borrowed} = State, Pid) ->
    case maps:find(Pid, Borrowed) of
        {ok, #borrowed{count = Count}} ->
            ok = counters:add(State#state.counters, ?DISCONNECTS, Count),
            ok = minato_telemetry:event(
                [minato, connection, closed],
                #{
                    pool => State#state.name,
                    reason => borrower_died,
                    borrower => Pid,
                    connections => Count
                }
            ),
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

-doc false.
-spec fill(#state{}) -> #state{}.
fill(#state{min_size = Floor, connecting = Connecting} = State) ->
    case Floor - held(State) of
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

-doc """
Close connections nobody has wanted for `max_idle`, down to `min_size`.

A pool that grew for a busy hour holds that hour's connections until the process
dies otherwise. The floor is kept because a pool with nothing open pays a
connect on the next query, and the point of the floor is that somebody has
already paid it.
""".
-spec swept(#state{}) -> #state{}.
swept(#state{max_idle = infinity} = State) ->
    State;
swept(#state{idle = Idle, min_size = Floor} = State) when length(Idle) =< Floor ->
    State;
swept(#state{idle = Idle, min_size = Floor, max_idle = MaxIdle} = State) ->
    Now = erlang:monotonic_time(millisecond),
    {Keep, Stale} = idle_split(oldest_first(Idle, []), Now - MaxIdle, Floor, [], []),
    _ = [closed(State, Conn) || Conn <- Stale],
    State#state{idle = Keep}.

-spec oldest_first([{minato_conn:conn(), integer()}], [{minato_conn:conn(), integer()}]) ->
    [{minato_conn:conn(), integer()}].
oldest_first([], Reversed) ->
    Reversed;
oldest_first([Held | Rest], Reversed) ->
    oldest_first(Rest, [Held | Reversed]).

-spec idle_split(
    [{minato_conn:conn(), integer()}],
    integer(),
    non_neg_integer(),
    [{minato_conn:conn(), integer()}],
    [minato_conn:conn()]
) -> {[{minato_conn:conn(), integer()}], [minato_conn:conn()]}.
idle_split([], _Cutoff, _Floor, Keep, Stale) ->
    {Keep, Stale};
idle_split([{Conn, Since} | Rest], Cutoff, Floor, Keep, Stale) when
    Since < Cutoff, length(Rest) + length(Keep) >= Floor
->
    idle_split(Rest, Cutoff, Floor, Keep, [Conn | Stale]);
idle_split([Held | Rest], Cutoff, Floor, Keep, Stale) ->
    idle_split(Rest, Cutoff, Floor, [Held | Keep], Stale).

-spec closed(#state{}, minato_conn:conn()) -> ok.
closed(#state{name = Name}, Conn) ->
    ok = minato_conn:close(Conn),
    minato_telemetry:event(
        [minato, connection, closed], #{pool => Name, reason => idle}
    ).

-spec holders(#{pid() => #borrowed{}}) -> non_neg_integer().
holders(Borrowed) ->
    lists:sum([Count || _Pid := #borrowed{count = Count} <- Borrowed]).

-spec reported(#state{}) -> stats().
reported(#state{} = State) ->
    #state{idle = Idle, borrowed = Borrowed, waiting = Waiting, counters = Counters} = State,
    #{
        size => State#state.size,
        idle => length(Idle),
        borrowed => holders(Borrowed),
        waiting => queue:len(Waiting),
        checkouts => counters:get(Counters, ?CHECKOUTS),
        waits => counters:get(Counters, ?WAITS),
        timeouts => counters:get(Counters, ?TIMEOUTS),
        disconnects => counters:get(Counters, ?DISCONNECTS),
        retired => counters:get(Counters, ?RETIRED)
    }.
