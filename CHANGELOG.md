# Changelog

All notable changes to this project will be documented in this file.

## [1.1.1] - 2026-08-11

### Documentation

- A changelog that covers the releases that happened

## [1.1.0] - 2026-08-11

### Features

- Take the socket options callers actually pass (#49)

## [1.0.2] - 2026-08-11

### Bug Fixes

- An address family is a choice, not a setting, and a pinned CA is the CA (#47)

## [1.0.1] - 2026-08-10

### Documentation

- Say 1.0, and say what 1.0 does not mean (#46)

## [1.0.0] - 2026-08-10

### Features

- The socket transport by default, and options that say when they stop (#45)

## [0.19.1] - 2026-08-10

### Testing

- Measure throughput, because per-operation cost was answering the wrong question (#44)

## [0.19.0] - 2026-08-10

### Features

- A socket-module transport, opt in (#43)

### Perf

- Build a statement's decoder once, and measure the work rather than the wait (#42)

## [0.18.10] - 2026-08-09

### Bug Fixes

- Make prepared-statement names unique per connection, not per counter (#41)

## [0.18.9] - 2026-08-06

### Bug Fixes

- Do not hand out a connection the server has ended (#39)

## [0.18.8] - 2026-08-06

### Perf

- Decode the rows of a simple query too (#38)

## [0.18.7] - 2026-08-06

### Perf

- Choose the codec when the decoder is built (#37)

## [0.18.6] - 2026-08-06

### Miscellaneous

- Take every plugin from hex and drop the sbom fork (#36)

## [0.18.5] - 2026-08-06

### Perf

- Flatten row runs once instead of reversing them twice (#35)

## [0.18.4] - 2026-08-06

### Perf

- Decode a run of rows while framing it (#34)

## [0.18.3] - 2026-08-06

### Perf

- Collect rows tail-recursively and cut columns in one match (#33)

## [0.18.2] - 2026-08-06

### Perf

- Decode a row in one pass over its bytes (#32)

## [0.18.1] - 2026-08-06

### Perf

- Work out how to read a row once, not once per row (#31)

## [0.18.0] - 2026-08-05

### Features

- Give back connections nobody is using (#30)

## [0.17.0] - 2026-08-05

### Features

- A pool that grows, fails fast, and checks the budget (#29)

## [0.16.1] - 2026-08-05

### Bug Fixes

- Forward every decode option to the codec (#28)

## [0.16.0] - 2026-08-05

### Features

- An opt-in float form for numeric (#27)

## [0.15.4] - 2026-08-05

### Testing

- Generate the TLS certificates instead of committing them (#26)

## [0.15.3] - 2026-08-05

### Documentation

- Guides for a published package (#25)

## [0.15.2] - 2026-08-05

### Testing

- Cancel a statement that has actually started (#24)

## [0.15.1] - 2026-08-05

### Documentation

- Reference the connection options as a type (#23)

## [0.15.0] - 2026-08-05

### Features

- Connection lifetime, a health probe, and the trace bridge (#21)
- Cancel a statement that outlives its deadline (#22)

## [0.14.0] - 2026-08-05

### Features

- Telemetry events and structured logs (#20)

## [0.13.1] - 2026-08-05

### Bench

- Minato against pgo, epgsql, and the Node clients (#19)

## [0.13.0] - 2026-08-05

### Features

- Hand a borrowed connection to another process (#18)

## [0.12.0] - 2026-08-05

### Features

- Parse each statement once per connection (#17)

## [0.11.0] - 2026-08-05

### Features

- Verified TLS and SCRAM-SHA-256-PLUS channel binding (#16)

## [0.10.2] - 2026-08-05

### Testing

- Run the corpus and shape properties through the real client (#15)

## [0.10.1] - 2026-08-05

### Testing

- Add a soak, and fix the two defects it found (#14)

## [0.10.0] - 2026-08-05

### Features

- Add LISTEN and NOTIFY (#13)

## [0.9.0] - 2026-08-04

### Features

- Add the pool, the public API and the application (#12)

## [0.8.0] - 2026-08-04

### Features

- Add transactions and the transaction status (#11)

## [0.7.0] - 2026-08-04

### Features

- Add the simple and extended query paths (#10)

## [0.6.0] - 2026-08-04

### Features

- Add the connection layer (#9)

## [0.5.0] - 2026-08-04

### Features

- Bound, harden and measure the bulk framer (#8)

## [0.4.0] - 2026-08-04

### Features

- Add SCRAM-SHA-256, MD5 and cleartext authentication (#7)

## [0.3.0] - 2026-08-04

### Features

- Add the protocol message codec (#6)

## [0.2.1] - 2026-08-04

### Testing

- Prove the codecs against pg_types and a real PostgreSQL (#5)

## [0.2.0] - 2026-08-04

### Features

- Add the type codec layer (#3)

## [0.1.1] - 2026-08-04

### Miscellaneous

- Add rebar3_hex and a changelog (#2)

## [0.1.0] - 2026-08-04

### Miscellaneous

- Seed repository with licence and gitignore
- Scaffold rebar3 library with erlang-ci pipeline (#1)

