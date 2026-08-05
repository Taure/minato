# minato

港 - harbour. Where connections dock and wait to be dispatched.

An independent PostgreSQL client for Erlang.

## Status

Early, and usable end to end: codecs, protocol, authentication with channel
binding, TLS, connections, queries, transactions, a pool, `LISTEN`/`NOTIFY`,
telemetry and logs. Nothing runs on it in production yet, and the API is not
stable. Read [the design guide](guides/design.md) before depending on it.

## Install

```erlang
{deps, [{minato, "~> 0.1"}]}.
```

```erlang
{ok, _Pid} = minato:start_pool(main, #{
    size => 10,
    connection => #{host => "localhost", user => ~"minato",
                    password => ~"minato", database => ~"minato_test"}
}),

{ok, #{rows := [{42}]}} = minato:query(main, ~"SELECT $1::int4", [42]),

{ok, done} = minato:transaction(main, fun(Conn) ->
    {ok, _Result, Written} = minato_query:query(Conn, ~"INSERT INTO t VALUES ($1)", [1]),
    {ok, done, Written}
end).
```

[Getting started](guides/getting-started.md) is the ten minute version.

## What is different about it

- **A slow query costs a query, not a connection.** When a statement passes its
  deadline minato sends `CancelRequest` and reads the cancellation through, so
  the answer is the server's own `57014` and the connection goes back to the
  pool. A read timeout on its own can only end the wait: the server carries on
  running the query and the connection is left with an answer coming that nobody
  will read.
- **A `COMMIT` the server turns into a `ROLLBACK` is reported as one.**
  PostgreSQL answers `COMMIT` with `ROLLBACK` when the transaction had already
  failed. Nothing was written, and a client that reads only "the COMMIT
  completed" reports success for work that was thrown away - which is how a job
  queue runs a job twice.
- **The SCRAM exchange is bound to the TLS session.** `SCRAM-SHA-256-PLUS` with
  `tls-server-end-point`, on by default under TLS. Without it a man in the middle
  holding a certificate you accept can relay the whole exchange and keep the
  session, without ever learning the password.
- **TLS has no `prefer` mode.** A server that declines is refused, because
  declining is the one message an attacker on the connection can always produce.
- **Result sets are framed in bulk.** One read with the remainder carried
  forward, never a header read then a payload read: 61 reads over 5000 rows
  rather than 10,006. See [the benchmark](bench/README.md).

## Guides

- [Getting started](guides/getting-started.md) - pool, query, transaction, listen
- [Configuration](guides/configuration.md) - every option, its default, and why
- [Types](guides/types.md) - what a value comes back as, and what happens to a
  type minato has no codec for
- [Security](guides/security.md) - TLS, channel binding, credentials, and what
  never reaches a log
- [Observability](guides/observability.md) - the events, the logs, and what to
  alert on
- [Design](guides/design.md) - the four decisions everything else follows from

## Testing

`rebar3 eunit` needs nothing installed: unit tests and PropEr round trips for
every type in both wire formats, byte for byte tests of every protocol message
against the documented format, framing properties that cut a stream at every
byte and require it back whole, and SCRAM tampering properties stated over every
byte position rather than as a few examples. The protocol round trips do not
compare an encoder against itself: frontend messages are read back by a separate
reader written from the same documentation, and backend messages are built by a
separate writer.

`rebar3 ct` needs a PostgreSQL:

```
docker compose -f test/docker-compose.yml up -d
rebar3 ct
docker compose -f test/docker-compose.yml down -v
```

- **differential** - every type against `pg_types` as a black box oracle *and*
  against PostgreSQL 17 as the judge, in both wire formats
- **round trip** - the same corpus through minato's own connection and pool, as
  a bound parameter and as a column of a real table
- **properties** - result sets of any size, any number of parameters, nulls in
  any position, UTF-8 of any content, `bytea` of any size, tuples against maps,
  prepared against unprepared
- **authentication** - the whole SASL exchange over a real socket, including
  recomputing the verifier PostgreSQL stored in `pg_authid`
- **TLS** - a verified handshake against a second server with `ssl=on`, whose
  certificate authority it generates at start up so no key is in this
  repository, a certificate for another host refused, and `pg_stat_ssl` asked
  whether the session is really encrypted
- **soak** - concurrent workers checking their own answers, with backends killed
  underneath them, and the pool measured at rest afterwards

CI runs all of it on OTP 28 and 29.

## Requirements

Build and test on OTP 28 or later. OTP 29 is the intended floor for released
versions; the `minimum_otp_vsn` gate reads `28` because the pre-push checklist
runs `elp lint` and `elp eqwalize-all` and ELP publishes no OTP 29 binary.

## Prior art

minato is an independent implementation. It contains no code from any other
project and is not a fork of one. Wire formats are taken from the PostgreSQL
documentation and the documented binary send and receive representations, not
from any existing client.

These projects were studied as architecture and are acknowledged as influences:
[pgo](https://github.com/erleans/pgo), [epgsql](https://github.com/epgsql/epgsql),
[Postgrex](https://github.com/elixir-ecto/postgrex),
[asyncpg](https://github.com/MagicStack/asyncpg) and
[pgx](https://github.com/jackc/pgx).

[pg_types](https://github.com/erleans/pg_types) and
[pgo](https://github.com/erleans/pgo) are test profile dependencies only:
`pg_types` as a differential oracle, `pgo` as a transport that carries minato's
bytes to a real server. Neither is shipped at run time and neither is read as a
source of implementation.

## Licence

Apache-2.0. Copyright 2026 Widgrens IT AB (org.nr 559241-2752). See
[LICENSE](LICENSE).
