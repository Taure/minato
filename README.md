# minato

港 - harbour. Where connections dock and wait to be dispatched.

An independent Erlang client for PostgreSQL.

## Status

Early. The type codec layer exists; there is no connection, no pool and no
protocol yet, no published package, and no stable API. Do not depend on it.

## Codecs

`minato_codec` converts Erlang terms to PostgreSQL wire bytes and back, in both
the binary and the text wire format. It is pure: no I/O, no process, no state.

`bool`, `bytea`, `int2`, `int4`, `int8`, `float4`, `float8`, `numeric`, `text`,
`varchar`, `json`, `jsonb`, `uuid`, `date`, `time`, `timestamp`, `timestamptz`,
and the array of each.

```erlang
1> minato_codec:encode(23, 42, binary).
<<0,0,0,42>>
2> minato_codec:decode(1009, ~"{a,NULL,\"b,c\"}", text).
[<<"a">>,null,<<"b,c">>]
```

The contracts worth knowing before reading the module documentation:

- `null` is the NULL sentinel in both directions and the only one. NULL has no
  bytes on the wire, so `encode/4` returns the atom `null` and the caller writes
  a length of -1.
- `jsonb` is a JSON document as bytes, never a parsed term. The codec does not
  contain a JSON parser and never will.
- `numeric` decodes to an exact decimal binary such as `~"123.4500"`, never to a
  float, and keeps its display scale. `NaN`, `Infinity` and `-Infinity` are the
  atoms `nan`, `infinity` and `neg_infinity`.
- `timestamptz` decodes to `{{Y,M,D},{H,Mi,S}}` with sub-second precision
  floored away, or losslessly to microseconds since the Unix epoch under
  `datetime_format => microseconds`.
- `uuid` decodes to the 36 character form by default and to the raw 16 bytes
  under `uuid_format => binary`. Encoding accepts either, and 32 hex characters.
- Arrays are lists. Encoding writes one dimension; decoding reads any number and
  nests.
- A type minato has no codec for still works in the text format, which is what
  makes the text path worth having beyond parity.

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
