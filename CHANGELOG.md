# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-11-16

### Upgrading

Nothing in the API is removed or renamed. These are the changes a caller of
1.1.6 can notice, most of them a refusal where there used to be silence.

Two of them stop something that ran on 1.1.6. Look for these first:

- **`ssl_options` without `ssl => true` are refused**, with
  `{invalid_option, ssl_options}`: `minato_conn:connect/1` raises, and a pool
  or a listener does not start. 1.1.6 passed the options over and connected
  without TLS, so a configuration that read as encrypted was not. Add
  `ssl => true`.
- **A query whose whole answer takes longer than `timeout` fails.** `timeout`
  is 15 seconds unless set, and it used to bound only the wait between two
  reads, so a large result that kept arriving was read to its end. Now the
  statement is cancelled at the deadline: `{error, {pgsql_error, #{code :=
  ~"57014"}}}`, with the connection kept, from a server that takes the cancel,
  and `{error, {socket, timeout}}`, with the connection closed, from one that
  is still sending `cancel_timeout` later. Give that call a `timeout` that
  covers the whole result, or read it in parts with a cursor; see "A deadline
  bounds time, not memory" in the configuration guide.

**Values and results**

- A `numeric` outside what PostgreSQL stores, more than 131072 digits before
  the point or 16383 after it, raises `{minato_codec, #{reason := out_of_range}}`
  when encoded instead of being written with a wrapped header. One too large
  for `numeric_format => float` raises a codec failure instead of `badarg`.
- An array with more than six dimensions, a negative dimension, or more
  elements declared than its bytes could hold is refused on decode.
- An `int2`, `int4` or `int8` that arrives as text and does not fit its type
  raises `{minato_codec, #{reason := out_of_range}}` instead of coming back as
  a larger integer, and so does a `numeric` longer than PostgreSQL writes one.
  A float, a date, a time or a timestamp in text longer than a server writes
  raises `malformed_text`. A value a PostgreSQL server sent decodes as before.
- `command` in a result is an atom for every tag PostgreSQL has, as before,
  and the binary the server sent for a word that is not one of them. No atom
  is made from bytes off the socket any more.
- `column_name_as_atom => true` gives an atom key only for a column whose
  name is an atom already, and the binary the server sent for any other. It
  made an atom of every name, and the server chooses the names. A caller that
  matches `#{id := _}` is unaffected, since its own code made `id` an atom;
  one that turns a row's keys into atoms it never mentions now gets binaries.
- A message longer than 1,073,741,823 bytes, and a statement with more than
  65,535 parameters, raise `{minato_protocol, _}` before anything is sent.
- A row with more columns than its description raises
  `{minato_protocol, #{reason := column_count_mismatch}}`, as one with fewer
  already did, where it raised `column_longer_than_the_message`, or
  `negative_column_length` when the extra column was NULL. Bytes after the
  last column make `minato_protocol:columns/1` raise `malformed`.
- `{array, Rows}` as a parameter sends an array of more than one dimension,
  for every element type and in both formats: `{array, [[1,2],[3,4]]}` is a
  2 by 2 `_int4`, and what a multi-dimensional array decodes to goes back as
  `{array, Decoded}`. A plain list is one dimension and raises what it always
  raised for a list inside it, so `[[1,2]]` and `["12"]` handed to `_int4` are
  still `not_an_integer`. Rows that are not rectangular raise `ragged_array`
  and a seventh dimension `dimensions_out_of_range`.
- A `date` or `timestamp` the binary format cannot hold, or that would land on
  the value meaning `infinity`, raises
  `{minato_codec, #{reason := out_of_range}}` instead of being written wrapped.
  Day 0 raises `day_out_of_range`, where it said `month_out_of_range`, and a
  `time` given as microseconds outside one day raises `time_out_of_range`.
- A parameter that will not encode raises with `value => redacted` where the
  value was. `{minato, [{log_values, true}]}` puts it back.
- A null byte in a statement's text, or in the name of a statement or a
  portal, raises `{minato_protocol, #{reason := null_byte}}` before anything
  is sent, where it was sent as it was.

**Connecting**

- `user`, `database` or a `parameters` entry holding a null byte makes
  `minato_conn:connect/1` raise before it opens a socket.
