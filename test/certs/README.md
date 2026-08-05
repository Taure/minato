# Test certificates

Empty on purpose.

The TLS server in `docker-compose.yml` generates a certificate authority and a
`localhost` certificate signed by it when it starts, and writes `ca.crt` and
`server.crt` here. `minato_tls_SUITE` verifies against `ca.crt`, which is what a
deployment with a private CA does.

**The private keys never leave the container.** A key committed to a repository
is a key somebody has to reason about: a scanner flags it, a reader wonders, and
the answer is always "it is only a test key", which is a sentence nobody should
have to read. Generating them at start up costs a second and removes the
question.

`*.crt` and `*.key` here are ignored by git. `docker compose -f
test/docker-compose.yml rm -sf postgres-tls` and a fresh `up` gives you a new
pair.
