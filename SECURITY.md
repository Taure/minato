# Security policy

## Supported versions

| version | fixes |
| --- | --- |
| the latest `1.x` release | yes |
| anything older | no; upgrade within `1.x`, which keeps the API |

A fix is released as a new patch version and the versions it replaces are
retired on Hex with a pointer to it.

## Reporting a vulnerability

Report it privately through GitHub: on
[the repository's Security tab](https://github.com/Taure/minato/security),
choose "Report a vulnerability". Please do not open a public issue or pull
request for it.

Say what you did, what happened, and which version and OTP release it was on. A
failing test is the best report there is.

You will get an answer within seven days. A confirmed report gets a fix, a
GitHub security advisory naming the patched version, and credit in it unless
you would rather not be named.

## What counts

minato sits between an application and a PostgreSQL server and trusts neither
the network nor the server. These are in scope:

- **A hostile or compromised server**, or anyone able to answer in its place:
  running the client out of memory or atoms, keeping a caller waiting past its
  timeouts, taking down a pool or a listener, or leaving a connection that
  answers the next caller with somebody else's result.
- **Somebody on the connection**: turning TLS off, getting a certificate for
  another name accepted, relaying or downgrading authentication, or learning
  the password.
- **A value an application passes through unchecked**: a parameter that changes
  what is sent beyond its own bytes, costs memory or time out of proportion to
  its size, or reaches the server as SQL.
- **Secrets and values where they should not be**: a password, a private key,
  a statement parameter or row data in a log, a telemetry event, a crash
  report or a status call.

These are not: an application that builds SQL by pasting values into the text
it gives `minato:simple/2`; a caller that turns verification off in
`ssl_options`; anybody who can already run code on the node.

## The setting for production

The defaults connect to any PostgreSQL there is, and that is what they are for.
They are not the setting for a network anybody else is on. In a connection's
options, that is:

```erlang
#{ssl => true,
  auth => [scram_sha_256],
  channel_binding => require}
```

`ssl => true` verifies the server's certificate against the OS trust store and
checks its name, `auth` stops a server from choosing a weaker method than
SCRAM, and `channel_binding => require` ties the SCRAM exchange to that
certificate so it cannot be relayed.

What the defaults leave open, to somebody on the path between the client and
the server:

- Without `ssl => true` nothing is encrypted: every statement, parameter and
  row can be read and changed, and an MD5 or SCRAM exchange can be relayed to
  the real server, which gives the relay a session as that user without the
  password.
- With `ssl => true` and the default `auth`, whoever holds a certificate the
  client accepts can ask for the password itself and is given it.
- `channel_binding` is `prefer` under TLS: it binds when the server offers to,
  and somebody answering in the server's place does not offer.

A pool started without `ssl` in its options, towards a host that is not this
machine, logs one warning saying so. `ssl => false` written out is taken as a
decision and logs nothing.

[The security guide](guides/security.md) says what minato does about each of
these and how to check it.
