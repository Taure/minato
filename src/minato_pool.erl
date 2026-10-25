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
not open. The pool sends `ROLLBACK` ahead of the reset below rather than waiting
on it, and a connection it does not succeed on is closed and replaced by the
borrower that reads the answer.

The rest of the session is reset as well: settings made with `SET` or
`set_config/3`, the session user and role, advisory locks, `LISTEN`s, temporary
tables, cursors opened `WITH HOLD` and sequence state. Each of those outlives a
transaction, and a borrower would otherwise run with a role, a `search_path`, a
lock or a tenant setting left behind by somebody else. Statements minato has
prepared are kept, since they are the connection's own cache. A connection with
a statement prepared with SQL `PREPARE` is closed instead, because such a
statement can take the name of one minato has cached and run in its place for
every later borrower.

Some session state is not reset: the seed set with `setseed/1`, and whatever an
extension keeps per session, such as `dblink` connections, the `postgres_fdw`
connection cache and libraries loaded with `LOAD`. `RESET ALL` returns each
setting to its value when the connection opened, which includes defaults set on
the role or database with `ALTER ROLE ... SET`. A setting the application relies
on for security, such as `search_path`, therefore belongs in the connection's
`parameters`, where a role able to alter itself cannot change it.

The reset is sent when the connection comes back and its answer is read by the
next borrower, as the first thing `checkout/2` does. The pool therefore never
waits on a socket for it, and a connection that sat idle for longer than a round
trip costs the borrower nothing extra. Only the reset's own answer is accepted:
its command tags in order, ending with a value chosen afresh each time the
connection comes back, then an idle `ReadyForQuery`. A connection on which
something else answers first, because the last borrower gave it back with
answers it never read, is closed, and so is one the server refuses the reset on
and one whose answer does not come back because the server ended it while it
sat in the pool. The checkout then tries the next connection, up to the pool's
size and once more, before it returns `{error, {session_reset, Why}}`. A server
error in `Why` carries only its SQLSTATE `code`, since the rest of it may quote
what the last borrower ran.

A connection driven with `minato_conn:send/2` and `minato_conn:next/2` therefore
costs a reconnect if it is checked in with answers unread. Discard it instead.

The reset is a defence against SQL a borrower ran, not against Erlang code that
holds the connection. Such code can, for one, parse a statement with
`minato_query:prepare/3` under the name of one minato cached after a SQL
`DEALLOCATE`, and the reset cannot tell that statement from minato's own.
Extended-protocol messages written with `minato_conn:send/2` and not yet
followed by `Sync` are sent ahead of the reset, so the reset's own `Sync` can
commit them. Discard a connection given back like that.

The pool writes the reset itself, and `minato_conn:close/1` writes `Terminate`.
Both wait as long as the connection's `send_timeout` allows, which is forever by
default, so set it when a server may stop reading.
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
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_SIZE, 10).
-define(DEFAULT_MIN_SIZE, 1).
-define(DEFAULT_MAX_IDLE, 60000).
-define(DEFAULT_MAX_AGE, infinity).
-define(DEFAULT_DISCONNECTED, fail).
-define(IS_TIMEOUT(T), (T =:= infinity orelse (is_integer(T) andalso T >= 0))).
-define(CROWDED_SHARE, 4).
-define(SWEEP_INTERVAL, 5000).
-define(DEFAULT_CHECKOUT_TIMEOUT, 5000).
-define(MINIMUM_BACKOFF, 100).
-define(MAXIMUM_BACKOFF, 30000).
-define(RESET,
    ~"CLOSE ALL; SET SESSION AUTHORIZATION DEFAULT; RESET ALL; UNLISTEN *; SELECT pg_catalog.pg_advisory_unlock_all(); DISCARD TEMP; DISCARD SEQUENCES; SELECT '"
).
-define(RESET_END,
    ~"' WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_prepared_statements WHERE from_sql)"
).
-define(ROLLBACK, ~"ROLLBACK; ").
-define(RESET_TAGS, [
    {close, cursor_all},
    {set, undefined},
    {reset, undefined},
    {unlisten, undefined},
    {select, 1},
    {discard, temp},
    {discard, sequences}
]).
-define(RESET_RETRIES, 1).
-define(LATE_ANSWER_TIMEOUT, 100).

