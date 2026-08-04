# minato

港 - harbour. Where connections dock and wait to be dispatched.

An independent Erlang client for PostgreSQL.

## Status

Early. The type codec layer, the protocol layer, authentication and the
connection exist; there is no query API, no pool, no published package and no
stable API. Do not depend on it.

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
read, which costs two reads per row: over a 5000 row result set that is 61 reads
against 10,006, and 5.3 to 9.1 times less wall clock. `minato_framer_bench` runs
both and prints the table.

- `decode/1` answers `incomplete` for a buffer that stops anywhere short of a
  whole message, so carry-over is always safe. A message that is entirely
  present and still malformed raises, because the server contradicted itself.
- Framing is total. Arbitrary bytes either frame or raise minato's own
  exception, never something the far end chose, and a declared length above
  `max_message_length` is refused at the header rather than accumulated.
- The remainder is copied when it is a small slice of a large buffer, so a three
  byte partial header does not hold a 64 KiB read alive across an idle
  connection. Column bytes are not copied, because that is what makes framing a
  large result set cheap; a value kept beyond the query is the caller's to copy.
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

## Authentication

`minato_auth` answers the server's `Authentication` messages, and `minato_scram`
is SCRAM-SHA-256 (RFC 5802, RFC 7677) underneath it. Both are pure: the caller
owns the socket here too.

```erlang
State = minato_auth:init(#{user => ~"minato", password => ~"pencil"}),
{send, Reply, Next} = minato_auth:step(Message, State),
```

SCRAM-SHA-256 is the one that matters. It is what `password_encryption` has
defaulted to since PostgreSQL 14 and the only thing CloudNativePG issues. MD5
and cleartext are also answered, because a PostgreSQL is not always a recent
one.

- **The server is authenticated too.** `server-final-message` carries a
  `ServerSignature` only a holder of `ServerKey` can produce, and minato
  recomputes it and compares in constant time. A mismatch raises and there is no
  option to turn the check off. Skipping it is a downgrade to no server
  authentication at all.
- **The server nonce must extend the client nonce.** A server that does not echo
  the client's nonce as a prefix of its own has not seen the client's first
  message, which is what a replay looks like, and is rejected.
- **A started exchange has to finish.** `AuthenticationOk` is refused while SCRAM
  is outstanding, and so is a demand for a cleartext or MD5 password part way
  through one. Both are how a man in the middle who cannot produce a
  `ServerSignature` would try to get round having to. Asking for cleartext in the
  first message is still answered, because that is what supporting cleartext
  means; choosing which methods are acceptable at all is a `require_auth` style
  option that belongs with the connection layer next to TLS.
- **The iteration count is bounded at both ends.** The floor is 4096, which is
  what RFC 7677 says a server should announce and what `scram_iterations`
  defaults to. The ceiling is 1,000,000, because `i` is an unbounded number
  chosen by the far end and fed into a loop, and without one a server answering
  `i=2000000000` costs minutes of CPU per connection attempt.
- **Nonces come from `crypto:strong_rand_bytes`**, 24 bytes base64 encoded,
  never from `rand`.
- **The state holds no password.** Nothing derived from one survives the call
  that uses it either: what is carried to the last step is the expected
  `ServerSignature`, which the server is about to send in the clear anyway.

SASLprep (RFC 4013) is applied to the password, as far as OTP goes. Mapping,
NFKC and all ten prohibited output tables are implemented. The bidirectional
check of RFC 3454 section 6 is not, because OTP publishes no bidirectional
category table, and neither is the unassigned code point check, which is defined
against Unicode 3.2 specifically. `minato_saslprep` documents both gaps and the
tests assert the behaviour rather than omitting the cases. A password that
cannot be prepared falls back to its raw bytes, which is what PostgreSQL
documents itself as doing when it stores the verifier, so the two agree.

`SCRAM-SHA-256-PLUS` is not implemented. The client advertises `n,,`: no channel
binding. That is the honest flag for a client that cannot do it, and it leaves
the exchange open to a man in the middle holding a certificate the client will
accept. Channel binding needs the server certificate from the TLS session, so it
belongs with the connection layer. No Erlang client has it, which makes it a
real differentiator rather than a box to tick.

## Connection

`minato_conn` opens a connection: TCP, optionally TLS, the startup message,
authentication, and then the parameters and the `BackendKeyData` the server
volunteers. It answers once `ReadyForQuery` has arrived, so a connection that is
returned is one that can be used.

```erlang
{ok, Conn} = minato_conn:connect(#{host => "127.0.0.1", port => 5432,
                                   user => ~"minato", password => ~"minato",
                                   database => ~"minato_test"}),
minato_conn:parameter(Conn, ~"server_version").
```

There is no connection process. The socket is `{active, false}` and belongs to
the process that opened it, which is the caller ownership the design section
describes: a query is a send and a read on the caller's own scheduler slot
rather than a message to a `gen_server` that puts every caller behind the
slowest one. `next/1` returns the next message and the connection to carry on
from, because bytes that arrived but have not been read yet live in the
connection.

- **TLS has no `prefer` mode.** `ssl => true` refuses to continue when the
  server answers that it will not do TLS. Continuing in the clear on being
  declined is a downgrade an attacker on the connection can always ask for, since
  declining is the one message they are able to produce. Verification is on by
  default, against the OS trust store and with the hostname checked, and
  `server_name_indication` is set, which OTP needs told explicitly on a socket
  upgrade.
- **A cleartext password is refused on a plain socket.** The password opens
  every future connection too, so handing it to whoever is on the wire is worse
  than failing to connect. `auth => [Method]` narrows what is acceptable
  further, down to SCRAM alone.
- **The password is never held.** It is read, used, and left out of the
  connection, so a pool holding a thousand connections holds no copies of it. A
  `fun(() -> binary())` is accepted and called once per attempt, which is what a
  rotating credential needs.
- **`CancelRequest` works**, because `BackendKeyData` is kept. Cancelling opens
  a second connection, which is the only way the protocol offers to interrupt a
  query: the connection running it is busy.
- **Every read passes a timeout.** A read that times out leaves an unknown
  number of bytes still to come, so the connection is finished rather than
  retried: recovering would mean knowing how far through a message the far end
  got, which is what the timeout says we do not know.

## Testing

`rebar3 eunit` needs nothing installed: unit tests and PropEr round trips for
every type in both wire formats, byte for byte tests of every protocol message
against the documented format, and framing properties that cut a stream at every
byte and require it back whole.

The RFC 7677 vectors are used verbatim, and the SCRAM properties run the client
against a server half written from the same RFC, so agreement is between two
readings rather than one implementation and itself. The properties that matter
most are the tampering ones: changing any byte of any message in the exchange
has to break it, stated over every byte position rather than as a few examples.

The protocol round trips do not compare an encoder against itself. Frontend
messages are read back by a separate reader written from the same documentation,
and backend messages are built by a separate writer, so a length field only one
of the two believes in fails the property rather than cancelling out.

`rebar3 ct` runs the differential suite for the codecs and the authentication
suite, both of which need a PostgreSQL:

```
docker compose -f test/docker-compose.yml up -d
rebar3 ct
docker compose -f test/docker-compose.yml down -v
```

The authentication suite completes the whole SASL exchange against the container
over a real socket, then uses the session it opened. It also reads the verifier
PostgreSQL stored in `pg_authid` and recomputes it, which checks `StoredKey` and
`ServerKey` against the server's own PBKDF2 rather than against a second reading
of the RFC, and it sets `scram_iterations` to 1 for one role so that the
iteration count floor is proved against a server that really does announce a
weak one.

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
