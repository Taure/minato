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
| `[minato, query, start]` | `system_time`, `monotonic_time` | `host`, `port`, `database`, `pool` when a pool holds the connection, `path` (`simple`, `unnamed`, `cached` or `prepared`), `sql` when enabled |
| `[minato, query, stop]` | `duration`, `monotonic_time` | `host`, `port`, `database`, `pool`, `path`, `outcome`, and `command` and `num_rows` when it worked, `reason` when it did not |
| `[minato, query, exception]` | `duration` | what `start` carried, plus `kind`, `reason`, `stacktrace` |
| `[minato, checkout, start]` | `system_time`, `monotonic_time` | `pool` |
| `[minato, checkout, stop]` | `duration`, `monotonic_time` | `pool`, `outcome`, `reason` |
| `[minato, connection, opened]` | `system_time` | `pool` |
| `[minato, connection, closed]` | `system_time` | `pool`, `reason` (`discarded`, `borrower_died`, `max_age` or `idle`) |
| `[minato, notification, received]` | `system_time`, `subscribers`, `bytes` | `listener`, `channel` |
| `[minato, listener, reconnected]` | `system_time`, `channels` | `listener` |

`[minato, checkout, stop]` is the one to watch first. Its `duration` is time
spent **getting a connection**, not running a query: waiting for one to be free,
then reading the answer to the session reset the pool sent when it came back,
which is one round trip at most and nothing when the answer is already there. It
separates "the database is slow" from "the pool is too small" - two problems
with completely different fixes that look identical in a query latency graph.

## What is never emitted

- **Parameters.** Not in an event and not in a log. They are the values
  themselves: the email address, the token, the amount. The one way to see one
  is `log_values` below, and then only one that came back inside a failure.
- **Values inside a failure, unless you ask.** A failed statement's `reason`
  keeps the fields of the server's error that name things - `code`,
  `severity`, `severity_non_localised`, `constraint`, `schema`, `table`,
  `column`, `data_type`, `routine` - and drops `message`, `detail`, `hint` and
  the rest, which quote the row that broke a constraint or the input that would
  not parse. A parameter that would not encode raises `{minato_codec, #{type :=
  _, reason := _, value := redacted}}`, in the event and to the caller alike,
  because an uncaught raise ends up in a crash report. Frames in an event's
  `stacktrace` carry an arity, never arguments. The caller is still returned
  the whole `{error, {pgsql_error, Fields}}`. To have all of it in events and
  raises, on a development node or during an incident:

  ```erlang
  {minato, [{log_values, true}]}
  ```

  Read per call, like `log_statements`.
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

OTP's `default` handler drops records with a domain it does not know, so
without a handler of its own nothing minato logs is printed. To send it to the
`default` handler instead, let the domain through there:

```erlang
logger:add_handler_filter(default, minato, {fun logger_filters:domain/2, {log, sub, [minato]}}).
```

minato logs when something happened that nobody asked for and nobody will
otherwise see:

| level | event | why it is worth a line |
| --- | --- | --- |
| warning | `connect_failed` | a pool could not open a connection; carries `reason` and `retry_in_ms` |
| warning | `session_reset_failed` | a checkout closed a connection whose reset did not answer as sent: `reason` is `unread_answer` when the last borrower gave it back with answers unread, `sql_prepared_statement` when it left a statement prepared with SQL `PREPARE`, `in_transaction` or `failed` when the reset ended inside a transaction, otherwise the server's refusal by SQLSTATE `code` |
| warning | `listener_resubscribed` | a listener reconnected, which means notifications were missed - `NOTIFY` has no replay |
| info | `cached_plan_invalidated` | a schema change made PostgreSQL refuse a cached statement; minato recovered, but somebody ran a migration |
| info | `cached_statement_deallocated` | something on the session ran a SQL `DEALLOCATE` of a statement minato had cached; outside a transaction minato parsed it again |

Failures a caller can act on are **returned, not logged**. A statement with a
syntax error comes back as `{error, {pgsql_error, _}}` and stays out of the log,
because the caller is already dealing with it and a library that logs it too
produces a log full of things somebody has already handled.

## Numbers without a collector

`minato:stats/1` reads counters the pool keeps regardless of whether anything is
attached:

```erlang
#{size := 10, idle := 8, borrowed := 2, waiting := 0,
  checkouts := 148_233, waits := 41, timeouts := 0,
  disconnects := 3, retired := 96}
```

