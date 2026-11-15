# Security

What minato does about the network, the credentials and the log, and which of
those you have to ask for.

## The setting for production

```erlang
#{ssl => true,
  auth => [scram_sha_256],
  channel_binding => require}
```

The defaults connect to any PostgreSQL there is, and leave three things open to
somebody on the path: without `ssl => true` nothing is encrypted and an MD5 or
SCRAM exchange can be relayed; with it and the default `auth`, whoever holds a
certificate the client accepts can ask for the password itself; and
`channel_binding => prefer` binds only when the server offers to. The three
options above close all of it, and the sections below say why each is needed.
A pool that leaves `ssl` out towards a host that is not this machine logs one
warning at start, and `ssl => false` written out silences it.

## Parameters are parameters

There is no string interpolation anywhere in this client. Values travel as bound
parameters, typed from what the server said they are, and the one path that
cannot take parameters - `simple/2`, the simple query protocol - is documented
as being for statements that have no values in them.

Identifiers that minato itself has to put in a statement, which is channel names
in `LISTEN` and savepoint names, are quoted rather than interpolated. There is a
test that subscribes to a channel called `minato; DROP TABLE nothing`.

## TLS

`ssl => true`. There is **no `prefer` mode**, and that is the important part: a
client that continues in the clear when the server declines TLS is a client
whose encryption an attacker can turn off, because declining is the one message
somebody sitting on the connection can always produce. A server that says no
gets `{error, tls_refused}`.

Verification is on by default - `verify_peer` against the OS trust store, the
hostname checked, `server_name_indication` set, which OTP has to be told
explicitly on a socket upgrade. Anything in `ssl_options` replaces that one
default and nothing else, so turning verification off is possible and has to be
written down where a reviewer can see it.

`{server_name_indication, disable}` keeps the server's name out of the
handshake, where it travels in the clear, and that is all it does here. `m:ssl`
on its own also stops checking the certificate for the name when it is given
that option; minato puts the check back, against `host`, so the option cannot
be used to turn hostname verification off by accident. The ways to turn it off
are the ones that say so: `{verify, verify_none}`, a `verify_fun` of your own,
or a `customize_hostname_check` whose `match_fun` accepts what you mean it to.

## Channel binding

`SCRAM-SHA-256-PLUS` with `tls-server-end-point`, on by default under TLS.

Without it, SCRAM proves a shared password over whatever channel the client
happens to be on. A man in the middle holding a certificate the client accepts
can relay the entire exchange and keep the session: the password is never
revealed, and the attacker does not need it. With binding, the hash of the
server's certificate is inside the material the client proof covers, so the
relay's proof is computed over the wrong certificate and the server refuses it.

- `prefer` (default under TLS) uses it when the server offers it
- `require` authenticates with `SCRAM-SHA-256-PLUS` or not at all
- `disable` never binds

`require` is a statement about the whole exchange, not only about SCRAM. The
server chooses which method to ask for, so somebody answering in its place can
ask for a cleartext password, for MD5, or for nothing, and none of those can
carry a binding. Under `require` each of them is refused before a byte of the
password is read: `{error, {channel_binding_required, Method}}`. A server that
offers SCRAM without `-PLUS`, and `require` on a connection with no TLS under
it, are refused the same way with nothing sent, `Method` being
`scram_sha_256`, which a pool reports as a failed connect.

A client that can bind but is offered no `-PLUS` mechanism sends `y,,` in the
gs2 header, which is how a server that *does* support binding learns its
mechanism list was stripped in transit.

## Which authentication methods are acceptable

`auth => [scram_sha_256]` accepts nothing else. The default accepts all four
that PostgreSQL offers, with one rule that is not configurable: **a cleartext
password is refused on a plain socket**, always. The password opens every future
connection too, so handing it to whoever is on the wire is worse than failing to
connect.

The default is permissive because a client cannot know how a server it has not
met is configured. A deployment does know, and should say so: the server picks
the method, so a client that accepts all of them will hand an MD5 response, or
over TLS the password itself, to anything that asks. `auth` is what libpq calls
`require_auth`:

| `auth` | `require_auth` | the server asked for |
| --- | --- | --- |
| `scram_sha_256` | `scram-sha-256` | SASL, with or without channel binding |
| `md5` | `md5` | an MD5 response |
| `cleartext` | `password` | the password itself |
| `none` | `none` | nothing: `trust`, or a method that needs no answer |

A method outside the list is refused with `{error, {auth_method_refused,
Method}}` before anything is sent in answer to it.

## A setting minato does not know

`channel_binding => required`, or `~"require"` as a configuration file or an
environment variable would hand it over, is not `require`. Reading it as the
default would be reading it as the weaker setting, so it is not read at all:
`channel_binding`, `ssl`, `auth`, `ssl_options` and `password` are checked
before a socket is opened, `minato_conn:connect/1` raises
`{minato_conn, #{message := options, reason := {invalid_option, Key}}}`, and a
pool or a listener does not start. In `ssl_options`, `verify` has to be
`verify_peer` or `verify_none`, and `{handshake, hello}` is refused because it
answers with a session that has verified nothing yet.

## What a server cannot make the client do

The server is not trusted either. It may be compromised, or it may be somebody
between the client and the real one, and everything it sends is read as input
that was chosen. For each of these there is a test with a server that tries.

- **Run out of memory on one message.** A message longer than
  `max_message_length`, 64 MiB unless raised, is refused from its header,
  before its payload is waited for.
- **Run out of memory on one value.** A `numeric` is held to the range
  PostgreSQL stores, 131072 digits before the point and 16383 after, whatever
  its header claims, and decodes in time linear in its length. An array has at
  most six dimensions and no more elements than the bytes that arrived could
  hold, so its header cannot ask for a list longer than the message.
