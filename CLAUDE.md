# minato

An independent Erlang PostgreSQL client. Apache-2.0, Daniel Widgren.

## Legal position

This is an original implementation, not a fork and not a port.

- Write every codec and every protocol frame from the PostgreSQL documentation
  and the documented wire format. Do not open the source of pgo, pg_types,
  epgsql, Postgrex, asyncpg or pgx to check how they did it.
- `pg_types` is a test profile dependency used only as a differential oracle.
  Never a runtime dependency, never read for implementation.
- Never use the phrase "clean room". It is a two-team term of art and does not
  describe this work.
- The README may describe prior art as architectural influence. It must never
  claim minato is a fork of anything.

## OTP versions

`.tool-versions` pins erlang 28.4.1 and this is load-bearing: the erlang-ci ELP
action maps only OTP 26, 27 and 28 and hard-fails on anything else, and the
OTP 28 ELP binary panics on an OTP 29 pinned project.

`{minimum_otp_vsn, "28"}` follows from that pin, because rebar3 aborts compile
when the running OTP is below the declared minimum, which would take `elp lint`
and `elp eqwalize-all` offline both locally and in CI. OTP 29 is the intended
support floor: write no syntax and call no stdlib function that OTP 28 lacks,
and raise the gate once ELP ships an OTP 29 build. CI runs the test matrix on
both 28 and 29.

## Architecture, decided and not up for re-litigation

- The caller owns the socket on the query path. Not for speed: for head-of-line
  blocking and session pinning.
- Bulk framing with buffer carry-over, never recv header then recv payload.
  Always pass an explicit recv timeout.
- The protocol codec is a pure module: bytes in, terms out, no I/O, no process.
- Metrics through `counters` and `atomics` from day one.
- Later: a CoDel pool queue implemented from the Nichols and Jacobson paper,
  a public `minato:give_away/3`, and pool enforced connection reset on checkin.

## Consumers

The first two are `kura`, through its `kura_postgres` backend, and `shigoto`,
which uses a driver directly. Both stay on the client they have until minato
earns its way in behind the differential harness and a soak, and neither is
repointed from this repository: the change belongs in theirs.

## Differential harness

`test/minato_differential_SUITE.erl` compares every codec against `pg_types` and
against a real PostgreSQL. It needs a server:

```
docker compose -f test/docker-compose.yml up -d
rebar3 ct --suite test/minato_differential_SUITE
```

It skips when no server answers, so `rebar3 ct` on a machine without Docker is
not a failure. A disagreement goes in `known/3` in the suite with which
implementation is right and why; anything not listed there fails the run. Never
widen an entry to make a run go green without first deciding, against the server
and the documentation, which side is correct.

## Before pushing

`rebar3 fmt` then the full pre-push checklist. Run eqwalize under
`mise exec erlang@28.4.1`.
