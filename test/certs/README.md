# Test certificates

A certificate authority and a server certificate for `localhost`, generated for
these tests and valid for ten years.

**These are not secrets.** The private keys are in this repository on purpose:
the TLS suite needs a server certificate it can verify against a CA it knows,
and the compose file starts a PostgreSQL with them. They are trusted by nothing
except `minato_tls_SUITE`, they name only `localhost`, and anybody can generate
an identical set in ten seconds.

To regenerate:

```
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout ca.key -out ca.crt -subj "/CN=minato test CA" \
    -addext "basicConstraints=critical,CA:TRUE"

openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr \
    -subj "/CN=localhost"

printf "subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n" > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 3650 -sha256 -extfile server.ext
rm server.csr server.ext ca.srl
```