- `channel_binding => require` authenticates with `SCRAM-SHA-256-PLUS` or not
  at all: cleartext, MD5, a server asking for no password, SCRAM without
  `-PLUS` and SCRAM on a connection without TLS are all refused with
  `{error, {channel_binding_required, Method}}`. A server that takes the bound
  mechanism and answers `AuthenticationOk` before the exchange is finished is
  refused the same way, where under `require` it raised
  `{minato_auth, #{reason := sasl_exchange_unfinished}}`. Without `require` it
  still raises that.
- `channel_binding`, `ssl`, `auth`, `ssl_options` and `password` are checked
  before a socket opens. A value minato does not know, such as a misspelt
  `channel_binding`, a `verify` that is neither `verify_peer` nor
  `verify_none`, or `{handshake, hello}`, makes `minato_conn:connect/1` raise
  `{minato_conn, #{reason := {invalid_option, Key}}}`, and a pool or a listener
  does not start: `{error, {invalid_option, Key}}`. A misspelt
  `channel_binding` used to be read as `prefer`.
- A key that is not an option is refused, in a connection's options, a pool's
  and a listener's: `{invalid_option, Key}`, before a socket opens. A key
  minato did not know used to be passed over, so `sslmode => require` or a
  misspelt `channel_binding` connected with the default. The options are the
  ones in the configuration guide; remove anything else from what is passed.
  A key that is not an atom is not repeated in the reason:
  `{invalid_option, not_an_atom}`.
- `connect_timeout`, `timeout` and `cancel_timeout` are checked with the rest:
  each is a number of milliseconds, an integer that is not negative, or
  `infinity`, and anything else is `{invalid_option, Key}`. `"5000"` out of an
  environment variable used to open a connection and raise `badarith` in the
  first statement that ran out of time.
- A `host` that is not a string, an atom, an address or `{local, Path}`, a
  binary above all, is `{invalid_option, host}`. `minato_conn:connect/1` raised
  `function_clause` for one, and a pool did not start, with that as the reason.
- `ssl_options` without `ssl => true` are `{invalid_option, ssl_options}`.
  They used to be ignored and the connection opened in the clear. Add
  `ssl => true`, or take them out.
- `minato_conn:connect/1` checks its options before it reads the password, so
  an option that is wrong is reported ahead of a password that is not text.
- `{server_name_indication, disable}` in `ssl_options` no longer turns the
  hostname check off with it. `{verify, verify_none}` is how to say that. The
  certificate is checked for `host` once the handshake is over, and one that
  does not carry it is `{error, {tls, {bad_cert, hostname_check_failed}}}`.
- A TLS session is never resumed and never kept for another connection to
  resume: `{reuse_sessions, false}` and `{session_tickets, disabled}` are
  defaults. `ssl_options` with `{reuse_sessions, true | save}`,
  `{reuse_session, _}`, `{session_tickets, manual | auto}` or `{use_ticket, _}`
  are `{invalid_option, ssl_options}`.
- A pool started without `ssl` for a host that is not this machine logs one
  warning, `unencrypted_connection`. `ssl => false` written out says it was
  meant and logs nothing.
- The exchange from the startup message to `ReadyForQuery` has to finish
  within `timeout` as a whole, and `connect_timeout` covers the TCP connect,
  the TLS request and the handshake together.
- At most 64 `ParameterStatus` entries of 4096 bytes each are kept.

**Timeouts**

- `send_timeout` defaults to the connection's `timeout`, with
  `send_timeout_close`, where it was `infinity`. A server that stops reading
  now costs `{error, {socket, timeout}}` and the connection. A single value of
  hundreds of megabytes over a slow link needs `send_timeout` raised in
  `socket_options`.
- The same holds for TLS on the socket transport, which `ssl` writes without
  a deadline of its own: a new supervised process, `minato_overdue`, shuts the
  socket down when a write runs out of time, and there the connection is
  closed whatever `send_timeout_close` says. Without the `minato` application
  running the deadline still holds, at the cost of a process per write.
  `minato_overdue` and `minato_sup` cannot be the name of a pool or a
  listener: `{error, {reserved_name, Name}}`.
