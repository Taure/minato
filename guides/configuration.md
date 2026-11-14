# Configuration

Every option minato takes, what it defaults to, and why.

## A connection

Passed as `connection` in a pool or listener, or to `minato_conn:connect/1`
directly.

| option | default | |
| --- | --- | --- |
| `user` | required | the role to authenticate as |
| `password` | none | a binary or a string, or a fun of no arguments returning one, called once per attempt and never stored; prefer a named `fun my_app:db_password/0` |
| `database` | the user | as PostgreSQL itself defaults |
| `host` | `"localhost"` | |
| `port` | `5432` | |
| `parameters` | see below | added to the `StartupMessage` |
| `ssl` | `false` | |
| `ssl_options` | verify against the OS trust store | each option replaces one default |
| `channel_binding` | `prefer` under TLS, `disable` without | `require` accepts `SCRAM-SHA-256-PLUS` and refuses every other method, including a server that asks for no password |
| `auth` | every method | the methods a server may ask for, as libpq's `require_auth`; `[scram_sha_256]` to accept nothing else |
| `connect_timeout` | `5000` | covers the TCP connect, the answer to the TLS request and the TLS handshake together; `infinity` to wait |
| `timeout` | `15000` | the per read timeout, the default statement deadline, and how long the opening exchange may take from the startup message to `ReadyForQuery`; `infinity` to wait |
| `cancel_timeout` | `5000` | how long a cancelled statement has to acknowledge; on Windows also how long closing a TLS connection waits for the server to close first, never more than a second |
| `prepared_statements` | `64` | how many statements a connection keeps parsed; `0` disables |
| `socket_options` | `binary`, `{active,false}`, `{packet,raw}`, `{nodelay,true}`, `{send_timeout, Timeout}`, `{send_timeout_close,true}` | each replaces one default; `Timeout` is the connection's `timeout` |
| `transport` | `socket` | `inet` goes back to the driver every BEAM program uses |
| `frame_opts` | `#{max_message_length => 67108864}` | raise it only for a single value near PostgreSQL's 1 GB limit |

Two startup parameters are sent unless `parameters` overrides them:
`client_encoding` is `UTF8`, because the codecs decode text as UTF-8 and a
server sending LATIN1 would put mojibake in a binary rather than raise;
`DateStyle` is `ISO, MDY`, because the text format for dates is only
unambiguous under ISO. Set `application_name` here - it is what
`pg_stat_activity` shows, and it is the difference between finding the query
that is hurting and guessing.

