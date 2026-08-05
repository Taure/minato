# Benchmarks

minato against the other Erlang PostgreSQL clients, and against the clients
people use from Node and Python, on the same workloads.

```
docker compose -f test/docker-compose.yml up -d
bench/run.sh 2000
```

The Erlang clients always run. The JavaScript ones need `cd bench/js && npm
install`, and the Python ones need `asyncpg` and `psycopg[binary]` importable;
the runner says which it skipped rather than leaving them silently out.

`pgo` here is `erleans/pgo` from Hex, not the fork this repository pins as a
test transport.

## What is being measured, and what is not

A client benchmark against a database on the same machine measures the client.
The server does the same work for everybody, so what is left is round trips,
framing, decoding, and whatever each client does in between. It says nothing
about how fast PostgreSQL is, and nothing about a network with a real round trip
time, where every one of these numbers converges on the network.

- `simple` - the simple query protocol. One message out, nothing to bind.
  `pgo` has no simple path.
- `unnamed` - the extended protocol with nothing kept: parse, describe, bind,
  execute, sync, every time. `pgo` caches statements and cannot be asked not to.
- `cached` - the same statement kept per connection, which is what every client
  here does by default. **This is the comparison that matters**, and every row
  below it is run the same way.
- `rows_1000`, `rows_5000` - a result set that spans many reads, which is where
  framing shows up.
- `wide_row` - one row of 64 columns: decoding rather than framing.
- `insert` - the server does real work, so the client's share shrinks.
- `concurrent` - eight callers at once, one connection each.

Every client gets the same statement, the same parameters, the same iteration
count and a warmup that is thrown away. Timings are per operation. The median
and the 99th percentile are given as well as the mean, because a mean hides the
tail.

**Numbers move with the machine.** What is worth reading is the ratio between
clients in the same run, and anything under about ten percent is noise.

## A run

2000 iterations, OTP 29, PostgreSQL 17 in Docker on the same machine, times in
microseconds per operation.

| workload | minato | epgsql | pgo | node-postgres | postgres.js |
| --- | --- | --- | --- | --- | --- |
| simple | **313** | 337 | - | 354 | 384 |
| unnamed | 612 | 678 | - | **401** | 711 |
| cached | 342 | **307** | 436 | 374 | 384 |
| rows_1000 | 834 | **589** | 3842 | 905 | 745 |
| rows_5000 | 2248 | **1806** | 16076 | 2257 | 2197 |
| wide_row | 381 | **380** | 646 | 457 | 444 |
| insert | 378 | 350 | 471 | **310** | 346 |
| concurrent | 913 | 1501 | 1226 | 877 | **828** |

What the numbers say:

- **Bulk framing is worth what it claimed.** `pgo` reads a header and then a
  payload per message, and at 5000 rows it costs 16 ms against everybody else's
  2 ms. That is the one enormous difference in the table, and it is the
  difference this client was written around.
- **epgsql is fast, and faster than minato on row-heavy reads.** 589 us against
  834 at a thousand rows. epgsql has had fifteen years of tuning and it shows;
  the gap is worth chasing and there is now a number to chase it against.
- **Describing before binding costs a round trip**, which is what the `unnamed`
  row is: 612 us against 342 for the same query cached. That is the price of not
  guessing parameter types, and `minato:query/3` pays it once per connection
  rather than once per call.
- **The Node clients are not slower than the BEAM ones.** Anybody expecting a
  scripting language to lose here should look at `insert` and `concurrent`
  again. Most of a query's cost is waiting for the server, and every client here
  is good at waiting.
- **`concurrent` is where a pool shows up.** epgsql has none of its own, so its
  eight callers get eight connections and it still comes last; minato and the
  Node pools are within noise of each other.

## Honesty about this benchmark

It was written by the author of one of the clients being measured. Read the
source: every client is set up in `setup/1`, every workload is one line per
client in `runner/3`, and anything unfair is visible there. The workloads that
minato loses are in the table with the ones it wins.