- A statement's `timeout` ends a result that is still arriving. It was only
  looked at when a read found nothing waiting, so rows sent without a pause
  were read for as long as the server sent them. The statement is cancelled at
  the deadline, which a PostgreSQL that is only sending a long result answers
  with `57014`, and the connection is kept. A server still sending
  `cancel_timeout` after that is given up on: `{error, {socket, timeout}}`,
  and the connection is closed. A result that takes longer than `timeout` to
  arrive, and used to arrive, needs `timeout` raised for that call.
- The deadline bounds how long a call reads and not how much. `timeout =>
  infinity` and `cancel_timeout => infinity` each take the bound away, so
  keep both finite towards a server that is not trusted and read a result
  that may be large with a cursor, a `FETCH` at a time. The configuration
  guide shows how.
- A statement's `timeout` that is not a number of milliseconds or `infinity`
  raises `{minato_query, #{reason := {invalid_option, timeout}}}` before the
  statement is sent, and the connection is kept. It was a `badarith`.
- `minato_query:prepare/3`, `minato_query:close/2`, the reset a pool reads at
  checkout and the rollback after a function that raised in
  `minato_txn:transaction/2` get one `timeout` for the whole answer, where
  each read of it got one. A server that has not finished the answer by then
  costs the connection: `{error, {socket, timeout}}`.
- `minato_conn:close/1` does not raise and does not wait on a server that has
  stopped reading: `Terminate` gets the shorter of `send_timeout` and one
  second, and is not written at all behind bytes the server has not taken. TLS
  with `transport => inet` is closed by `ssl`, which gives up after about ten
  seconds.

**Statements kept on a connection**

- The first use of a statement by `minato:query/3` and `minato_query:cached/3`
  is two round trips, where it was three, and `minato_query:prepare/3` is one,
  where it was two. The statement is parsed and run in one exchange, so the
  first use also works behind a pooler that does not follow named statements;
  later uses there still need `prepared_statements => 0`.
- A kept statement is parsed again and run once more in more of the cases
  where the table changed under it: when the server refuses its parameters and
  their types have changed, when a value no longer fits the type it was kept
  with, and when the number of result columns has changed. Still once, and
  never inside a transaction the refusal has aborted: there the statement is
  dropped and the server's error is returned as it came, where `0A000` used to
  come back as `25P02`.
- It is run again only when the server refused it before it began, at
  `Bind`. An error from a statement that had started is returned as it came,
  whatever its code, because running it again would run it twice.
- A value that no longer fits a kept statement raises at once inside a
  transaction, without the server being asked anything in it. Outside one the
  statement is described again first, as before.
- `prepared_statements` counts the statements a connection is keeping. It
  counted every name ever handed out, so a connection that closed its
  statements still ran out of room.
- A statement run unnamed because the connection keeps no more keeps the
  caller's `timeout` and is one `[minato, query]` span, where it was two.
- A notification or a `ParameterStatus` that arrives while a statement is
  being described is passed over, where it raised `unexpected_message` on a
  session that had run `LISTEN`.
- An answer to a statement that does not begin with `BindComplete` raises
  `{minato_query, #{message := execute, reason := unexpected_message}}`, with
  the kind of message that came first as `data`. A notice, a notification
  and a `ParameterStatus` ahead of it are still passed over.

**Telemetry and logs**

- The `reason` of a failed statement in `[minato, query, stop]` keeps the
  fields of the server's error that name things and drops `message`, `detail`,
  `hint` and the rest, which can quote a value. The caller is still returned
  all of it. Frames in an event's `stacktrace` carry an arity, not arguments,
  including the frame of a fun. `log_values` restores both.
- Query events carry `host`, `port`, `database` and, on a pooled connection,
  `pool`.
- The `reason` of a pool's `connect_failed` warning is narrowed the same way:
  a server's error keeps the fields that name things, and a failure of
  `minato_auth`, `minato_scram` or `minato_conn` is its kind alone,
  `{minato_auth, no_supported_mechanism}` where it carried the list the server
  offered. The warning is written on every try.

**Pools, listeners and transactions**

- A parameter that will not encode, the wrong number of parameters, and a
  column that will not decode still raise, but no longer cost the connection:
  it is put back to ready first, `minato:query/4` and `minato:simple/3` return
  it to the pool, and `disconnects` in `minato:stats/1` no longer counts them.