-record(borrowed, {
    monitor :: reference(),
    count = 1 :: pos_integer(),
    last :: {minato_conn:conn(), [expected()]} | undefined
}).

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
    idle = [] :: [idle()],
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

A `size` that is not a positive integer, or a `min_size` that is not a
non-negative integer, stops the pool before it connects, and `start_link/2`
returns `{error, {invalid_size, Size}}` or `{error, {invalid_min_size, MinSize}}`.
A `min_size` above `size` is lowered to `size`. `max_idle` and `max_age` must be
`infinity` or a non-negative integer, and `disconnected` `fail` or `wait`, or the
pool stops the same way with `{invalid_max_idle, _}`, `{invalid_max_age, _}` or
`{invalid_disconnected, _}`. A `connection` that is missing, not a map, or has no
`user` stops it with `invalid_connection`, and options that are not a map with
`invalid_opts`. None of these reasons carries the options.

The options are also the pool's child spec under `minato_sup`, and a supervisor
prints its child specs: when a pool declared in the application environment
fails to start at boot, each time a running pool exits abnormally and is
restarted, and in `sys:get_status(minato_sup)`. A password given as a binary
appears in all three. Give it as a fun, as `minato_conn:opts()` allows, to keep
it out; a fun cannot be written in `sys.config`, so such a pool is started with
`minato:start_pool/2`.

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

-type waiter() :: {gen_server:from(), pid(), reference(), integer() | infinity}.

-type idle() :: {minato_conn:conn(), Since :: integer(), [expected()]}.

-type lent() :: {ok, minato_conn:conn(), [expected()], Size :: pos_integer()}.

-type cast() ::
    {checkin, pid(), minato_conn:conn()}
    | {unlent, pid(), minato_conn:conn(), [expected()]}
    | {discard, pid(), minato_conn:conn()}
    | {gave_up, pid()}
    | timed_out.

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