- **Make atoms.** A command tag is read against the words PostgreSQL uses. One
  it does not use comes back as a binary: `command` and `num_rows` in a result
  are atoms and integers for every statement there is, and binaries for one a
  server invented. Column names are binaries, and under
  `column_name_as_atom` a name is looked up among the atoms that exist and
  left a binary when it is not one of them.
- **Keep a connect waiting.** `connect_timeout` covers the TCP connect and the
  TLS handshake together, and `timeout` the whole exchange from the startup
  message to `ReadyForQuery`, not each read of it. What the server reports
  about itself on the way is kept up to 64 parameters.
- **Keep a write waiting.** A write gets the connection's `timeout` and the
  connection is closed when it runs out, on both transports, with TLS and
  without.
- **Take a pool or a listener down.** An answer that is not a message ends the
  connection it arrived on, which is reconnected with backoff. The process
  holding it stays up, a listener's subscribers are told they were
  disconnected, and a pool's borrowers are not kept waiting on a server that
  has stopped answering the pool's own questions.
- **Choose a weaker authentication.** See the two sections above: the methods
  in `auth` are the only ones answered, and `channel_binding => require` is
  answered with a bound SCRAM exchange or not at all.

A value on its way to the server is held to the same limits: a message that
does not fit the protocol's length field, more than 65535 parameters, or a
startup parameter with a null byte in it is refused before anything is sent.

## Credentials

The password is used during authentication and is not stored on the connection,
so a pool holding a thousand connections holds one copy of it, in its options,
not a thousand. That copy is held as a fun, and neither `sys:get_status/1` on a
pool or listener nor its crash report shows it. A password given
as `fun(() -> binary())` is called once per connection attempt, which is what a
rotating credential needs: one read at start up and kept for a month is a
credential that expires while you hold it. Give a named function,
`fun my_app:db_password/0`, rather than a closure: it prints as its name, and it
still works after the module that made it is reloaded, where a closure from a
module that has been reloaded twice raises `badfun`.

## What reaches a log

**Parameters never do.** Not in a log and not in a telemetry event, unless
`log_values` below was turned on and one came back inside a failure. They are
the values themselves - the email address, the token, the amount.

**Values inside a failure only if you ask.** A server error quotes what it
refused: `detail` holds the row that broke a constraint and `message` the input
that would not parse. In a query event the error keeps the fields that name
things, `code`, `constraint`, `table` and the like, and loses those two and the
rest. A parameter that would not encode is raised with `redacted` where the
value was, because an uncaught raise is printed by whatever supervises the
caller. `{minato, [{log_values, true}]}` turns both off, for a development node
or an incident, and is read per call. The `{error, {pgsql_error, Fields}}` a
caller is returned is always whole.

**Statements only if you ask.** `{minato, [{log_statements, true}]}` puts the SQL
in query events. It is off by default because a statement is not a secret but
sits next to one: `WHERE email = $1` is fine to log, and the same statement
written by a caller who pasted the value in is a leak. It is read per call, so
it can be turned on while something is happening.

**Pool options are a child spec.** A pool or listener started under `minato_sup`
has its options in its child spec, and OTP's supervisor prints child specs: in
the progress report at start up, which a node logging at `debug` writes, when a
pool declared in the environment fails at boot, when a running pool is
restarted after an abnormal exit, and in `sys:get_status(minato_sup)`. minato
puts a password given as a binary or a string, and the whole of `ssl_options`,
which can hold a private key, into the child spec as funs that return them, so
each of those prints `#Fun<...>` where the secret would be. Pools, listeners
and connections hold them the same way. The application environment itself
still holds what `sys.config` gave it.

This is hygiene for logs and reports, not a security boundary. Anyone who can
run code on the node, from a remote shell or otherwise, can still read the
secrets: with `erlang:fun_info/2` on the fun, `sys:get_state/1` on a pool,
`term_to_binary/1`, or a crash dump. A pool started with `minato_pool:start_link/2` under your
own supervisor has your child spec, which holds the options as given.
`start_pool/2` and `start_listener/2` return the child's reason without the
child spec.

**Errors a caller can act on are returned, not logged.** A failing statement
comes back as a value. minato logs what nobody asked for and nobody else will
see: a pool that cannot connect, a listener that reconnected, a cached plan the
server refused.

## What minato does not do

- **No `SCRAM-SHA-256-PLUS` over a non-TLS transport**, because there is nothing
  to bind to.
- **No client certificate authentication.** `ssl_options` takes a `certfile` and
  PostgreSQL will use it, but nothing in minato tests that path.
- **No `sslmode=verify-ca` distinct from `verify-full`.** Verification checks the
  chain and the hostname; a deployment that wants the chain without the hostname
  can say so in `ssl_options` with a `customize_hostname_check` whose
  `match_fun` accepts any name, and should write down why.
- **No secret redaction pass over values you pass to `logger` yourself.** minato
  keeps its own output clean; what your handlers do with `{error, {pgsql_error,
  Fields}}` is yours.

## Verifying this yourself

`minato_tls_SUITE` runs against a PostgreSQL that generates its own certificate
authority when it starts, so there is no key in this repository to wonder about.
It proves a handshake that completes, a certificate verified against that CA
rather than accepted, a hostname that is checked, a certificate for another host
refused, and `channel_binding => require` connecting - which only succeeds if
the server negotiated `SCRAM-SHA-256-PLUS` and accepted the certificate hash the
client bound to.

## Reporting something

Open an issue for anything that is not exploitable. For anything that is, please
say so privately first through the repository's security advisories rather than
in a public issue.