- A null byte in a statement's text still raises, and no longer costs a
  pooled connection either: nothing was written, so `minato:query/4` and
  `minato:simple/3` return the connection to the pool.
- The rollback after an exception in `minato_txn:transaction/2` is sent
  behind a `Sync` and read up to a mark of its own, so answers the function
  left unread are not taken for it. A connection that cannot be rolled back
  that way is closed.
- A pool asks the server for `max_connections` from the process that
  connects, so a slow or malformed answer no longer holds or stops the pool.
  It asks until it has an answer and then not again, whatever the answer was.
- A pool opens a connection for every caller that is waiting, side by side,
  up to `size`. It opened one at a time, so a caller could time out below
  `size` while a connect was in flight. While connects are failing it is still
  one at a time.
- A reset answered with bytes that are not a message costs the connection:
  the checkout tries the next one and answers
  `{error, {session_reset, {minato_protocol, Reason}}}` if none is left, where
  it raised in the caller and left the connection counted as borrowed.
- A pool that could not connect opens nothing until its wait is over. A
  caller that arrived during the wait, or a connection given up during it,
  started a connect at once, so a server that was down was asked as often as
  callers arrived. While connects are failing the pool also fills back up to
  `min_size` one connection at a time, where it opened all of them together.
- The wait before a pool or a listener connects again is a random time in the
  upper half of the backoff, so `retry_in_ms` in `connect_failed` is no longer
  exactly 100, 200, 400 and so on.
- A listener whose `LISTEN` or `UNLISTEN` failed on the socket, or that was
  sent bytes that are not a message, reconnects and tells its subscribers
  instead of stopping. `minato:listen/2` on a connection lost that way answers
  `{error, {minato_protocol, Reason}}` or the socket's error.
- `minato:listen/2` and `minato:unlisten/2` refuse a channel that is not a
  binary, `{error, {invalid_channel, not_a_binary}}`, or that holds a null
  byte, `{error, {invalid_channel, null_byte}}`, without asking the listener.
  The first stopped the listener and the second cost it its connection.
- The channel and the payload of a notification are copies, so a subscriber
  that keeps one keeps nothing else.

**Tested against**

- PostgreSQL 14 to 18, and PgBouncer 1.26 in transaction mode. See
  "PgBouncer and connection poolers" in the configuration guide for what does
  not cross a pooler.

### Added

- `minato_conn:validate/1` says whether a connection's options would be
  accepted, without connecting.
- `minato_conn:origin/1` and the type `minato_conn:origin/0`: the `host`,
  `port`, `database` and `pool` a connection's events carry.
- `{array, Rows}` as a parameter, for an array of more than one dimension.
- `{minato, [{log_values, true}]}` in the application environment puts
  values back into raised errors and events. `minato_telemetry:values/0`
  reads it, and `minato_telemetry:reason/1` and `minato_telemetry:frames/1`
  are what narrow a failure and a stacktrace for an event.
- `minato_auth:proven/1`: whether the server has proved in a SCRAM exchange
  that it knows the password.
- `minato_backoff:spread/1`: the random wait a pool and a listener take from
  their backoff.
- `minato_sup:reserved/1`: whether a name is one of minato's own.
- `minato_overdue`, the supervised process that ends a TLS write on the
  socket transport when it runs out of time, with `watch/2`, `finished/1` and
  `ran_out/1`.
- An `unencrypted_connection` warning from a pool started without `ssl` for
  another host.

### Features

- *(codec)* Send an array of more than one dimension only as `{array, Rows}`
- *(pool)* Warn once when a pool would reach another host without TLS

### Bug Fixes

