# Getting started

minato is a PostgreSQL client for Erlang. This is the shortest path from nothing
to a query.

## Add it

```erlang
{deps, [{minato, "~> 0.1"}]}.
```

And to your `.app.src`, so it starts before you use it:

```erlang
{applications, [kernel, stdlib, minato]}.
```

## Start a pool

A pool is named, and everything else is passed to the connection:

```erlang
{ok, _Pid} = minato:start_pool(main, #{
    size => 10,
    connection => #{
        host => "localhost",
        user => ~"minato",
        password => ~"minato",
        database => ~"minato_test"
    }
}).
```

Or declare it in the application environment, which starts it with your
application rather than after it:

```erlang
{minato, [
    {pools, #{main => #{size => 10, connection => #{user => ~"minato"}}}}
]}.
```

Either way the pool is up before it has connections: they are opened in the
background and retried with backoff, so an application that starts before its
database starts anyway, and the first query waits for one.

## Run a query

```erlang
{ok, #{rows := [{42}]}} = minato:query(main, ~"SELECT $1::int4", [42]).
```

Parameters are parameters. There is no interpolation anywhere in this client,
and `simple/2` - the one path that cannot take parameters - is for statements
that have no values in them.

A result is a map:

```erlang
#{command => select, num_rows => 1, rows => [{42}]}
```

Rows are tuples by default and maps under `return_rows_as_maps`:

```erlang
{ok, #{rows := [#{id := 1, name := ~"a"}]}} =
    minato:query(main, ~"SELECT id, name FROM users WHERE id = $1", [1],
                 #{return_rows_as_maps => true, column_name_as_atom => true}).
```

## Errors

```erlang
{error, {pgsql_error, #{code := ~"23505", constraint := ~"users_email_key"}}} =
    minato:query(main, ~"INSERT INTO users (email) VALUES ($1)", [~"taken@example.com"]).
```

A statement that fails is a normal outcome, not an exception: `code` is the
SQLSTATE, and the connection goes back to the pool ready for the next caller.
What raises is a bug - the wrong number of parameters, a value that does not fit
the type the server asked for - and those raise where they happen.

## A transaction

```erlang
{ok, done} = minato:transaction(main, fun(Conn) ->
    {ok, _Result, One} = minato_query:query(Conn, ~"INSERT INTO a VALUES ($1)", [1]),
    {ok, _Second, Two} = minato_query:query(One, ~"INSERT INTO b VALUES ($1)", [2]),
    {ok, done, Two}
end).
```

The function is handed a connection and hands one back, because everything
inside the transaction has to run on that connection. `{rollback, Reason, Conn}`
rolls back and reports the reason; an exception rolls back and is re-raised.

`{error, transaction_rolled_back}` is the case worth knowing about: PostgreSQL
answers `COMMIT` with `ROLLBACK` when the transaction had already failed, and
minato tells you rather than reporting success for work that was thrown away.

## Notifications

`LISTEN` needs a connection of its own, so it gets one:

```erlang
{ok, _Pid} = minato:start_listener(events, #{connection => #{user => ~"minato"}}),
ok = minato:listen(events, ~"job_ready"),
receive
    {minato_notification, ~"job_ready", Payload, _From} -> Payload
end.
```

A listener that reconnects tells you: `{minato_listener, events, resubscribed}`
means it was away, and `NOTIFY` has no replay, so anything published while it
was gone is gone. Treat a notification as something that makes a poll faster,
never as the only way you find out.

## Where next

- [Configuration](configuration.md) - every option, with its default and why
- [Types](types.md) - what a PostgreSQL type comes back as, and what happens to
  one minato has no codec for
- [Security](security.md) - TLS, channel binding, and what never reaches a log
- [Observability](observability.md) - the events, the logs, and what to alert on
