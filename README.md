# minato

港 - harbour. Where connections dock and wait to be dispatched.

An independent Erlang client for PostgreSQL.

## Status

Early. The type codec layer and the protocol layer exist; there is no
connection, no pool, no published package and no stable API. Do not depend on
it.

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

## Protocol

`minato_protocol` encodes the messages a client sends and decodes the messages a
server sends. It is pure in the same way the codecs are: bytes in, terms out, no
socket and no process.

```erlang
1> iolist_to_binary(minato_protocol:encode({execute, ~"", 0})).
<<69,0,0,0,9,0,0,0,0,0>>
2> minato_protocol:frame(<<49,0,0,0,4, 50,0,0,0,4, 51,0,0>>).
{[parse_complete,bind_complete],<<51,0,0>>}
```

`frame/1` is the shape that matters. It takes whatever bytes have arrived,
returns every complete message in them, and hands back the remainder to be
prepended to the next read. Not a five byte header read followed by a payload
read, which costs two system calls per row.

- `decode/1` answers `incomplete` for a buffer that stops anywhere short of a
  whole message, so carry-over is always safe. A message that is entirely
  present and still malformed raises, because the server contradicted itself.
- `BackendKeyData` is kept. It is the whole of what `CancelRequest` needs, and a
  client that throws it away cannot cancel a query for the life of the
  connection.
- `ErrorResponse` is data, not an exception. Every documented field is decoded
  into a map with atom keys and binary values, and `code` is the SQLSTATE.
- `CommandComplete` parses to `{Command, Count}`: `{select, 5}`, `{insert, 3}`
  from the two-number form, `{'begin', undefined}` where there is nothing to
  count, `{create, table}` for a tag that names its object. The count is an
  integer or an atom, and the type says so.
- `DataRow` carries raw column bytes, because it cannot be read without the
  `RowDescription` that preceded it. `row/3` takes that description as an
  argument and decodes through `minato_codec`, as tuples or as maps.
- A message minato does not model decodes to `{unsupported, Type, Payload}`
  rather than raising, because every backend message is length prefixed and
  losing the stream is worse than not understanding one message.

## Testing

`rebar3 eunit` needs nothing installed: unit tests and PropEr round trips for
every type in both wire formats, byte for byte tests of every protocol message
against the documented format, and framing properties that cut a stream at every
byte and require it back whole.

The protocol round trips do not compare an encoder against itself. Frontend
messages are read back by a separate reader written from the same documentation,
and backend messages are built by a separate writer, so a length field only one
of the two believes in fails the property rather than cancelling out.

`rebar3 ct` runs the differential suite for the codecs, which needs a
PostgreSQL:

```
docker compose -f test/docker-compose.yml up -d
rebar3 ct --suite test/minato_differential_SUITE
docker compose -f test/docker-compose.yml down -v
```

It compares every type against two independent references. `pg_types` is a
black box oracle: minato's encoding must be byte identical to it, and the two
must decode the same bytes to the same value. PostgreSQL 17 is the judge: the
suite puts minato's own bytes on the wire, so the server parses them with its
`recv` function and answers with its `send` function, and the round trip has to
come back unchanged in both wire formats. The corpus is a hand written table of
awkward values plus a seeded generator, and a disagreement is written down in
the suite with which implementation is right rather than skipped.

CI runs it on every pull request, on OTP 28 and 29, against the same container.

Point it at another server with `MINATO_PG_HOST`, `MINATO_PG_PORT`,
`MINATO_PG_DATABASE`, `MINATO_PG_USER` and `MINATO_PG_PASSWORD`. It skips rather
than fails when nothing answers. `MINATO_DIFF_SCALAR_CASES` and
`MINATO_DIFF_ARRAY_CASES` set how many values are generated per type.

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

[pg_types](https://github.com/erleans/pg_types) and
[pgo](https://github.com/erleans/pgo) are used at test time only:
`pg_types` as a differential oracle to compare encoded and decoded values
against, `pgo` as the transport that carries minato's bytes to a real server.
Both are test profile dependencies, neither is shipped as a runtime dependency,
and neither is read as a source of implementation.

## Licence

Apache-2.0. Copyright 2026 Widgrens IT AB (org.nr 559241-2752). See
[LICENSE](LICENSE).
