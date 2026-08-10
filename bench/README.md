# Benchmarks

minato against the other Erlang PostgreSQL clients, and against the clients
people use from Node and Python, on the same workloads.

```
docker compose -f test/docker-compose.yml up -d
bench/run.sh 2000
```

The Erlang clients always run. The JavaScript ones need `cd bench/js && npm
install` and the Python ones need `bench/py/install.sh`, which puts `asyncpg`
and `psycopg[binary]` in `bench/py/.venv`; the runner says which it skipped
rather than leaving them silently out.

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
microseconds per operation, mean.

| workload | minato | epgsql | pgo | node-postgres | postgres.js | asyncpg | psycopg3 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| simple | **322** | 347 | - | 366 | 351 | 380 | 379 |
| unnamed | 629 | 666 | - | 414 | 750 | **399** | 432 |
| cached | 360 | **339** | 467 | 354 | 377 | 392 | 389 |
| rows_1000 | 639 | **576** | 3662 | 728 | 842 | 584 | 580 |
| rows_5000 | **1429** | 1861 | 15428 | 1868 | 1994 | 1584 | 1581 |
| wide_row | 373 | **371** | 663 | 384 | 439 | 389 | 403 |
| insert | 413 | 369 | 489 | **354** | 386 | 405 | 379 |
| concurrent | 1037 | 1451 | 976 | **752** | 847 | 1751 | 1167 |

What the numbers say:

- **Bulk framing is worth what it claimed.** `pgo` reads a header and then a
  payload per message, and at 5000 rows it costs 15 ms against everybody else's
  1.5 to 2 ms. That is the one enormous difference in the table, and it is the
  difference this client was written around.
- **epgsql is still ahead at a thousand rows and behind at five thousand.**
  minato does about thirty percent fewer reductions than epgsql at both sizes,
  so whatever is left at a thousand is not decoding work.
- **Describing before binding costs a round trip**, which is what the `unnamed`
  row is: 629 us against 360 for the same query cached. That is the price of not
  guessing parameter types, and `minato:query/3` pays it once per connection
  rather than once per call. asyncpg and node-postgres are quicker on that row
  because they infer the types instead of asking.
- **The Node and Python clients are not slower than the BEAM ones.** Anybody
  expecting a scripting language to lose here should look at `insert` and
  `concurrent` again. Most of a query's cost is waiting for the server, and
  every client here is good at waiting.
- **`concurrent` is where a pool shows up.** epgsql has none of its own, so its
  eight callers get eight connections and it is still second from last.

## Where the work goes

Wall clock against a database on the same machine is mostly the round trip, and
the differences between clients hide in the noise of whatever else the machine
is doing. `minato_profile` measures the work instead:

```
rebar3 as bench compile
erl -noshell -pa _build/bench/lib/*/ebin _build/bench/lib/minato/bench \
    -eval 'minato_profile:cost(2000), init:stop().'
```

Reductions are not microseconds, but they do not move with the machine, the
server or the load, so a five percent change is a change rather than a
run-to-run wobble. Per operation, same run as the table above:

| workload | minato | epgsql | pgo |
| --- | --- | --- | --- |
| simple | 439 | **289** | - |
| unnamed | 766 | **677** | - |
| cached | 434 | **348** | 1205 |
| rows_1000 | **20303** | 29497 | 152118 |
| rows_5000 | **101072** | 151245 | 757563 |
| wide_row | **1335** | 1657 | 2744 |
| insert | 426 | **391** | 1001 |

minato does less work per row than either and more work per statement. The
per-statement difference is most of what it charges for the things epgsql does
not do at all: a telemetry span around every query, a deadline that cancels the
statement on the server rather than abandoning the connection, and a lookup in
the per-connection statement cache.

`minato_profile:eprof(Workload)` runs one workload under `eprof`, for when the
question is which function rather than how much.

## Honesty about this benchmark

It was written by the author of one of the clients being measured. Read the
source: every client is set up in `setup/1`, every workload is one line per
client in `runner/3`, and anything unfair is visible there. The workloads that
minato loses are in the table with the ones it wins.
