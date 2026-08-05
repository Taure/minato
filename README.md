# minato

港 - harbour. Where connections dock and wait to be dispatched.

An independent Erlang client for PostgreSQL.

## Status

Early, but usable end to end: codecs, protocol, authentication with channel
binding, TLS, connection, queries, transactions, a pool and LISTEN/NOTIFY. There is no published package and no stable
API, and nothing runs on it in production yet. Do not depend on it.

## Using it

```erlang
{ok, _Pid} = minato:start_pool(main, #{size => 10,
                                       connection => #{host => "localhost",
                                                       user => ~"minato",
                                                       password => ~"minato",
                                                       database => ~"minato_test"}}),
{ok, #{rows := [{42}]}} = minato:query(main, ~"SELECT $1::int4", [42]),

{ok, done} = minato:transaction(main, fun(Conn) ->
    {ok, _Result, Written} = minato_query:query(Conn, ~"INSERT INTO t VALUES ($1)", [1]),
    {ok, done, Written}
end).
```

Pools can be declared in the application environment instead, for an application
that wants its pool up before anything asks for one:

```erlang
{minato, [{pools, #{main => #{size => 10, connection => #{user => ~"minato"}}}}]}
```

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

`SCRAM-SHA-256-PLUS` is implemented, with `tls-server-end-point` binding. Under
TLS the hash of the server's certificate goes into the `c=` field of
`client-final-message`, which the `ClientProof` covers, so the exchange is tied
to the TLS session it happened on. Without that, SCRAM proves a shared password
over whatever channel the client is on, and a man in the middle holding a
certificate the client accepts can relay the entire exchange and keep the
session.

`channel_binding` is `prefer` under `ssl => true` and `disable` on a plain
socket, where there is nothing to bind to. `require` refuses to connect unless
the server offers `-PLUS`. A client that can bind but is talking to a server
that did not offer it sends `y,,`, which is how a server that does support
binding detects the mechanism list being stripped in transit.

The hash is taken with the algorithm the certificate was signed with, as RFC
5929 says and as PostgreSQL computes it; SHA-1 and MD5 signatures are hashed
with SHA-256 instead, because the binding must not be weaker than the mechanism
it binds.

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

## Queries

`minato_query` runs SQL on a connection, in both of the protocol's query paths.

```erlang
{ok, #{rows := [{42}]}, Conn1} = minato_query:query(Conn, ~"SELECT $1::int4", [42]),
{ok, Statement, Conn2} = minato_query:prepare(Conn1, ~"by_id", ~"SELECT * FROM t WHERE id = $1"),
{ok, Result, Conn3} = minato_query:execute(Conn2, Statement, [7]).
```

- **Parameter types are the server's to decide.** `Describe` is answered before
  the parameters are encoded, so nothing is guessed from the shape of an Erlang
  term. That is two round trips for a one-off query and one for a prepared
  statement, which is what `prepare/3` is for.
- **Formats are chosen per column.** `binary` for every type minato has a codec
  for and `text` for the rest, so a column of an extension type still arrives
  rather than failing the query. The `RowDescription` a `Describe` returns says
  text for every column, because formats are not chosen until `Bind`; minato
  replaces those with what it asked for before decoding.
- **A failed statement leaves the connection usable.** The error tuple carries
  the connection back, read on to `ReadyForQuery`, because a driver that returns
  an error and a dead connection turns one bad statement into a dead pool. A
  connection that is *not* usable is not handed back at all: `{error, {socket,
  _}}` has no connection in it.
- **A statement is parsed once per connection.** `minato:query/3` goes through
  `minato_query:cached/4`, which keeps the parsed statement on the connection it
  used, so the same SQL costs one round trip after the first on each connection
  in the pool rather than two every time. The cache is bounded by
  `prepared_statements` (64 by default, 0 to turn it off), and a connection that
  is full runs anything new unnamed, so unbounded distinct SQL gets the uncached
  path rather than an unbounded pile of parsed statements in the backend.
- **A schema change under a cached plan is recovered, not returned.** Altering a
  table makes PostgreSQL refuse the statement it planned with `0A000`, which is
  not something a caller can act on; the statement is closed, parsed again and
  run once more. A second `0A000` is a real failure.
- **`simple/2` has no parameters.** The simple query protocol has nowhere to put
  them, and a value pasted into SQL is an injection waiting to be found.

## Transactions

`minato_txn` runs a function inside `BEGIN` and `COMMIT`.

```erlang
{ok, Value, Conn1} = minato_txn:transaction(Conn, fun(Open) ->
    {ok, _Result, Written} = minato_query:query(Open, ~"INSERT INTO t VALUES ($1)", [1]),
    {ok, done, Written}
end).
```

`{rollback, Reason, Conn}` rolls back and reports `Reason`; an exception rolls
back and is re-raised, so nothing can leave the connection holding an open
transaction. `savepoint/2` and `rollback_to/2` are the nested case, because SQL
has no nested `BEGIN` and a client that pretended otherwise would report a
rollback the server never did.

The case the module exists for is a `COMMIT` the server turns into a `ROLLBACK`.
PostgreSQL does that whenever the transaction had already failed: nothing is
written, and a client that reads "the COMMIT completed" reports success for work
the server threw away, which is how a job queue runs a job twice. `commit/1`
compares the tag it got with the statement it sent and answers `{error,
transaction_rolled_back, Conn}`.

