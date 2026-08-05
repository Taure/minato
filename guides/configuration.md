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
| `frame_opts` | `#{max_message_length => 67108864}` | raise it only for a single value near PostgreSQL's 1 GB limit |

Two startup parameters are sent unless `parameters` overrides them:
`client_encoding` is `UTF8`, because the codecs decode text as UTF-8 and a
server sending LATIN1 would put mojibake in a binary rather than raise;
`DateStyle` is `ISO, MDY`, because the text format for dates is only
unambiguous under ISO. Set `application_name` here - it is what
`pg_stat_activity` shows, and it is the difference between finding the query
that is hurting and guessing.

## A pool

| option | default | |
| --- | --- | --- |
| `connection` | required | the map above |
| `size` | `10` | connections kept |
| `max_age` | `infinity` | retire a connection checked in older than this |

`size` is not a throughput dial. A pool larger than the database can serve moves
the queue from your application to the server, where you cannot see it; a pool
smaller than your concurrency makes callers wait, which
`[minato, checkout, stop]` measures exactly.

`max_age` is `infinity` because a connection to PostgreSQL is good
indefinitely, and churning connections is work nobody asked for. Set it when
something sits in the middle - a proxy, a load balancer, a NAT - since those
have limits of their own and a connection one of them cut is otherwise found by
a query failing on it.

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