- *(codec)* Bound numeric to the range PostgreSQL stores and decode it in one pass
- *(codec)* Bound array dimensions, nesting and element counts on decode
- *(protocol)* Read command tags against a closed vocabulary
- *(protocol)* Refuse a frontend message that does not fit its length field
- *(conn)* Refuse a startup parameter that holds a null byte
- *(auth)* Make a required channel binding refuse every method that cannot carry one
- *(telemetry)* Keep values out of failed-query events and say where a query went
- *(pool)* Ask the server for its connection limit from the connector, and read any answer
- *(listener)* Reconnect after a statement or a message that lost the connection
- *(conn)* Bound the opening exchange as a whole and the parameters kept from it
- *(tls)* Keep checking the hostname when the server name is left out of the handshake
- *(conn)* Bound a write by the connection timeout unless told otherwise
- *(query)* A value that does not fit no longer costs the connection
- *(txn)* Roll back on a connection an exception left out of step
- *(conn)* Give a TLS write on the socket transport a deadline
- *(protocol)* Call a column the description does not have a count mismatch
- *(query)* Notice a kept statement that has gone stale, and renew it once
- *(query)* Pass over what the server says unasked while a statement is described
- *(conn)* A close neither raises nor waits on a peer that stopped reading
- *(protocol)* Call a null column the description does not have a count mismatch
- *(codec)* Name the date field that is wrong, and refuse what the wire cannot hold
- *(codec)* Write an array of more than one dimension
- *(overdue)* Keep minato's own names, and the write deadline, whatever is started
- *(protocol)* Make no atom of a column name the server chose
- *(telemetry)* Take the arguments out of a frame that names no module
- *(pool)* Open a connection for every caller waiting, up to the size
- *(conn)* Refuse a security option minato does not know before a socket opens
- *(auth)* Refuse SCRAM that cannot be bound the way every other method is refused
- *(pool)* Give up a connection whose reset is answered with bytes that are no message
- *(protocol)* Refuse a null byte in a statement's text or in a statement or portal name
- *(query)* Run a kept statement again only when it was refused before it began
- *(conn)* Count the room for statements in statements kept, not in names handed out
- *(query)* Raise a value that will not encode at once inside an open transaction
- *(tls)* Check the hostname after the handshake when no server name is sent
- *(listener)* Send subscribers copies of the channel and the payload
- *(pool)* Wait a random part of the backoff before connecting again
- *(pool)* Ask the server for its limit once, whatever it answers
- *(test)* Name only the other tests minato_conn is mutated against
- *(test)* Mutate minato_conn against its own tests alone again
- *(tls)* Make every handshake a full one
- *(conn)* Hold an answer that is still arriving to its deadline
- *(listener)* Refuse a name that cannot be a channel without asking the listener
- *(pool)* Keep the connection of a statement that was refused before it was sent
- *(pool)* Open nothing until the wait after a failed connect is over
- *(conn)* Refuse a key that is not an option, and TLS options without TLS
- *(conn)* Check the options before the password is read
- *(codec)* Read a number or a date in text no further than its type goes
- *(query)* Refuse an answer to a statement that was never bound
- *(pool)* Log a failed connect by the name of its refusal
- *(conn)* Refuse an unfinished bound exchange the way a required binding refuses the rest
- *(conn)* Refuse a host that is not one by its name
- *(query)* Give prepare/3 the deadline every other call has
- *(conn)* Refuse a time that is not one when the options are checked
- *(query)* Refuse a timeout that is not a time before the statement is sent
- *(conn)* Name a key that is refused only when it is an atom
- *(query)* Hand a connection back from close/2 without its deadline

### Documentation

- *(security)* What a server cannot make the client do
- *(guides)* Say that a value that would not encode is raised redacted
- Say which PostgreSQL versions are tested and what crosses a pooler
- Add a security policy
- *(codec)* Say what a string in an array of numbers becomes
- What a kept statement, a close, an array and a date now do for a caller
- The write deadline without the application, a bounded close and minato's own names
- *(security)* The setting for production, and what the defaults leave open
- What raises and why, what listen/2 can answer, and a command that is a binary
- A deadline bounds time and not memory, and how to read a large result

### Performance

- *(query)* Parse and run a kept statement in one exchange

### Refactor

- *(socket)* Type the v6 address and the partial send as the socket module specifies them
- *(conn)* Keep the socket that was opened beside the one in use
- *(pool)* Type the answer a limit is read from as the results it is
- *(sup)* Type the options a child is started with as the two kinds they are
- *(listener)* Catch only the raise a simple statement can make
- *(pool)* Draw the wait before a reconnect in one place
- Let a reraise that cannot fail carry nothing if it does
- Drop two comments that repeat what is beside them
- *(types)* Type what the hostname check, the limit and their tests are given
- *(test)* Write out what a server answers after an unasked message
- *(pool)* Name a refusal by its first element in a way the types follow