`transport` is `socket`, which is `minato_socket` over the socket NIFs. It does
everything the driver does on every machine minato runs on, costs about a
quarter less per query and about half less per pooled one, and holds more
throughput at the same CPU once a pool is deep enough for per-operation cost to
matter at all - see the [bench](https://github.com/Taure/minato/tree/main/bench)
for where that is and is not true. `inet` is the driver, and is one option away
for a machine or a workload that disagrees.

The two transports take the same `socket_options`, but the socket transport has
no driver behind it to hold the ones it does not use, so it sorts them by what
they decide.

`inet`, `inet6`, `ip` and `port` are read before connecting: the first two
choose which address a hostname resolves to, the other two the local end to bind
to. `nodelay`, `keepalive`, `recbuf`, `sndbuf`, `priority`, `reuseaddr`, `tos`,
`bind_to_device` and `linger` are set on the socket, and `send_timeout` with
`send_timeout_close` are applied to the write. `binary`, `{packet, raw}`,
`{active, false}`, `buffer`, `delay_send`, `high_watermark`, `low_watermark`,
`exit_on_close` and `show_econnreset` are accepted and ignored, because this
transport already does them or configures a port's send queue that is not there.

`send_timeout` defaults to the connection's `timeout` and `send_timeout_close`
to `true`: a server that stops reading costs one timeout and the connection,
`{error, {socket, timeout}}`, and a statement deadline, which is spent on reads,
is no longer the only bound. It bounds a whole write, so a single value of
hundreds of megabytes over a slow link needs it raised, or `infinity`. A TLS
session on the socket transport is written by `ssl`, which takes no deadline of
its own, so there the socket under the session is shut down when the time runs
out and the connection is closed whatever `send_timeout_close` says. With the
`minato` application running that costs a timer; without it the bound still
holds, and costs a process per write.

Closing is bounded as well. `minato_conn:close/1` gives `Terminate` the shorter
of `send_timeout` and one second, writes nothing behind bytes the server has
not taken, and does not raise.

Anything else is refused at connect rather than silently dropped. If you hit
that with an option the driver takes, it is a gap in the list rather than a
decision - the list is meant to be what callers pass.

`inet6` means v6 or nothing. A host with both an A and a AAAA record resolves to
v4 unless you say otherwise, and a caller that asked for v6 gets an error rather
than a v4 connection, because a quiet fall back is the option accepted and not
honoured.

## A pool

| option | default | |
| --- | --- | --- |
| `connection` | required | the map above |
| `size` | `10` | the most connections this pool will hold |
| `min_size` | `1` | how many it opens before anybody asks |
| `disconnected` | `fail` | what a checkout gets when the pool is empty and cannot connect |
| `max_idle` | `60000` | close a connection nobody has wanted for this long, down to `min_size` |
| `max_age` | `infinity` | retire a connection checked in older than this |

`min_size` is one because a node with twenty pools should not want a hundred
connections the moment it boots, and one is still enough for the pool to prove
it can connect and complain at start up rather than at the first query. The rest
open when a caller finds none free. Set it to `size` for a pool that must be
warm on the first request, and to `0` for one that may never be used at all.

`max_idle` is the other half of `min_size`. A pool that grew to meet a busy hour
would otherwise hold that hour's connections until the process died, which is a
cost the server pays and nobody sees. The floor is never swept below, because
the point of the floor is that somebody has already paid for those connections.
`infinity` keeps whatever the pool has grown to.

`disconnected` is `fail`: a checkout against a pool that holds nothing and whose
last attempt to connect failed answers `{error, disconnected}` immediately.
During an outage the alternative is every caller holding a process for the whole
checkout timeout to learn the same thing, and a queue that outlives the outage.
`wait` queues anyway, for work that would rather be slow than fail.

`size` is not a throughput dial. A pool larger than the database can serve moves
the queue from your application to the server, where you cannot see it; a pool
smaller than your concurrency makes callers wait, which
`[minato, checkout, stop]` measures, along with the round trip a checkout may
spend reading the answer to the connection's session reset.

`max_age` is `infinity` because a connection to PostgreSQL is good
indefinitely, and churning connections is work nobody asked for. Set it when
something sits in the middle - a proxy, a load balancer, a NAT - since those
have limits of their own and a connection one of them cut is otherwise found by
a query failing on it.

### How many connections is that

`size` per pool, times the pools on the node, times the nodes, against the
server's `max_connections`. Nobody does that multiplication until PostgreSQL
starts refusing, so minato does it: the first connection a pool opens asks the
server for its limit, and a pool that alone wants a quarter of it says so once,
at `warning`, with `event => connection_budget`.

The arithmetic bites hardest in test suites, where every module tends to start a
pool and none of them stop one. See the [testing](#pools-in-tests) note below.

### Pools in tests

A test suite that starts a pool per module and stops none of them is asking for
`sorry, too many clients already`, and it will get it sooner with minato than
with a client that opens connections lazily, unless `min_size` is low.

Three things that keep it quiet: start one pool for the suite rather than one
per module; use `min_size => 1` and a small `size`, since tests are rarely
concurrent enough to need more; and stop the pool when the suite ends -
`minato:stop_pool/1` closes every connection it holds.

## PgBouncer and connection poolers

A pooler in transaction mode lends a client a server connection for one
transaction and takes it back when that ends, so two statements from one
minato connection can be answered by two backends. minato runs behind one,
and the suite runs against PgBouncer 1.26 in transaction mode with both
settings below, but what a session holds does not follow the client.

| | through the pooler |
| --- | --- |
| `minato:simple/2`, `minato_query:query/3` | work: one statement is one exchange and stays on one backend |
| `minato:transaction/2`, `minato_txn` | work: the backend is kept from `BEGIN` to the end |
| a statement deadline and its cancel | work: the pooler passes the cancel on |
| `minato:query/3`, `minato_query:cached/3` | need the pooler to follow named statements, or `prepared_statements => 0` |
| `minato_query:prepare/3` | the same |
| `minato:start_listener/2` | does not work: connect a listener to the server itself |

`minato:query/3` keeps statements parsed by name, and a name parsed on one
backend means nothing to the next. PgBouncer follows them from 1.21 when its
`max_prepared_statements` is above zero, and then nothing needs changing. With
it at zero, or behind a pooler that does not do this, set
`prepared_statements => 0` in the connection: every statement is then parsed
unnamed inside the exchange that runs it. Left at the default, the first use
of a statement works, because it is parsed and run in one exchange, and a
later one fails with `26000`, `prepared statement does not exist`, whenever
the pooler has moved the client to a backend that never parsed it. minato
parses it again once, which lasts until the next move, or fails with `42P05`
on a backend that already has the name.

Behind a PgBouncer that follows statements, a migration needs one step more
than it does on a direct connection. PgBouncer keeps a statement by its SQL
text and prepares that on every backend it uses, so a statement the server
refuses after a table changed (`0A000`, or `42883` when a parameter's type
changed) stays refused, for new clients as well, until `RECONNECT` on
PgBouncer's admin console gives it new backends. minato returns that error
once and does not run the statement a third time. After the `RECONNECT`, a
minato connection still holds the column and parameter types it was told
before the migration, and PgBouncer has prepared the statement again without
telling it. A different number of columns is noticed and parsed again; a
column whose type changed in place is read as the type it used to be. So when
a migration changes the type of a column, recycle the minato pools as well
(`minato:stop_pool/1` and start, or a `max_age`), or run with
`prepared_statements => 0`.

A notification is sent to the backend that ran `LISTEN`, and the pooler has by
then taken that backend back, so it has nobody to hand the notification to and
drops it. Nothing fails: the listener subscribes, and hears nothing.

Three smaller things. `channel_binding` and the SCRAM exchange are with the
pooler, which authenticates to the server on its own. The limit a pool reads
for its `connection_budget` warning is the server's `max_connections`, not
what the pooler will accept. And anything set on the session outside a
transaction, with `SET` or an advisory lock, lands on a backend the next client
inherits; the reset a minato pool sends between borrowers runs on whichever
backend it is given, so it is not the defence here that it is on a direct
connection.

## A listener

```erlang
{ok, _Pid} = minato:start_listener(events, #{connection => #{user => ~"minato"}}).
```

`connection` is the only option. A listener holds one connection and never
shares it, because `LISTEN` is session state.

## Per query

Options to `minato:query/4`, `minato:simple/3` and the `minato_query` functions:

| option | default | |
| --- | --- | --- |
| `timeout` | the connection's `timeout` | deadline for the statement; on expiry it is cancelled on the server, not abandoned |
| `return_rows_as_maps` | `false` | a map per row instead of a tuple |
| `column_name_as_atom` | `false` | atom keys in those maps |
| `uuid_format` | `string` | `binary` for the raw 16 bytes |
| `datetime_format` | `datetime` | `microseconds` for lossless integers |

`column_name_as_atom` is off because a column name is not always something you
wrote: a query built at run time can alias a column after a value, and every
distinct alias would make an atom that is never collected. Turn it on for
queries whose column names you chose.

## The application environment

```erlang
{minato, [
    {pools, #{main => #{size => 10, connection => #{user => ~"minato"}}}},
    {listeners, #{events => #{connection => #{user => ~"minato"}}}},
    {log_statements, false},
    {log_values, false}
]}.
```

`pools` and `listeners` are started by minato's supervisor, so they come up with
the application rather than after it. `minato_overdue` and `minato_sup` are
minato's own processes and not names for either: declared, the application does
not start, and `minato:start_pool/2` answers `{error, {reserved_name, Name}}`.
`log_statements` puts the SQL in events
and logs; it is read per call, so it can be turned on while something is
happening and off again afterwards. `log_values` leaves the values a failure
quotes in query events and in the error a parameter that would not encode
raises; without it an event keeps the server error's code and the names it
gives, and the raise says `redacted`. It is read per call too. See
[Security](security.md) for why both are off by default.