The timeout covers reading the answer to the connection's reset as well as
waiting for one. A checkout that runs out of time while the pool has not yet
answered waits up to a further 100 milliseconds for that answer, so that a
connection lent at the last moment goes back to the pool. One that finds every
connection it tries left unusable, the pool's size and one more, returns
`{error, {session_reset, Why}}`.
""".
-spec checkout(name(), timeout()) -> {ok, minato_conn:conn()} | {error, term()}.
checkout(Name, Timeout) ->
    minato_telemetry:span([minato, checkout], #{pool => Name}, fun() ->
        borrowed(checked_out(Name, deadline(Timeout)))
    end).

%%--- Checking out
%%
%% These run in the caller, which owns the socket once it is lent.

-spec checked_out(name(), integer() | infinity) -> {ok, minato_conn:conn()} | {error, term()}.
checked_out(Name, Deadline) ->
    checked_out(Name, Deadline, undefined).

-spec checked_out(name(), integer() | infinity, pos_integer() | undefined) ->
    {ok, minato_conn:conn()} | {error, term()}.
checked_out(Name, Deadline, Left) ->
    case waited(Name, Deadline) of
        {ok, Conn, Expected, Size} ->
            Answer = cleared(Conn, read_timeout(Conn, Deadline), Expected, false),
            ready(Name, Deadline, attempts(Left, Size), Conn, Answer);
        {error, Reason} ->
            {error, Reason}
    end.

%% Every connection in the pool may have been left dirty or have died while it
%% sat there, so a checkout gets through all of them and one fresh one before it
%% gives up, rather than opening connections for as long as its deadline allows.
-spec attempts(pos_integer() | undefined, pos_integer()) -> pos_integer().
attempts(undefined, Size) -> Size + ?RESET_RETRIES;
attempts(Left, _Size) -> Left.

-spec ready(name(), integer() | infinity, pos_integer(), minato_conn:conn(), cleared()) ->
    {ok, minato_conn:conn()} | {error, term()}.
ready(_Name, _Deadline, _Left, _Conn, {ok, Reset}) ->
    {ok, Reset};
ready(Name, Deadline, Left, Conn, {refused, Why}) ->
    ok = warned(Name, Why),
    retried(Name, Deadline, Left, Conn, Why);
ready(Name, Deadline, Left, Conn, {lost, Why}) ->
    retried(Name, Deadline, Left, Conn, Why).

-spec retried(name(), integer() | infinity, pos_integer(), minato_conn:conn(), term()) ->
    {ok, minato_conn:conn()} | {error, term()}.
retried(Name, _Deadline, 1, Conn, Why) ->
    ok = discard(Name, Conn),
    {error, {session_reset, Why}};
retried(Name, Deadline, Left, Conn, _Why) ->
    ok = discard(Name, Conn),
    checked_out(Name, Deadline, Left - 1).

-spec warned(name(), term()) -> ok.
warned(Name, Why) ->
    _ = ?LOG_WARNING(#{event => session_reset_failed, pool => Name, reason => Why}, #{
        domain => [minato]
    }),
    ok.

%% Refused is what a connection was left with, and worth a warning; lost is a
%% connection that went away, which the borrower finds out about anyway.
-type cleared() :: {ok, minato_conn:conn()} | {refused, term()} | {lost, term()}.

-type expected() :: minato_protocol:tag() | {row, binary()}.

%% Reads the answer to the reset the pool sent when the connection came back.
%% Only its own command tags, in order, with the nonce it was sent with, then an
%% idle ReadyForQuery will do: anything else answering first is an answer the
%% last borrower never read.
-spec cleared(minato_conn:conn(), timeout(), [expected()], boolean()) -> cleared().
cleared(Conn, Timeout, [Next | Rest] = Expected, Started) ->
    case minato_conn:next(Conn, Timeout) of
        {ok, {command_complete, Next}, Read} ->
            cleared(Read, Timeout, Rest, true);
        {ok, {data_row, <<1:16, Length:32, Nonce:Length/binary>>}, Read} when
            Next =:= {row, Nonce}
        ->
            cleared(Read, Timeout, Rest, true);
        {ok, {data_row, _Other}, _Read} when element(1, Next) =:= row ->
            {refused, unread_answer};
        {ok, {command_complete, {select, 0}}, _Read} when element(1, Next) =:= row ->
            {refused, sql_prepared_statement};
        {ok, {command_complete, _Other}, _Read} ->
            {refused, unread_answer};
        {ok, {ready_for_query, _Status}, _Read} ->
            {refused, unread_answer};
        {ok, {error_response, _Reported}, _Read} when not Started ->
            {refused, unread_answer};
        {ok, {error_response, Reported}, _Read} ->
            {refused, narrowed(Reported)};
        {ok, _Message, Read} ->
            cleared(Read, Timeout, Expected, Started);
        {error, Reason} ->
            {lost, Reason}
    end;
cleared(Conn, Timeout, [], Started) ->
    case minato_conn:next(Conn, Timeout) of
        {ok, {ready_for_query, idle}, Read} ->
            nothing_unread(Read);
        {ok, {ready_for_query, Status}, _Read} ->
            {refused, Status};
        {ok, {error_response, Reported}, _Read} ->
            {refused, narrowed(Reported)};
        {ok, {parameter_status, _Name, _Value}, Read} ->
            cleared(Read, Timeout, [], Started);
        {ok, {notice_response, _Fields}, Read} ->
            cleared(Read, Timeout, [], Started);
        {ok, {notification_response, _Pid, _Channel, _Payload}, Read} ->
            cleared(Read, Timeout, [], Started);
        {ok, _Other, _Read} ->
            {refused, unread_answer};
        {error, Reason} ->
            {lost, Reason}
    end.

-spec narrowed(minato_protocol:fields()) -> {pgsql_error, map()}.
narrowed(Reported) ->
    {pgsql_error, maps:with([code], Reported)}.

%% The reset answers in one round trip, so it gets no longer than any other read
%% on the connection, whatever the checkout allows.
-spec read_timeout(minato_conn:conn(), integer() | infinity) -> timeout().
read_timeout(Conn, Deadline) ->
    case {remaining(Deadline), minato_conn:timeout(Conn)} of
        {infinity, Read} -> Read;
        {Left, infinity} -> Left;
        {Left, Read} -> min(Left, Read)
    end.

%% A server that ended the backend while it sat in the pool answered the reset
%% first and then said why it was closing, so the reset alone does not show it.
-spec nothing_unread(minato_conn:conn()) -> {ok, minato_conn:conn()} | {lost, unusable}.
nothing_unread(Conn) ->
    case minato_conn:usable(Conn) of
        true -> {ok, Conn};
        false -> {lost, unusable}
    end.

-spec deadline(timeout()) -> integer() | infinity.
deadline(infinity) -> infinity;
deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

-spec remaining(integer() | infinity) -> timeout().
remaining(infinity) ->
    infinity;
remaining(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 -> Left;
        _Passed -> 0
    end.

-spec borrowed({ok, minato_conn:conn()} | {error, term()}) ->
    {{ok, minato_conn:conn()} | {error, term()}, minato_telemetry:metadata()}.
borrowed({ok, Conn}) -> {{ok, Conn}, #{outcome => ok}};
borrowed({error, Reason}) -> {{error, Reason}, #{outcome => error, reason => Reason}}.

-spec waited(name(), integer() | infinity) -> lent() | {error, term()}.
waited(Name, Deadline) ->
    waited(Name, Deadline, remaining(Deadline)).

-spec waited(name(), integer() | infinity, timeout()) -> lent() | {error, term()}.
waited(Name, _Deadline, 0) ->
    ok = gen_server:cast(Name, timed_out),
    {error, checkout_timeout};
waited(Name, Deadline, Timeout) ->
    Request = gen_server:send_request(Name, {checkout, Deadline}),
    case response(Request, Timeout) of
        {reply, Answer} -> Answer;
        timeout -> gave_up(Name, Request);
        {error, {noproc, _Pool}} -> {error, {no_pool, Name}};
        {error, {Reason, _Pool}} -> {error, Reason}
    end.

%% The pool never lends past the deadline and answers a waiter that gave up, so
%% whatever answer is on its way arrives promptly. It is collected all the same:
%% a connection lent at the last moment goes back to the pool rather than staying
%% borrowed by a caller that will never check it in.
-spec gave_up(name(), gen_server:request_id()) -> {error, checkout_timeout}.
gave_up(Name, Request) ->
    ok = gen_server:cast(Name, {gave_up, self()}),
    ok = unlent(Name, gen_server:receive_response(Request, ?LATE_ANSWER_TIMEOUT)),
    {error, checkout_timeout}.

%% Its reset is still unread, so whoever borrows it next reads and checks it.
-spec unlent(name(), dynamic()) -> ok.
unlent(Name, {reply, {ok, Conn, Expected, _Size}}) ->
    case whereis(Name) of
        Pid when is_pid(Pid) ->
            _ = minato_conn:give_away(Conn, Pid),
            gen_server:cast(Name, {unlent, self(), Conn, Expected});
        _Gone ->
            minato_conn:close(Conn)
    end;
unlent(_Name, _Refused) ->
    ok.

-spec response(gen_server:request_id(), timeout()) -> dynamic().
response(Request, Timeout) ->
    gen_server:wait_response(Request, Timeout).

-doc """
Give a connection back.

