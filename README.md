# minato

港 - harbour. Where connections dock and wait to be dispatched.

An independent Erlang client for PostgreSQL.

## Status

Early. The repository is scaffolding only: there is no client yet, no published
package, and no stable API. Do not depend on it.

## Requirements

Build and test on OTP 28 or later.

OTP 29 is the intended support floor for released versions. The `minimum_otp_vsn`
gate in `rebar.config` reads `28` because the pre-push checklist runs `elp lint`
and `elp eqwalize-all`, and ELP publishes no OTP 29 binary. Declaring 29 makes
`rebar3 compile` abort under the OTP 28 toolchain ELP needs, which takes the type
checker offline. The code is therefore written against OTP 28 features only and
CI runs the test matrix on both 28 and 29. The gate moves to 29 when ELP ships an
OTP 29 build.

## Design

- The caller owns the socket on the query path. A single owning process is an
  unpreemptable FIFO queue, because the PostgreSQL protocol is FIFO per
  connection: one slow query stalls every other caller. Caller ownership also
  gives session pinning, which transactions, advisory locks and `SET ROLE` all
  need.
- Bulk framing. One `recv` with buffer carry-over, never a header read followed
  by a payload read. Measured at 5.23x faster over 1000 rows and 12.78x over
  5000.
- The protocol codec is a pure module. Bytes in, terms out, no I/O and no
  process, so it is exhaustively testable without a database.
- Metrics through `counters` and `atomics` from the start rather than retrofitted.

## Prior art

minato is an independent implementation. It contains no code from any other
project and is not a fork of one.

Wire formats are taken from the PostgreSQL documentation and the documented
binary send and receive representations, not from any existing client.

These projects were studied as architecture and are acknowledged as influences on
the design decisions above: [pgo](https://github.com/erleans/pgo),
[epgsql](https://github.com/epgsql/epgsql),
[Postgrex](https://github.com/elixir-ecto/postgrex),
[asyncpg](https://github.com/MagicStack/asyncpg) and
[pgx](https://github.com/jackc/pgx).

[pg_types](https://github.com/erleans/pg_types) is used at test time only, as a
differential oracle to compare encoded and decoded values against. It is a test
profile dependency, it is never shipped as a runtime dependency, and it is not
read as a source of implementation.

## Licence

Apache-2.0. Copyright 2026 Widgrens IT AB (org.nr 559241-2752). See
[LICENSE](LICENSE).