`waits` against `checkouts` is how often a caller found nothing free. `timeouts`
is how often one ran out of time, waiting or reading the reset. `disconnects` climbing is a pool losing connections -
the server closing them, or the application killing processes that hold them -
while `retired` is the pool closing them on purpose at `max_age`. They are
counted separately because one is a problem and the other is the pool working.

## Traces

The spans above are already the shape OpenTelemetry wants, so a bridge is one
module rather than a package. `opentelemetry_telemetry` keeps the span that a
`start` opened under the `telemetry_span_context` every event of the span
carries, and hands it back at `stop` or `exception`.

This is `test/minato_traces.erl` from the repository, whole. It is there, and
not in `src`, so that minato does not depend on OpenTelemetry; it is compiled
with the tests and `minato_traces_SUITE` runs it against the OpenTelemetry SDK
and a real server, and a test fails if this page and that file differ. Copy it
into your application under a name of your own:

```erlang
-module(minato_traces).
-moduledoc """
minato's `telemetry` spans as OpenTelemetry spans.

`attach/0` once, after `opentelemetry` has started. A statement, the checkout
it waited on and the connect behind a new connection each become a span, named
and described as the OpenTelemetry conventions for a database client ask. A
statement and its checkout run in the caller's process, so they are children
of whatever span the caller has open.

Needs `opentelemetry_api` and `opentelemetry_telemetry`.
""".

-export([attach/0, detach/0, handle/4]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(HANDLER, ~"minato-traces").
-define(ATTRIBUTES, [
    {database, 'db.namespace'},
    {port, 'server.port'},
    {pool, 'db.client.connection.pool.name'},
    {sql, 'db.query.text'}
]).

-spec attach() -> ok | {error, already_exists}.
attach() ->
    telemetry:attach_many(
        ?HANDLER,
        [
            [minato, Span, Stage]
         || Span <- [connect, query, checkout], Stage <- [start, stop, exception]
        ],
        fun ?MODULE:handle/4,
        undefined
    ).

-spec detach() -> ok | {error, not_found}.
detach() ->
    telemetry:detach(?HANDLER).

-spec handle([atom()], map(), map(), term()) -> ok.
handle([minato, Span, start], _Measurements, Metadata, _Config) ->
    _ = otel_telemetry:start_telemetry_span(?MODULE, name(Span, Metadata), Metadata, #{
        kind => kind(Span), attributes => attributes(Metadata)
    }),
    ok;
handle([minato, _Span, _Ended], _Measurements, Metadata, _Config) ->
    Ctx = otel_telemetry:set_current_telemetry_span(?MODULE, Metadata),
    _ = ended(Ctx, Metadata),
    otel_telemetry:end_telemetry_span(?MODULE, Metadata).

%% The statement is not known to be a SELECT until it has been answered, so a
%% query span starts under the name of its database and is renamed here.
ended(Ctx, #{outcome := ok, command := Command, database := Database}) ->
    Operation = iolist_to_binary(string:uppercase(operation(Command))),
    _ = otel_span:update_name(Ctx, <<Operation/binary, " ", Database/binary>>),
    otel_span:set_attributes(Ctx, #{'db.operation.name' => Operation});
ended(Ctx, #{reason := Reason}) ->
    _ = otel_span:set_attributes(Ctx, failure(Reason)),
    otel_span:set_status(Ctx, ?OTEL_STATUS_ERROR);
ended(_Ctx, _Metadata) ->
    true.

name(query, #{database := Database}) -> Database;
name(connect, _Metadata) -> ~"minato connect";
name(checkout, _Metadata) -> ~"minato checkout".

kind(checkout) -> ?SPAN_KIND_INTERNAL;
kind(_Span) -> ?SPAN_KIND_CLIENT.

attributes(Metadata) ->
    Named =
        #{Name => Value || {Key, Name} <- ?ATTRIBUTES, {ok, Value} <- [maps:find(Key, Metadata)]},
    addressed(Named#{'db.system.name' => ~"postgresql"}, Metadata).

addressed(Attributes, #{host := {local, _Path}}) ->
    Attributes;
addressed(Attributes, #{host := Host}) when is_tuple(Host) ->
    case inet:ntoa(Host) of
        {error, einval} -> Attributes;
        Address -> Attributes#{'server.address' => list_to_binary(Address)}
    end;
addressed(Attributes, #{host := Host}) when is_atom(Host) ->
    Attributes#{'server.address' => atom_to_binary(Host)};
addressed(Attributes, #{host := Host}) ->
    Attributes#{'server.address' => unicode:characters_to_binary(Host)};
addressed(Attributes, _Metadata) ->
    Attributes.

operation(Command) when is_atom(Command) -> atom_to_binary(Command);
operation(Command) when is_binary(Command) -> Command.

%% A server's refusal is known by its SQLSTATE. Anything else is known by what
%% kind of thing it is, never by its text, which can quote a value.
failure({pgsql_error, #{code := Code}}) ->
    #{'db.response.status_code' => Code, 'error.type' => Code};
failure({Kind, _Detail}) when is_atom(Kind) ->
    #{'error.type' => Kind};
failure(Reason) when is_atom(Reason) ->
    #{'error.type' => Reason};
failure(_Reason) ->
    #{'error.type' => '_OTHER'}.
```