The socket goes back to the pool first, because the pool cannot read a socket it
does not own. A connection with a transaction open is rolled back before it is
lent again, and one that cannot be is closed and replaced. The rest of the
session is reset as the module documentation describes.
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

-type refused() ::
    invalid_opts
    | invalid_connection
    | {invalid_size, term()}
    | {invalid_min_size, term()}
    | {invalid_max_idle, term()}
    | {invalid_max_age, term()}
    | {invalid_disconnected, term()}.

-type settings() :: {pos_integer(), non_neg_integer(), timeout(), timeout(), fail | wait}.

%% Options can come from the environment, so anything reaches here. No reason
%% carries the options themselves: they hold the password.
-spec init({name(), dynamic()}) -> {ok, #state{}} | {stop, refused()}.
init({Name, #{connection := #{user := _} = Connection} = Opts}) ->
    case checked(Opts) of
        {ok, Settings} -> started(Name, Connection, Settings);
        {refused, Reason} -> {stop, Reason}
    end;
init({_Name, Opts}) when is_map(Opts) ->
    {stop, invalid_connection};
init({_Name, _Opts}) ->
    {stop, invalid_opts}.

-spec checked(opts()) -> {ok, settings()} | {refused, refused()}.
checked(Opts) ->
    Settings = {
        maps:get(size, Opts, ?DEFAULT_SIZE),
        maps:get(min_size, Opts, ?DEFAULT_MIN_SIZE),
        maps:get(max_idle, Opts, ?DEFAULT_MAX_IDLE),
        maps:get(max_age, Opts, ?DEFAULT_MAX_AGE),
        maps:get(disconnected, Opts, ?DEFAULT_DISCONNECTED)
    },
    case Settings of
        {Size, _, _, _, _} when not is_integer(Size); Size < 1 ->
            {refused, {invalid_size, Size}};
        {_, MinSize, _, _, _} when not is_integer(MinSize); MinSize < 0 ->
            {refused, {invalid_min_size, MinSize}};
        {_, _, MaxIdle, _, _} when not ?IS_TIMEOUT(MaxIdle) ->
            {refused, {invalid_max_idle, MaxIdle}};
        {_, _, _, MaxAge, _} when not ?IS_TIMEOUT(MaxAge) ->
            {refused, {invalid_max_age, MaxAge}};
        {_, _, _, _, Disconnected} when Disconnected =/= fail, Disconnected =/= wait ->
            {refused, {invalid_disconnected, Disconnected}};
        _Valid ->
            {ok, Settings}
    end.

-spec started(name(), minato_conn:opts(), settings()) -> {ok, #state{}}.
started(Name, Connection, {Size, MinSize, MaxIdle, MaxAge, Disconnected}) ->
    process_flag(trap_exit, true),
    State = #state{
        name = Name,
        opts = Connection,
        size = Size,
        min_size = min(MinSize, Size),
        disconnected = Disconnected,
        max_idle = MaxIdle,
        max_age = MaxAge,
        counters = counters:new(?COUNTERS, [write_concurrency])
    },
    _ = erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {ok, fill(State)}.

-doc false.
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(#{state := #state{opts = Opts} = State} = Status) ->
    Status#{state => State#state{opts = maps:remove(password, Opts)}};
format_status(Status) ->
    Status.

-type request() :: {checkout, integer() | infinity} | stats | {give_away, pid(), pid()}.

-spec handle_call(request(), gen_server:from(), #state{}) ->
    {reply, term(), #state{}} | {noreply, #state{}}.
%% A caller stops waiting for its answer a while after its deadline, so a
%% connection lent after the deadline could reach nobody and stay borrowed.
handle_call({checkout, Deadline}, {Pid, _Tag} = From, State) ->
    case expired(Deadline) of
        true ->
            {reply, {error, checkout_timeout}, State};
        false ->
            case lendable(State) of
                {ok, Conn, Expected, Ready} -> lending(Ready, Conn, Expected, Pid);
                {none, Ready} -> asked(Ready, From, Deadline)
            end
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
handle_cast({unlent, Pid, Conn, Expected}, State) ->
    {noreply, unborrowed(State, Pid, Conn, Expected)};
handle_cast({gave_up, Pid}, State) ->
    ok = counters:add(State#state.counters, ?TIMEOUTS, 1),
    {Gone, Kept} = lists:partition(
        fun({_From, Waiter, _Monitor, _Deadline}) -> Waiter =:= Pid end,
        queue:to_list(State#state.waiting)
    ),
    _ = [answered_gave_up(Waiter) || Waiter <- Gone],
    {noreply, State#state{waiting = queue:from_list(Kept)}};
handle_cast(timed_out, State) ->
    ok = counters:add(State#state.counters, ?TIMEOUTS, 1),
    {noreply, State};
handle_cast(_Message, State) ->
    {noreply, State}.

-spec answered_gave_up(waiter()) -> ok.
answered_gave_up({From, _Pid, Monitor, _Deadline}) ->
    true = erlang:demonitor(Monitor, [flush]),
    gen_server:reply(From, {error, checkout_timeout}).

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
    {noreply, replenished(State)};
handle_info(sweep, State) ->
    _ = erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {noreply, swept(State)};
handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    {noreply, lost(State, Pid)};
handle_info(_Message, State) ->
    {noreply, State}.

-spec terminate(term(), #state{}) -> ok.
terminate(_Reason, #state{idle = Idle}) ->
    _ = [minato_conn:close(Conn) || {Conn, _Since, _Expected} <- Idle],
    ok.

%%----------------------------------------------------------------------
%% Lending
%%----------------------------------------------------------------------

-doc """
The most recently returned idle connection.

A connection can die while it sits in the pool and nothing announces it. The
borrower finds out, because it reads the answer to the connection's reset before
anything else and takes another connection when none comes, so a server restart
does not become one failed statement per pooled connection.
""".
-spec lendable(#state{}) ->
    {ok, minato_conn:conn(), [expected()], #state{}} | {none, #state{}}.
lendable(#state{idle = []} = State) ->
    {none, State};
lendable(#state{idle = [{Conn, _Since, Expected} | Rest]} = State) ->
    {ok, Conn, Expected, State#state{idle = Rest}}.

-spec lending(#state{}, minato_conn:conn(), [expected()], pid()) -> {reply, term(), #state{}}.
lending(State, Conn, Expected, Pid) ->
    case minato_conn:give_away(Conn, Pid) of
        ok ->
            ok = counters:add(State#state.counters, ?CHECKOUTS, 1),
            {reply, {ok, Conn, Expected, State#state.size}, borrow(State, Pid, {Conn, Expected})};
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

-spec asked(#state{}, gen_server:from(), integer() | infinity) ->
    {reply, {error, disconnected}, #state{}} | {noreply, #state{}}.
asked(State, {Pid, _Tag} = From, Deadline) ->
    case unreachable(State) of
        true ->
            {reply, {error, disconnected}, State};
        false ->
            ok = counters:add(State#state.counters, ?WAITS, 1),
            Waiter = {From, Pid, erlang:monitor(process, Pid), Deadline},
            Waiting = queue:in(Waiter, State#state.waiting),
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
        true -> {reply, ok, borrow(released(State, From), To, undefined)}
    end.

-doc """
Note that `Pid` is holding one more connection.

Counted rather than recorded, because one process may hold several: a worker
with two repos does, and so does anything that checks a connection out on behalf
of somebody else. A map keyed by pid alone would have lost the second
connection at the second checkin, which is a connection leaked per checkout
pair.

`Lent` is what the pool lent, kept until the next lend to the same caller: a
caller that gave up is still waiting for that answer and can borrow nothing
else, so only the last can come back with `{unlent, ...}`.
""".
-spec borrow(#state{}, pid(), {minato_conn:conn(), [expected()]} | undefined) -> #state{}.
borrow(#state{borrowed = Borrowed} = State, Pid, Lent) ->
    case maps:find(Pid, Borrowed) of
        {ok, #borrowed{count = Count, last = Last} = Held} ->
            Holding = Held#borrowed{count = Count + 1, last = latest(Lent, Last)},
            State#state{borrowed = Borrowed#{Pid => Holding}};
        error ->
            Monitor = erlang:monitor(process, Pid),
            State#state{borrowed = Borrowed#{Pid => #borrowed{monitor = Monitor, last = Lent}}}
    end.

-spec latest(Lent, Lent) -> Lent when Lent :: {minato_conn:conn(), [expected()]} | undefined.
latest(undefined, Last) -> Last;
latest(Lent, _Last) -> Lent.

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
hand_out(State, Conn) ->
    case nonce() of
        {ok, Nonce} ->
            reset_written(State, Conn, reset(Nonce, minato_conn:transaction_status(Conn)));
        error ->
            discarded(State, Conn)
    end.

%% The reset and the answer it has to get. `ROLLBACK` only when the borrower left
%% a transaction open, because outside one it is a warning in the server log for
%% every checkin. A borrower that sent `BEGIN` and never read the answer is not
%% fooled by this: the reset is then answered by the `BEGIN` first.
-spec reset(binary(), minato_protocol:transaction_status()) -> {iodata(), [expected()]}.
reset(Nonce, idle) ->
    {[?RESET, Nonce, ?RESET_END], ?RESET_TAGS ++ [{row, Nonce}, {select, 1}]};
reset(Nonce, _Open) ->
    {Sql, Expected} = reset(Nonce, idle),
    {[?ROLLBACK, Sql], [{rollback, undefined} | Expected]}.

-spec reset_written(#state{}, minato_conn:conn(), {iodata(), [expected()]}) -> #state{}.
reset_written(State, Conn, {Sql, Expected}) ->
    case minato_conn:send(Conn, {query, Sql}) of
        ok -> reset_sent(State, Conn, Expected);
        {error, _Reason} -> discarded(State, Conn)
    end.

-spec nonce() -> {ok, binary()} | error.
nonce() ->
    try crypto:strong_rand_bytes(8) of
        Bytes -> {ok, binary:encode_hex(Bytes)}
    catch
        error:low_entropy -> error
    end.

-spec reset_sent(#state{}, minato_conn:conn(), [expected()]) -> #state{}.
reset_sent(#state{waiting = Waiting} = State, Conn, Expected) ->
    case queue:out(Waiting) of
        {{value, {From, Pid, Monitor, Deadline}}, Rest} ->
            true = erlang:demonitor(Monitor, [flush]),
            case expired(Deadline) of
                true ->
                    gen_server:reply(From, {error, checkout_timeout}),
                    reset_sent(State#state{waiting = Rest}, Conn, Expected);
                false ->
                    {reply, Answer, Lent} = lending(
                        State#state{waiting = Rest}, Conn, Expected, Pid
                    ),
                    gen_server:reply(From, Answer),
                    Lent
            end;
        {empty, _Rest} ->
            Since = erlang:monotonic_time(millisecond),
            State#state{idle = [{Conn, Since, Expected} | State#state.idle]}
    end.

-spec returned(#state{}, pid(), minato_conn:conn()) -> #state{}.
returned(#state{borrowed = Borrowed} = State, Pid, Conn) ->
    case maps:is_key(Pid, Borrowed) of
        true -> aged(released(State, Pid), Conn);
        false -> discarded(State, Conn)
    end.

-spec unborrowed(#state{}, pid(), minato_conn:conn(), [expected()]) -> #state{}.
unborrowed(#state{borrowed = Borrowed} = State, Pid, Conn, Expected) ->
    case maps:find(Pid, Borrowed) of
        {ok, #borrowed{last = {Conn, Expected}} = Held} ->
            Unlent = State#state{borrowed = Borrowed#{Pid => Held#borrowed{last = undefined}}},
            reset_sent(released(Unlent, Pid), Conn, Expected);
        {ok, _Other} ->
            discarded(released(State, Pid), Conn);
        error ->
            discarded(State, Conn)
    end.

-spec dropped(#state{}, pid(), minato_conn:conn()) -> #state{}.
dropped(#state{borrowed = Borrowed} = State, Pid, Conn) ->
    case maps:is_key(Pid, Borrowed) of
        true -> discarded(released(State, Pid), Conn);
        false -> discarded(State, Conn)
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
    replenished(State).

-spec discarded(#state{}, minato_conn:conn()) -> #state{}.
discarded(State, Conn) ->
    ok = minato_conn:close(Conn),
    ok = counters:add(State#state.counters, ?DISCONNECTS, 1),
    ok = minato_telemetry:event(
        [minato, connection, closed], #{pool => State#state.name, reason => discarded}
    ),
    replenished(State).

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
            replenished(State#state{borrowed = maps:remove(Pid, Borrowed)});
        error ->
            State#state{waiting = without(State#state.waiting, Pid)}
    end.

-spec without(queue:queue(waiter()), pid()) -> queue:queue(waiter()).
without(Waiting, Pid) ->
    queue:filter(fun({_From, Waiter, _Monitor, _Deadline}) -> Waiter =/= Pid end, Waiting).

-spec expired(integer() | infinity) -> boolean().
expired(infinity) -> false;
expired(Deadline) -> erlang:monotonic_time(millisecond) >= Deadline.

%%----------------------------------------------------------------------
%% Filling up
%%----------------------------------------------------------------------

%% Back up to the floor, and one more if somebody is waiting: a pool whose floor
%% is below what it has lent would otherwise leave a waiter queued for a
%% connection nobody is going to open.
-spec replenished(#state{}) -> #state{}.
replenished(State) ->
    Filled = fill(State),
    case queue:is_empty(Filled#state.waiting) of
        true -> Filled;
        false -> grown(Filled)
    end.

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

-spec oldest_first([idle()], [idle()]) -> [idle()].
oldest_first([], Reversed) ->
    Reversed;
oldest_first([Held | Rest], Reversed) ->
    oldest_first(Rest, [Held | Reversed]).

-spec idle_split([idle()], integer(), non_neg_integer(), [idle()], [minato_conn:conn()]) ->
    {[idle()], [minato_conn:conn()]}.
idle_split([], _Cutoff, _Floor, Keep, Stale) ->
    {Keep, Stale};
idle_split([{Conn, Since, _Expected} | Rest], Cutoff, Floor, Keep, Stale) when
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
