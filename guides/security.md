# Security

What minato does about the network, the credentials and the log, and which of
those you have to ask for.

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

## Channel binding

`SCRAM-SHA-256-PLUS` with `tls-server-end-point`, on by default under TLS.

Without it, SCRAM proves a shared password over whatever channel the client
happens to be on. A man in the middle holding a certificate the client accepts
can relay the entire exchange and keep the session: the password is never
revealed, and the attacker does not need it. With binding, the hash of the
server's certificate is inside the material the client proof covers, so the
relay's proof is computed over the wrong certificate and the server refuses it.

- `prefer` (default under TLS) uses it when the server offers it
- `require` refuses to connect without it
- `disable` never binds

A client that can bind but is offered no `-PLUS` mechanism sends `y,,` in the
gs2 header, which is how a server that *does* support binding learns its
mechanism list was stripped in transit.

## Which authentication methods are acceptable

`auth => [scram_sha_256]` accepts nothing else. The default accepts all four
that PostgreSQL offers, with one rule that is not configurable: **a cleartext
password is refused on a plain socket**, always. The password opens every future
connection too, so handing it to whoever is on the wire is worse than failing to
connect.

## Credentials

The password is used during authentication and is not stored on the connection,
so a pool holding a thousand connections holds no copies of it. A password given
as `fun(() -> binary())` is called once per connection attempt, which is what a
rotating credential needs: one read at start up and kept for a month is a
credential that expires while you hold it.

## What reaches a log

**Parameters never do.** Not in a log, not in a telemetry event, not in any
configuration. They are the values themselves - the email address, the token,
the amount.

**Statements only if you ask.** `{minato, [{log_statements, true}]}` puts the SQL
in query events. It is off by default because a statement is not a secret but
sits next to one: `WHERE email = $1` is fine to log, and the same statement
written by a caller who pasted the value in is a leak. It is read per call, so
it can be turned on while something is happening.

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
  can say so in `ssl_options`, and should write down why.
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