`status/1` reports what the server last said: `idle`, `transaction`, or `failed`
for a transaction where a statement has already errored and everything further
is rejected until it is rolled back.

## Pool

`minato_pool` holds connections and lends them; it does not run queries. That
follows from the caller owning the socket: a pool that ran the query would be one
process serialising every caller again. `checkout/2` hands over the socket along
with the connection, `checkin/2` hands it back, and `m:minato` wraps both.

- **A pool is up before it has connections.** They are opened in the background
  and retried with backoff, so an application that starts before its database
  starts anyway and the first query waits rather than a supervisor giving up.
- **A borrower that dies is noticed.** The socket belongs to the process holding
  it, so a dead borrower means a dead connection; the pool's monitor fires and a
  replacement is opened.
- **A connection checked in mid-transaction is rolled back** before it is lent
  again, and closed if that fails. The alternative is the next borrower silently
  joining a transaction it did not open.
- **A caller that gives up waiting is removed from the queue**, rather than being
  handed a connection nobody is waiting for.
- **A connection can be handed to another process.** `minato:give_away/3` moves
  the socket and the pool's monitor together, so a connection can outlive the
  process that borrowed it when that is what was meant, and the pool watches
  whoever holds it now. The connection term is the caller's to send on.
- **The queue is a plain FIFO for now.** A CoDel queue is what belongs here, and
  it needs a load to measure against before it is worth writing.

`stats/1` reports what the pool holds and what it has done, counted with
`counters`: checkouts, waits, timeouts and disconnects.

## Notifications

`minato_listener` holds a connection of its own and `LISTEN`s on it, because
`LISTEN` is session state: on a pooled connection the notification would be
delivered to whichever caller happened to hold it next, which is to say nowhere.

```erlang
{ok, _Pid} = minato:start_listener(events, #{connection => #{user => ~"minato"}}),
ok = minato:listen(events, ~"job_ready"),
receive
    {minato_notification, ~"job_ready", Payload, _From} -> Payload
end.
```

Subscribing is per process and the process is monitored, so a subscriber that
dies is dropped and a channel nobody is left listening to is `UNLISTEN`ed.
Channel names are quoted, not interpolated.

The part worth reading twice: **a connection that drops takes its subscriptions
with it, and whatever was published while it was away is gone.** `NOTIFY` is
fire and forget and has no replay. The listener reconnects with backoff,
`LISTEN`s again for every channel that still has a subscriber, and then sends
each subscriber `{minato_listener, Name, resubscribed}` - which is a consumer's
cue to go and look, because it missed something. Treat `NOTIFY` as a hint that
makes a poll faster, never as the only path.

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

`rebar3 ct` runs the differential suite for the codecs, the authentication
suite, the connection, query, transaction, pool, listener and soak suites, all
of which need a PostgreSQL:

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

### Round trips and properties

`minato_roundtrip_SUITE` runs the same corpus the codec differential suite uses -
every type, fixed cases and generated ones - through minato's own connection,
parameters and pool rather than through `pgo`. Each value goes out as a bound
parameter and comes back as a decoded row, both as `SELECT $1::type` and as an
`INSERT ... RETURNING`, because a value can survive the parameter path and still
be wrong through a column.

`minato_prop_SUITE` asks the questions that are about shape rather than value,
against the real server: a result set of any size, any number of parameters,
nulls in any position, UTF-8 of any content, a `bytea` of any size, the same
query as tuples and as maps, a prepared statement against an unprepared one, and
a refused statement followed by a working one. Shape is where a protocol client
goes wrong - framing is fine until a result set spans enough reads, a parameter
list is fine until it is longer than the one in the test. `MINATO_PROP_TESTS`
sets how many times each property runs; the default is CI-small.

### Soak

`minato_soak_SUITE` runs concurrent workers against a pool for a bounded time,
each checking its own answers: a `SELECT` that has to return the row that worker
just wrote, which fails if a connection is ever handed out with somebody else's
bytes on it. Then it measures the pool at rest - every connection back, none
borrowed, nobody waiting - because a driver that loses one connection per
thousand operations looks perfect in a unit test.

One case kills backends underneath the load with `pg_terminate_backend` and
requires the pool to refill and keep answering. The default run is short enough
for CI; `MINATO_SOAK_SECONDS` makes it as long as you want, and the number to
run before believing anything is minutes.

It has already earned its place: it found a connector that crashed when the
socket handover failed, and a transaction API with no way for the caller to say
"the connection is gone".

### TLS

`minato_tls_SUITE` runs against a second server in the compose file with
`ssl=on`, using the CA and certificate in `test/certs` (generated for these
tests, valid for ten years). Every other suite can only prove the failure path -
that minato refuses to continue when a server declines TLS - and this proves the
one that matters: a handshake that completes, a certificate verified against a
CA, a hostname that is checked, a certificate for another host that is refused,
and a working session afterwards, including a megabyte value and five thousand
rows through the record layer.

The server is the judge of whether the session is encrypted: the suite asks
`pg_stat_ssl` rather than believing the client. Channel binding is proved the
same way - `channel_binding => require` only connects if PostgreSQL negotiated
`SCRAM-SHA-256-PLUS` and accepted the certificate hash the client bound to.

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