What comes out, per statement:

| | |
| --- | --- |
| name | `SELECT minato_test`: the command and the database, once the statement has been answered; the database alone for one that failed |
| kind | `client`; `internal` for `minato checkout` |
| parent | the span open in the calling process, for a statement and its checkout |
| `db.system.name` | `postgresql` |
| `db.namespace` | the database |
| `db.operation.name` | `SELECT`, `INSERT` and so on, when it was answered |
| `server.address`, `server.port` | as the connection was asked to connect |
| `db.client.connection.pool.name` | the pool, when one holds the connection |
| `db.query.text` | the statement, only under `log_statements` |
| `db.response.status_code`, `error.type` | the SQLSTATE of a statement the server refused, with the span's status set to error |
| `error.type` | for anything else that failed, what kind of failure: `socket`, `minato_codec` |

No parameter and no row is in a span, and neither is the text of an error,
for the reasons under [What is never emitted](#what-is-never-emitted).

A `[minato, query]` span nested inside an application span is the picture worth
having: the request, the checkout it waited on, and the statement it ran, with
the gap between them visible. `[minato, checkout]` is what makes that picture
useful, because a request that spent 40 ms waiting for a connection and 2 ms
querying looks exactly like the reverse until the two are separate spans. A
`minato connect` span is made in the pool's process, where no request is, so
it starts a trace of its own unless the application connects itself.

## Health

`minato:health/1` borrows a connection and runs `SELECT 1`, both inside a
timeout:

```erlang
case minato:health(main, 1000) of
    ok -> ready;
    {error, _Reason} -> not_ready
end.
```

Use it as a **readiness** probe, not a liveness one. A pool that cannot reach
its database is not broken - it is waiting, and reconnecting with backoff while
it waits. Restarting the node for that turns a database outage into an outage of
everything else the node was doing.

## Connections that live too long

`max_age` in the pool options retires a connection when it is checked in older
than that, and opens a replacement. It is `infinity` by default: a connection to
PostgreSQL itself is good indefinitely, and churning connections is work nobody
asked for.

Set it when something sits in the middle. A proxy, a load balancer or a NAT has
idle and lifetime limits of its own, and a connection one of them cut is
discovered when a query fails on it. Retiring on your own schedule turns that
into a connection replaced quietly, counted as `retired` rather than
`disconnects`.

## Statements that run too long

`timeout` in the query options is a deadline on the statement, not just on the
read:

```erlang
minato:query(main, ~"SELECT slow(...)", [], #{timeout => 2000}).
```

When it expires minato cancels the statement on the server and reads the
cancellation through, so what comes back is `{error, {pgsql_error, #{code :=
~"57014"}}}` and the connection goes back to the pool. It defaults to the
connection's read timeout. In a dashboard those appear as ordinary failed
queries with SQLSTATE `57014`, and a rate of them is a query that needs looking
at rather than a client that needs restarting.

A `{error, {socket, timeout}}` after that is the other case: the server did not
acknowledge the cancellation within `cancel_timeout` either, so the connection
is closed and replaced, and `disconnects` goes up.

## What to alert on

- `timeouts` increasing at all. A checkout timeout is a request that failed
  before it reached the database.
- `[minato, checkout, stop]` p99 above a few round trips to the server. One
  round trip is the reset; beyond that, the pool is too small for the load, or
  connections are being held across something slow.
- `disconnects` increasing while nothing is deploying.
- `listener_resubscribed` at any rate above roughly never, on a system that
  treats `NOTIFY` as its wake-up: every one of those is a window where nothing
  woke up. Poll as well; the notification is an optimisation.
- `57014` appearing in `[minato, query, stop]` reasons. Every one is a statement
  that outlived its deadline and was cancelled; the connection survived, but
  somebody's query did not.
- `[minato, connect, stop]` with `outcome => error` in a steady state. The
  credentials, the certificate or the network changed.
