-module(minato).
-moduledoc """
The interface a caller uses: a pool, and queries against it.

```erlang
{ok, _Pid} = minato:start_pool(main, #{size => 10,
                                       connection => #{host => "localhost",
                                                       user => ~"minato",
                                                       password => ~"minato",
                                                       database => ~"minato_test"}}),
{ok, #{rows := [{42}]}} = minato:query(main, ~"SELECT $1::int4", [42]).
```

Every function here borrows a connection, uses it, and gives it back. The
connection layer underneath threads a connection through each call, because the
caller owns the socket; this module hides that for the ordinary case and `with/2`
hands it to callers who need several statements on one connection.

Pools can also be declared in the application environment, which is what an
application that wants its pool up before anything asks for it needs:

```erlang
{minato, [{pools, #{main => #{size => 10, connection => #{user => ~"minato"}}}}]}
```

## What a caller gets back

`{ok, Result}` or `{error, Reason}`, with no connection in it. A statement that
failed on the server gives `{error, {pgsql_error, Fields}}` and the connection
goes back to the pool, because a failed statement is a normal outcome. A
connection that failed underneath gives `{error, {socket, Reason}}` and is
closed and replaced rather than lent to somebody else.

## Transactions

`transaction/2` borrows one connection for the whole of the function, which is
what makes it a transaction rather than a sequence of statements that happen to
be nearby. The function is handed the connection and hands it back, since
statements inside a transaction have to run on that one.
""".

-export([
    start_pool/2,
    stop_pool/1,
    start_listener/2,
    stop_listener/1,
    listen/2,
    unlisten/2,
    query/3,
    query/4,
    simple/2,
    simple/3,
    transaction/2,
    with/2,
    stats/1
]).

-doc "A pool name, as given to `start_pool/2` or declared in the environment.".
-type pool() :: minato_pool:name().

-doc "What a call answers with once the connection has gone back to the pool.".
-type answer(Value) :: {ok, Value} | {error, term()}.

-export_type([pool/0, answer/1]).

-type conn() :: minato_conn:conn().

-doc """
Start a pool and keep it under minato's supervisor.

The pool is up before it has connections: they are opened in the background and
retried with backoff, so an application that starts before its database starts
anyway and the first query waits.
""".
-spec start_pool(pool(), minato_pool:opts()) -> supervisor:startchild_ret().
start_pool(Name, Opts) ->
    minato_sup:start_pool(Name, Opts).

-doc "Stop a pool and close every connection it holds.".
-spec stop_pool(pool()) -> ok | {error, not_found}.
stop_pool(Name) ->
    minato_sup:stop_pool(Name).

-doc """
Start a listener and keep it under minato's supervisor.

A listener holds one connection of its own, because `LISTEN` is session state
and a pooled connection would deliver notifications to whichever caller happened
to hold it next.
""".
-spec start_listener(minato_listener:name(), minato_listener:opts()) ->
    supervisor:startchild_ret().
start_listener(Name, Opts) ->
    minato_sup:start_listener(Name, Opts).

-doc "Stop a listener and close its connection.".
-spec stop_listener(minato_listener:name()) -> ok | {error, not_found}.
stop_listener(Name) ->
    minato_sup:stop_listener(Name).

-doc """
Subscribe the calling process to a channel.

Notifications arrive as `{minato_notification, Channel, Payload, From}`, and a
reconnect arrives as `{minato_listener, Name, resubscribed}` - which means
notifications were missed, because `NOTIFY` has no replay. See
`m:minato_listener`.
""".
-spec listen(minato_listener:name(), binary()) -> ok | {error, term()}.
listen(Listener, Channel) ->
    minato_listener:listen(Listener, Channel).

-doc "Stop the calling process's subscription.".
-spec unlisten(minato_listener:name(), binary()) -> ok | {error, term()}.
unlisten(Listener, Channel) ->
    minato_listener:unlisten(Listener, Channel).

