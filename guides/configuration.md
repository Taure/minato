# Configuration

Every option minato takes, what it defaults to, and why.

## A connection

Passed as `connection` in a pool or listener, or to `minato_conn:connect/1`
directly.

| option | default | |
| --- | --- | --- |
| `user` | required | the role to authenticate as |
| `password` | none | a binary, or a `fun(() -> binary())` called once per attempt and never stored |
| `database` | the user | as PostgreSQL itself defaults |
| `host` | `"localhost"` | |
| `port` | `5432` | |
| `parameters` | see below | added to the `StartupMessage` |
| `ssl` | `false` | |
| `ssl_options` | verify against the OS trust store | each option replaces one default |
| `channel_binding` | `prefer` under TLS, `disable` without | `require` refuses to connect without it |
| `auth` | every method | `[scram_sha_256]` to accept nothing else |
| `connect_timeout` | `5000` | covers the TCP connect and the TLS handshake |
| `timeout` | `15000` | the per read timeout, and the default statement deadline |
| `cancel_timeout` | `5000` | how long a cancelled statement has to acknowledge |
| `prepared_statements` | `64` | how many statements a connection keeps parsed; `0` disables |
| `socket_options` | `binary`, `{active,false}`, `{packet,raw}`, `{nodelay,true}` | each replaces one default |
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
`[minato, checkout, stop]` measures exactly.

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
    {log_statements, false}
]}.
```

`pools` and `listeners` are started by minato's supervisor, so they come up with
the application rather than after it. `log_statements` puts the SQL in events
and logs; it is read per call, so it can be turned on while something is
happening and off again afterwards. See [Security](security.md) for why it is
off by default.
