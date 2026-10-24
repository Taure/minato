# Design

Four decisions the rest of the client follows from, and what each one costs.

## The caller owns the socket

There is no connection process. A connection is a term the calling process
holds, the socket is `{active, false}` and belongs to that process, and a query
is a send and a read on the caller's own scheduler slot.

The alternative - a `gen_server` per connection, which is what most clients do -
makes that process an unpreemptable FIFO queue. The PostgreSQL protocol is
already FIFO per connection, so a slow query blocks every other caller of that
process, and no timeout on the caller's side can take the connection back
because the connection is not theirs to take. Caller ownership also gives
session pinning for free, and transactions, advisory locks, `SET ROLE` and
`LISTEN` all need that to be correct rather than merely fast.

What it costs: the connection is threaded through every call, because the bytes
that arrived and have not been read yet live in it. `{ok, Result, Conn}` rather
than `{ok, Result}` is the price, and `m:minato` hides it for the ordinary case.

## Bulk framing

One `recv` with the remainder carried forward, never a five byte header read
followed by a payload read.

Header-then-payload is two reads per message and scales with the number of rows.
Reading whatever has arrived and framing every complete message in it reads a
result set in a handful of calls: over 5000 rows, 61 reads against 10,006. The
[benchmark](https://github.com/Taure/minato/tree/main/bench) puts numbers on
what that is worth against a client that does it the other way.

What it costs: `frame/1` has to be able to say "not yet" at any byte boundary,
and the remainder has to be handled carefully - a three byte partial header must
not hold a 64 KiB read alive across an idle connection, so a small remainder is
copied and a large one is not.

## The protocol layer is pure

Bytes in, terms out. No I/O, no process, no state, in the codecs, the message
encoder and decoder, and the authentication exchange.

That is what makes the awkward parts testable without a database: every type in
both wire formats, every message byte for byte, framing properties that cut a
stream at every byte and require it back whole, and SCRAM tampering properties
stated over every byte position rather than as a few examples. A protocol bug
that only appears against a real server is a bug you find at three in the
morning.

What it costs: a layer that does nothing on its own, and a connection layer that
has to carry state the pure layer refuses to.

## Metrics from the start

`counters` in the pool and `telemetry` spans on the paths that can be slow,
written when each was written rather than retrofitted.

Instrumentation added afterwards measures what was easy to reach, which is
rarely what you need. The one that would not have survived retrofitting is the
checkout span: its duration is time spent **getting a connection**, waiting for
one and then reading the answer to its session reset, which separates a slow
database from a pool that is too small - two problems that look identical in a
query latency graph.

What it costs: one dependency, and an event on the hot path that does nothing
when nothing is attached.

## What this is not

- **Not a driver for every PostgreSQL feature.** No `COPY`, no replication
  protocol, no cursors beyond a whole result set. They are absent, not hidden
  behind an error.
- **Not multi-node aware.** No failover, no read replicas, no topology
  discovery. A pool points at a server; something above it decides which server.
- **Not an ORM, and not underneath one yet.** It returns rows.