-doc "`query/4` with the default decoding options.".
-spec query(pool(), iodata(), [term()]) -> answer(minato_protocol:result()).
query(Pool, Sql, Parameters) ->
    query(Pool, Sql, Parameters, #{}).

-doc """
Run one statement with parameters.

The extended protocol, so the parameters are parameters and nothing is pasted
into the SQL. See `m:minato_query` for what the result holds and which wire
formats are asked for.
""".
-spec query(pool(), iodata(), [term()], minato_protocol:opts()) ->
    answer(minato_protocol:result()).
query(Pool, Sql, Parameters, Opts) ->
    with(Pool, fun(Conn) -> answered(minato_query:query(Conn, Sql, Parameters, Opts)) end).

-doc "`simple/3` with the default decoding options.".
-spec simple(pool(), iodata()) -> answer([minato_protocol:result()]).
simple(Pool, Sql) ->
    simple(Pool, Sql, #{}).

-doc """
Run statements through the simple query protocol, with no parameters.

One result per statement. For DDL, `SET`, and anything else with no values in
it; a statement with a value in it belongs in `query/3`.
""".
-spec simple(pool(), iodata(), minato_protocol:opts()) -> answer([minato_protocol:result()]).
simple(Pool, Sql, Opts) ->
    with(Pool, fun(Conn) -> answered(minato_query:simple(Conn, Sql, Opts)) end).

-doc """
Run a function inside a transaction, on one borrowed connection.

```erlang
minato:transaction(main, fun(Conn) ->
    {ok, _Result, Written} = minato_query:query(Conn, ~"INSERT INTO t VALUES ($1)", [1]),
    {ok, done, Written}
end).
```

`{ok, Value}` for a committed transaction, `{rollback, Reason}` for one the
function asked to roll back, and `{error, transaction_rolled_back}` for a
`COMMIT` the server turned into a `ROLLBACK`, which is not success. See
`m:minato_txn`.
""".
-spec transaction(pool(), fun((conn()) -> minato_txn:outcome())) ->
    {ok, term()} | {rollback, term()} | {error, term()}.
transaction(Pool, Fun) ->
    with(Pool, fun(Conn) -> concluded(minato_txn:transaction(Conn, Fun)) end).

-doc """
Borrow a connection for as long as the function needs it.

The function is handed the connection and answers `{keep, Value, Conn}` with the
connection it finished with, or `{discard, Value}` for a connection that should
not be lent to anybody else. An exception discards the connection and is
re-raised, because a connection abandoned part way through a result set has
bytes on it that nobody has read.
""".
-spec with(pool(), fun((conn()) -> {keep, Value, conn()} | {discard, Value})) ->
    Value | {error, term()}.
with(Pool, Fun) ->
    case minato_pool:checkout(Pool) of
        {ok, Conn} -> used(Pool, Conn, Fun);
        {error, Reason} -> {error, Reason}
    end.

-doc "What the pool holds and what it has done.".
-spec stats(pool()) -> minato_pool:stats().
stats(Pool) ->
    minato_pool:stats(Pool).

%%----------------------------------------------------------------------
%% Borrowing
%%----------------------------------------------------------------------

-spec used(pool(), conn(), fun((conn()) -> {keep, Value, conn()} | {discard, Value})) -> Value.
used(Pool, Conn, Fun) ->
    try Fun(Conn) of
        {discard, Value} ->
            ok = minato_pool:discard(Pool, Conn),
            Value;
        {keep, Value, Used} ->
            ok = minato_pool:checkin(Pool, Used),
            Value
    catch
        Class:Reason:Stacktrace ->
            ok = minato_pool:discard(Pool, Conn),
            reraise(Class, Reason, Stacktrace)
    end.

-spec answered(
    {ok, Result, conn()} | {error, term(), conn()} | {error, term()}
) -> {keep, answer(Result), conn()} | {discard, answer(Result)}.
answered({ok, Result, Conn}) -> {keep, {ok, Result}, Conn};
answered({error, Reason, Conn}) -> {keep, {error, Reason}, Conn};
answered({error, Reason}) -> {discard, {error, Reason}}.

-spec concluded(
    {ok, term(), conn()}
    | {rollback, term(), conn()}
    | {error, term(), conn()}
    | {error, term()}
) ->
    {keep, {ok, term()} | {rollback, term()} | {error, term()}, conn()}
    | {discard, {error, term()}}.
concluded({ok, Value, Conn}) -> {keep, {ok, Value}, Conn};
concluded({rollback, Reason, Conn}) -> {keep, {rollback, Reason}, Conn};
concluded({error, Reason, Conn}) -> {keep, {error, Reason}, Conn};
concluded({error, Reason}) -> {discard, {error, Reason}}.

-spec reraise(error | exit | throw, term(), erlang:raise_stacktrace()) -> no_return().
reraise(Class, Reason, Stacktrace) ->
    erlang:raise(Class, Reason, Stacktrace),
    error({minato, #{message => Class, reason => Reason, data => Stacktrace}}).