### Miscellaneous

- *(types)* State what the new code and its tests hand eqWAlizer and the linter
- *(mutate)* Point rebar3_mutate at the tests of modules tested under other names
- *(types)* State what the pooler and traces tests and the write deadline hand eqWAlizer and the linter
- *(types)* Ask the transport's own module about a closing socket, and drop a macro nothing uses
- *(app)* List minato_overdue among the registered names
- *(deps)* Pin every plugin to a version and resolve the lock again from nothing
- *(bench)* Format the benchmarks, and open a new connection every 500 first uses

### Testing

- *(protocol)* Generate only startup parameter names the encoder accepts
- *(txn)* A downgraded commit through the pool, and what an exception leaves on the server
- *(protocol)* Frame any stream of messages, and any row against its columns
- *(transport)* Make the send timeout case wait on a write
- *(pool)* Pin what a borrow costs and who is served next
- Let the compose file start any PostgreSQL major
- *(pgbouncer)* Run minato through a transaction pooler
- *(traces)* Run the OpenTelemetry bridge the guide shows
- *(txn)* What minato_txn sends for each outcome, against a scripted server
- Cover the edges mutation testing found nothing watching
- *(traces)* Find the guide from where rebar3 runs, not from the build directory
- Bounds, refused text and row lengths that mutation testing found unasserted
- *(bench)* Time the first use of a kept statement
- *(pool)* End only the backends the pool suite opened
- What minato and minato_listener do, against a scripted server
- Stop waiting on a scripted server that has already answered
- *(codec)* What minato_codec decides for itself, which mutation testing found unwatched
- *(codec)* The last date and timestamp the wire holds, and whole hours
- *(overdue)* What starts it, what it leaves behind, and what the supervisor allows
- *(query)* What a query reports of itself, and answers that come out of turn
- *(pool)* Clear a pool a run that was cut short left under the supervisor
- *(pool)* What a pool makes of the limit it asks for, where mutation testing can run it
- *(types)* Type the property tests instead of switching the checker off for them
- *(pool)* A connection closed under a raise over its values is counted as lost
- *(listener)* Ask what a listener does about a wait already started
- *(listener)* Let the server's turn end with the test that asked for it
- *(pool)* Run the growth tests under mutation, and wait a second at most
- *(overdue)* Wait for the writer to be gone instead of asking whether it is
- *(conn)* Run the hostile server tests when minato_conn is mutated
- *(codec)* Send the array with no elements as the array it is in the round trip suite
- *(protocol)* A column name no atom exists for stays a binary in a row
- *(query)* Ask what a bind that is not answered as expected comes to
- Take down what a test started when the test is killed
- Give the helpers and the scripted server the types they are used with
- *(redaction)* Judge what minato logs, not what ssl reports of its own
- *(pool)* Keep a warning from one test out of the next one's capture
- *(pool)* Cover a connect that fails during the wait and a connection read after its reset
- *(pool)* Write the reset test's script with the helper the others use
- Stop what a test started by its process, not by its name
- *(conn)* Ask what ssl is handed for a session, on every release
- *(query)* A result still arriving at its deadline, against a real PostgreSQL
- *(types)* Give the cursor case and the refused listener the types they are used with

### Style

- *(query)* Wrap a comment that ran past the line
- *(conn)* Put the comment on an overdue deadline beside the function it is about

## [1.1.6] - 2026-11-06

### Bug Fixes

- Keep secrets out of child specs and status, retry raising connects, accept hour 24 only as midnight (#61)

### Documentation

- Position minato as an alternative to epgsql and pgo (#62)

## [1.1.5] - 2026-11-02

### Bug Fixes

- Two Windows-only flakes, a TLS close that hangs and a probe that aborts connections (#60)

## [1.1.4] - 2026-11-01

### Bug Fixes

- *(pool)* Validate pool options and keep the password out of start errors and status (#59)

## [1.1.3] - 2026-10-25

### Bug Fixes

- *(pool)* Reset session state when a connection is checked in (#53)

## [1.1.2] - 2026-10-24

### Miscellaneous

- Attribute licence to Daniel Widgren, not Widgrens IT AB (#52)

## [1.1.1] - 2026-08-11

### Documentation

- A changelog that covers the releases that happened (#50)

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

