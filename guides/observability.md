# Observability

What minato tells you while it is running, and what it deliberately does not.

Everything here is either `telemetry` or OTP `logger`. There is no minato
metrics format, no minato log format and nothing to bridge: an OpenTelemetry
exporter, a Prometheus collector and a `logger` handler already understand what
comes out.

## Events

Spans are `telemetry:span/3` shaped - `start`, then `stop` or `exception` - and
`stop` carries `duration` in native time units. Convert with
`erlang:convert_time_unit(Duration, native, millisecond)`.

| event | measurements | metadata |
| --- | --- | --- |
| `[minato, connect, start]` | `system_time`, `monotonic_time` | `host`, `port`, `database`, `user`, `ssl` |
| `[minato, connect, stop]` | `duration`, `monotonic_time` | the above, plus `outcome`, and `reason` when it failed |
| `[minato, connect, exception]` | `duration` | the above, plus `kind`, `reason`, `stacktrace` |
| `[minato, query, start]` | `system_time`, `monotonic_time` | `path` (`simple`, `unnamed` or `cached`), `sql` when enabled |
| `[minato, query, stop]` | `duration`, `monotonic_time` | `outcome`, and `command` and `num_rows` when it worked, `reason` when it did not |
| `[minato, query, exception]` | `duration` | `kind`, `reason`, `stacktrace` |
| `[minato, checkout, start]` | `system_time`, `monotonic_time` | `pool` |
| `[minato, checkout, stop]` | `duration`, `monotonic_time` | `pool`, `outcome`, `reason` |
| `[minato, connection, opened]` | `system_time` | `pool` |
| `[minato, connection, closed]` | `system_time` | `pool`, `reason` (`discarded` or `borrower_died`) |
| `[minato, notification, received]` | `system_time`, `subscribers`, `bytes` | `listener`, `channel` |
| `[minato, listener, reconnected]` | `system_time`, `channels` | `listener` |

`[minato, checkout, stop]` is the one to watch first. Its `duration` is time
spent **waiting for a connection**, not running a query, so it separates "the
database is slow" from "the pool is too small" - two problems with completely
different fixes that look identical in a query latency graph.

## What is never emitted

- **Parameters.** Not in an event, not in a log, not in any configuration. They
  are the values themselves: the email address, the token, the amount.
- **Passwords.** They are used during authentication and never stored on the
  connection, so there is nothing to leak later. A password given as a
  `fun(() -> binary())` is called once per attempt and the result is not kept.
- **Statements, unless you ask.** `sql` appears in query events only when the
  application environment says so:

  ```erlang
  {minato, [{log_statements, true}]}
  ```

  It is read per call, so it can be turned on at three in the morning without a
  restart. It is off by default because a statement is not a secret but is next
  to one: `WHERE email = $1` is fine to log, and the same statement written by a
  caller who pasted the value in is not.

## Logs

Every log record is a map report with `domain => [minato]`, so a handler can
take or leave everything minato says in one filter:

```erlang
logger:add_handler(minato, logger_std_h, #{
    filters => [{minato, {fun logger_filters:domain/2, {stop, not_equal, [minato]}}}]
}).
```

minato logs when something happened that nobody asked for and nobody will
otherwise see:

| level | event | why it is worth a line |
| --- | --- | --- |
| warning | `connect_failed` | a pool could not open a connection; carries `reason` and `retry_in_ms` |
| warning | `listener_resubscribed` | a listener reconnected, which means notifications were missed - `NOTIFY` has no replay |
| info | `cached_plan_invalidated` | a schema change made PostgreSQL refuse a cached statement; minato recovered, but somebody ran a migration |

Failures a caller can act on are **returned, not logged**. A statement with a
syntax error comes back as `{error, {pgsql_error, _}}` and stays out of the log,
because the caller is already dealing with it and a library that logs it too
produces a log full of things somebody has already handled.

## Numbers without a collector

`minato:stats/1` reads counters the pool keeps regardless of whether anything is
attached:

```erlang
#{size := 10, idle := 8, borrowed := 2, waiting := 0,
  checkouts := 148_233, waits := 41, timeouts := 0, disconnects := 3}
```

`waits` against `checkouts` is how often a caller found nothing free.
`timeouts` is how often one gave up. `disconnects` climbing is a pool losing
connections, which is either the server closing them or the application killing
processes that hold them.

## What to alert on

- `timeouts` increasing at all. A checkout timeout is a request that failed
  before it reached the database.
- `[minato, checkout, stop]` p99 above a few milliseconds. The pool is too small
  for the load, or connections are being held across something slow.
- `disconnects` increasing while nothing is deploying.
- `listener_resubscribed` at any rate above roughly never, on a system that
  treats `NOTIFY` as its wake-up: every one of those is a window where nothing
  woke up. Poll as well; the notification is an optimisation.
- `[minato, connect, stop]` with `outcome => error` in a steady state. The
  credentials, the certificate or the network changed.
