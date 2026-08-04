-module(minato_txn).
-moduledoc """
Transactions on a connection.

A transaction is session state rather than a statement, which is why it is here
rather than in `m:minato_query`: every statement between `BEGIN` and `COMMIT`
has to run on the same connection, and a client where that is not guaranteed
has a transaction only by accident.

```erlang
{ok, Value, Conn1} = minato_txn:transaction(Conn, fun(Open) ->
    {ok, _Result, Written} = minato_query:query(Open, ~"INSERT INTO t VALUES ($1)", [1]),
    {ok, done, Written}
end).
```

The function is given the connection and returns one back, because everything in
this client threads the connection through. Returning `{rollback, Reason, Conn}`
rolls back and reports `Reason`; raising rolls back and re-raises.

## A COMMIT the server turns into a ROLLBACK

PostgreSQL answers `COMMIT` with the tag `ROLLBACK` when the transaction had
already failed. Nothing was written, and a client that reads only "the COMMIT
succeeded" reports success for work the server threw away. That is the failure
mode that makes a job queue run a job twice or an ledger lose an entry, so
`commit/1` compares the tag it got with the statement it sent and answers
`{error, transaction_rolled_back, Conn}` when they disagree.

`ReadyForQuery` carries the same news in its status byte, and `status/1` reports
it: `idle` outside a transaction, `transaction` inside a good one, `failed`
inside one where a statement has already errored and everything further will be
rejected until it is rolled back.

## Savepoints

`savepoint/2` and `rollback_to/2` are the nested case. There is no nested
`transaction/2`, because SQL has no nested `BEGIN`: a second `BEGIN` inside a
transaction is a warning and a no-op, and a client that hid that would report a
rollback the server never did.
""".

-export([
    transaction/2,
    open/1,
    commit/1,
    rollback/1,
    savepoint/2,
    rollback_to/2,
    release/2,
    status/1
]).

-doc "What went wrong. `transaction_rolled_back` is a COMMIT the server refused.".
-type error() :: minato_query:error() | transaction_rolled_back.

-doc "What the caller's function answers with.".
-type outcome() :: {ok, term(), conn()} | {rollback, term(), conn()}.

-export_type([error/0, outcome/0]).

-type conn() :: minato_conn:conn().

-doc """
Run a function inside a transaction.

`BEGIN` first, the function next, then `COMMIT` for `{ok, Value, Conn}` and
`ROLLBACK` for `{rollback, Reason, Conn}`. An exception rolls back and is
re-raised, so a `throw` out of the middle of a transaction cannot leave the
connection holding an open one.

Answers `{error, transaction_rolled_back, Conn}` when the server turned the
`COMMIT` into a `ROLLBACK`, which is the case a caller must not read as success.
""".
-spec transaction(conn(), fun((conn()) -> outcome())) ->
    {ok, term(), conn()} | {rollback, term(), conn()} | {error, error(), conn()} | {error, error()}.
transaction(Conn, Fun) ->
    case open(Conn) of
        {ok, Open} -> guarded(Open, Fun);
        Failed -> Failed
    end.

-doc "Begin a transaction.".
-spec open(conn()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
open(Conn) ->
    statement(Conn, ~"BEGIN", 'begin').

-doc """
Commit a transaction.

`{error, transaction_rolled_back, Conn}` is a server that answered the `COMMIT`
with `ROLLBACK` because the transaction had already failed. Nothing was written.
""".
-spec commit(conn()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
commit(Conn) ->
    statement(Conn, ~"COMMIT", commit).

-doc "Roll a transaction back. A connection with nothing open is left as it is.".
-spec rollback(conn()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
rollback(Conn) ->
    statement(Conn, ~"ROLLBACK", rollback).

-doc "Name a point inside the transaction that `rollback_to/2` can return to.".
-spec savepoint(conn(), binary()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
savepoint(Conn, Name) ->
    statement(Conn, <<"SAVEPOINT ", (quoted(Name))/binary>>, savepoint).

-doc """
Undo everything since a savepoint, keeping the transaction open.

This is what makes a failed statement recoverable: a transaction that has
errored rejects everything until it is rolled back, and rolling back to a
savepoint taken before the statement clears that without losing the work before
it.
""".
-spec rollback_to(conn(), binary()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
rollback_to(Conn, Name) ->
    statement(Conn, <<"ROLLBACK TO SAVEPOINT ", (quoted(Name))/binary>>, rollback).

-doc "Forget a savepoint, keeping everything done since it.".
-spec release(conn(), binary()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
release(Conn, Name) ->
    statement(Conn, <<"RELEASE SAVEPOINT ", (quoted(Name))/binary>>, release).

-doc """
What the server last said about the transaction on this connection.

`failed` is a transaction in which a statement has already errored: every
further statement is rejected until it is rolled back.
""".
-spec status(conn()) -> minato_protocol:transaction_status().
status(Conn) ->
    minato_conn:transaction_status(Conn).

%%----------------------------------------------------------------------
%% Running the transaction
%%----------------------------------------------------------------------

-spec guarded(conn(), fun((conn()) -> outcome())) ->
    {ok, term(), conn()} | {rollback, term(), conn()} | {error, error(), conn()} | {error, error()}.
guarded(Conn, Fun) ->
    try Fun(Conn) of
        {ok, Value, Used} -> committed(Used, Value);
        {rollback, Reason, Used} -> rolled_back(Used, Reason)
    catch
        Class:Reason:Stacktrace ->
            _ = rollback(Conn),
            reraise(Class, Reason, Stacktrace)
    end.

-spec reraise(error | exit | throw, term(), erlang:raise_stacktrace()) -> no_return().
reraise(Class, Reason, Stacktrace) ->
    erlang:raise(Class, Reason, Stacktrace),
    error({minato_txn, #{message => Class, reason => Reason, data => Stacktrace}}).

-spec committed(conn(), term()) ->
    {ok, term(), conn()} | {error, error(), conn()} | {error, error()}.
committed(Conn, Value) ->
    case commit(Conn) of
        {ok, Committed} -> {ok, Value, Committed};
        Failed -> Failed
    end.

-spec rolled_back(conn(), term()) ->
    {rollback, term(), conn()} | {error, error(), conn()} | {error, error()}.
rolled_back(Conn, Reason) ->
    case rollback(Conn) of
        {ok, Rolled} -> {rollback, Reason, Rolled};
        Failed -> Failed
    end.

-spec statement(conn(), binary(), atom()) ->
    {ok, conn()} | {error, error(), conn()} | {error, error()}.
statement(Conn, Sql, Expected) ->
    case minato_query:simple(Conn, Sql) of
        {ok, Results, Ran} -> answered(Ran, Results, Expected);
        {error, Reason, Ran} -> {error, Reason, Ran};
        {error, Reason} -> {error, Reason}
    end.

-spec answered(conn(), [minato_protocol:result()], atom()) ->
    {ok, conn()} | {error, error(), conn()}.
answered(Conn, [#{command := rollback} | _Rest], commit) ->
    {error, transaction_rolled_back, Conn};
answered(Conn, _Results, _Expected) ->
    {ok, Conn}.

-spec quoted(binary()) -> binary().
quoted(Name) ->
    Escaped = binary:replace(Name, ~"\"", ~"\"\"", [global]),
    <<$", Escaped/binary, $">>.
