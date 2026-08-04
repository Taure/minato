-module(minato_scram).
-moduledoc """
SCRAM-SHA-256 (RFC 5802, RFC 7677) as a pure function of messages.

Bytes in, bytes out. No socket, no process, no state outside the value the
caller threads through the three calls, so the whole exchange can be tested
against the published vectors and against a hostile server without either one.

## The exchange

Four messages, three calls:

```erlang
{ClientFirst, Client} = minato_scram:client_first(~"minato", #{}),
%% send ClientFirst, receive ServerFirst
{ClientFinal, Check} = minato_scram:client_final(ServerFirst, ~"pencil", Client),
%% send ClientFinal, receive ServerFinal
ok = minato_scram:server_final(ServerFinal, Check).
```

`m:minato_auth` drives those calls from the `AuthenticationSASL` messages the
server sends, and is what a connection uses. This module is the mechanism on its
own.

## What the client checks

Authentication is mutual, and both directions are enforced here.

- **The server nonce must extend the client nonce.** The server answers with the
  client's nonce and its own appended. A server that returns something else has
  not seen the client's first message, which is what a replay or a
  man in the middle looks like, so `client_final/3` raises rather than
  continuing.
- **The server signature must verify.** `server_final/2` recomputes
  `ServerSignature` and compares it, in constant time, with the value the server
  sent. Only a party that holds `ServerKey` can produce it, so this is what
  proves the server is the one that stored the verifier. Skipping the check
  leaves a client that will complete a handshake with anybody, which is a
  downgrade to no server authentication at all, so a mismatch raises and there
  is no option to turn it off.
- **The iteration count must be in range.** See below.

## The iteration count

`i` decides how much work an offline attack on the stored verifier costs, and
the server chooses it, so a hostile or compromised server can choose badly in
either direction.

The floor is 4096, which is what RFC 7677 says a server SHOULD announce and what
PostgreSQL's `scram_iterations` defaults to. Below it the derivation is cheaper
to brute force than the specification allows for, and since PostgreSQL will not
put a lower value there by default, a lower value is a signal rather than a
configuration.

The ceiling is 1,000,000, roughly 180ms of PBKDF2 on a current machine and some
240 times PostgreSQL's default. It exists because `i` is an unbounded number
chosen by the far end and fed straight into a loop: without a ceiling a server
that answers `i=2000000000` costs the client minutes of CPU per connection
attempt for free.

Both move with `minimum_iterations` and `maximum_iterations` in `t:opts/0`, for
a server that is deliberately configured away from the defaults.

The digits are counted before they are parsed, and more than 20 of them are
rejected without being read. Turning a decimal string into an integer costs more
than linear time in its length, so a server that answers with a megabyte of
digits would otherwise be paid for out of the client's CPU before the ceiling
above ever got a number to compare.

## Channel binding

Not implemented. The client advertises `n,,`: no channel binding, no authzid.

That leaves the mechanism open to a man in the middle who holds a certificate
the client will accept, because nothing in the handshake is tied to the TLS
channel underneath it. PostgreSQL offers `SCRAM-SHA-256-PLUS` with
`tls-server-end-point` binding for exactly that, and no Erlang client implements
it, so it is a real differentiator rather than a box to tick. It needs the
server certificate from the TLS session, which is why it belongs with the
connection layer rather than here.

## What is not an error here

A wrong password is not. The server answers a bad `ClientProof` with an ordinary
`ErrorResponse`, which `m:minato_protocol` decodes as data for the caller to
branch on. Everything this module raises on is a server that broke the protocol
or failed to prove itself.

## Secrets in the state

`t:client/0` never holds the password, which is why `client_final/3` takes it
rather than `client_first/2`. Nothing derived from it survives that call either:
what is carried forward to `server_final/2` is the expected `ServerSignature`
alone, which the server is about to send in the clear anyway. The value is
therefore safe to log, and no scrubbing is needed for one that is not.
""".

-export([client_first/2, client_first/3, client_final/3, server_final/2]).

-define(GS2_HEADER, ~"n,,").
-define(NONCE_BYTES, 24).
-define(KEY_LENGTH, 32).
-define(MINIMUM_ITERATIONS, 4096).
-define(MAXIMUM_ITERATIONS, 1000000).
-define(MAXIMUM_DIGITS, 20).

-record(first, {
    nonce :: binary(),
    bare :: binary(),
    minimum_iterations :: pos_integer(),
    maximum_iterations :: pos_integer()
}).

-record(final, {signature :: binary()}).

-doc """
A SCRAM exchange in progress.

Holds no password and nothing derived from one. See the module documentation.
""".
-opaque client() :: #first{} | #final{}.

-doc """
Bounds on the iteration count a server may ask for.

```erlang
#{minimum_iterations => pos_integer(),
  maximum_iterations => pos_integer()}
```

Defaulting to 4096 and 1,000,000. See the module documentation for why both
ends are checked.
""".
-type opts() :: #{
    minimum_iterations => pos_integer(),
    maximum_iterations => pos_integer()
}.

-doc "The map carried by an `error({minato_scram, Report})` exception.".
-type report() :: #{message := term(), reason := term(), data := term()}.

-export_type([client/0, opts/0, report/0]).

-doc """
Build the `client-first-message` and the state the rest of the exchange needs.

```erlang
1> {Message, _Client} = minato_scram:client_first(~"minato", #{}),
1> iolist_to_binary(Message).
<<"n,,n=minato,r=ZU1VevH/T4oYMaHeqfcBbLlQCqZ3APDo">>
```

The nonce is 24 bytes of `crypto:strong_rand_bytes/1`, base64 encoded, which is
192 bits of entropy in 32 of the printable characters RFC 5802 allows. A nonce
is what stops an answer to an earlier exchange being replayed into this one, so
it comes from the strong generator and never from `m:rand`.

The user name goes in `n=` with `=` and `,` escaped as RFC 5802 requires, so
that the message matches the published vectors. PostgreSQL then ignores it and
uses the name from the startup packet instead, which it documents, because
SCRAM requires UTF-8 there and a PostgreSQL user name need not be representable
in it. Nothing therefore depends on this field, and it is passed through rather
than prepared with `m:minato_saslprep`: preparing it could only change bytes the
server does not read.
""".
-spec client_first(binary(), opts()) -> {iodata(), client()}.
client_first(Username, Opts) ->
    client_first(Username, base64:encode(crypto:strong_rand_bytes(?NONCE_BYTES)), Opts).

-doc """
Internal. `client_first/2` with the client nonce given rather than generated.

Exported so that the RFC 7677 test vectors, which fix the client nonce, can be
reproduced exactly. A nonce that is not freshly random defeats the entire point
of the exchange, so nothing outside a test may call this.
""".
-spec client_first(binary(), binary(), opts()) -> {iodata(), client()}.
client_first(Username, Nonce, Opts) ->
    Bare = <<"n=", (saslname(Username))/binary, ",r=", Nonce/binary>>,
    Client = #first{
        nonce = Nonce,
        bare = Bare,
        minimum_iterations = maps:get(minimum_iterations, Opts, ?MINIMUM_ITERATIONS),
        maximum_iterations = maps:get(maximum_iterations, Opts, ?MAXIMUM_ITERATIONS)
    },
    {[?GS2_HEADER, Bare], Client}.

-doc """
Read the `server-first-message` and answer it with the `client-final-message`.

```erlang
1> {Message, _Check} = minato_scram:client_final(ServerFirst, ~"pencil", Client),
1> iolist_to_binary(Message).
<<"c=biws,r=...,p=...">>
```

Raises `error({minato_scram, t:report/0})` when the server nonce does not extend
the client nonce, when the iteration count is outside `t:opts/0`, when the salt
is not base64, when the server asks for a mandatory extension, or when the
message does not parse.

The password is prepared with `m:minato_saslprep` before it is salted.
""".
-spec client_final(binary(), binary(), client()) -> {iodata(), client()}.
client_final(ServerFirst, Password, #first{} = Client) ->
    #first{bare = Bare} = Client,
    {ServerNonce, Salt, Iterations} = server_first(ServerFirst, Client),
    Salted = crypto:pbkdf2_hmac(
        sha256, minato_saslprep:prepare(Password), Salt, Iterations, ?KEY_LENGTH
    ),
    ClientKey = crypto:mac(hmac, sha256, Salted, ~"Client Key"),
    StoredKey = crypto:hash(sha256, ClientKey),
    WithoutProof = <<"c=", (base64:encode(?GS2_HEADER))/binary, ",r=", ServerNonce/binary>>,
    AuthMessage = <<Bare/binary, ",", ServerFirst/binary, ",", WithoutProof/binary>>,
    Proof = crypto:exor(ClientKey, crypto:mac(hmac, sha256, StoredKey, AuthMessage)),
    ServerKey = crypto:mac(hmac, sha256, Salted, ~"Server Key"),
    Signature = crypto:mac(hmac, sha256, ServerKey, AuthMessage),
    Message = <<WithoutProof/binary, ",p=", (base64:encode(Proof))/binary>>,
    {Message, #final{signature = Signature}};
client_final(ServerFirst, _Password, _Client) ->
    bad(client_final, out_of_order, ServerFirst).

-doc """
Verify the `server-final-message`, which is what authenticates the server.

Answers `ok`, and raises `error({minato_scram, t:report/0})` otherwise: on a
`ServerSignature` that does not match, on the `e=` form in which a server
reports its own failure, and on a message that does not parse.

The comparison runs in constant time through `crypto:hash_equals/2`. A byte at a
time comparison would leak how much of a forged signature was right, which is
enough to build the rest of it one byte per attempt.
""".
-spec server_final(binary(), client()) -> ok.
server_final(ServerFinal, #final{signature = Expected}) ->
    case binary:split(ServerFinal, ~",", [global]) of
        [<<$v, $=, Verifier/binary>> | _Extensions] ->
            verify(Verifier, Expected, ServerFinal);
        [<<$e, $=, Error/binary>> | _Extensions] ->
            bad(server_final, {server_error, Error}, ServerFinal);
        _Attributes ->
            bad(server_final, malformed, ServerFinal)
    end;
server_final(ServerFinal, _Client) ->
    bad(server_final, out_of_order, ServerFinal).

-spec verify(binary(), binary(), binary()) -> ok.
verify(Verifier, Expected, ServerFinal) ->
    case decoded(Verifier, server_final, ServerFinal) of
        Signature when byte_size(Signature) =:= byte_size(Expected) ->
            matched(crypto:hash_equals(Signature, Expected), ServerFinal);
        Signature ->
            bad(server_final, server_signature_mismatch, {byte_size(Signature), ServerFinal})
    end.

-spec matched(boolean(), binary()) -> ok.
matched(true, _ServerFinal) -> ok;
matched(false, ServerFinal) -> bad(server_final, server_signature_mismatch, ServerFinal).

-spec server_first(binary(), #first{}) -> {binary(), binary(), pos_integer()}.
server_first(ServerFirst, Client) ->
    case binary:split(ServerFirst, ~",", [global]) of
        [<<$m, $=, Extension/binary>> | _Rest] ->
            bad(server_first, {mandatory_extension, Extension}, ServerFirst);
        [<<$r, $=, Nonce/binary>>, <<$s, $=, Salt/binary>>, <<$i, $=, Count/binary>> | _Rest] ->
            ServerNonce = extending(Nonce, Client, ServerFirst),
            Iterations = iterations(Count, Client, ServerFirst),
            {ServerNonce, decoded(Salt, server_first, ServerFirst), Iterations};
        _Attributes ->
            bad(server_first, malformed, ServerFirst)
    end.

-spec extending(binary(), #first{}, binary()) -> binary().
extending(ServerNonce, #first{nonce = Nonce}, ServerFirst) ->
    Size = byte_size(Nonce),
    case ServerNonce of
        <<Nonce:Size/binary, _Server/binary>> when byte_size(ServerNonce) > Size ->
            ServerNonce;
        _Other ->
            bad(server_first, server_nonce_does_not_extend_client_nonce, ServerFirst)
    end.

-spec iterations(binary(), #first{}, binary()) -> pos_integer().
iterations(Count, _Client, ServerFirst) when byte_size(Count) > ?MAXIMUM_DIGITS ->
    bad(server_first, {iteration_count_too_long, byte_size(Count)}, ServerFirst);
iterations(Count, Client, ServerFirst) ->
    #first{minimum_iterations = Minimum, maximum_iterations = Maximum} = Client,
    case digits(Count) of
        true ->
            bounded(binary_to_integer(Count), Minimum, Maximum, ServerFirst);
        false ->
            bad(server_first, {iteration_count_not_a_number, Count}, ServerFirst)
    end.

-spec bounded(integer(), pos_integer(), pos_integer(), binary()) -> pos_integer().
bounded(Count, Minimum, Maximum, _ServerFirst) when Count >= Minimum, Count =< Maximum ->
    Count;
bounded(Count, Minimum, _Maximum, ServerFirst) when Count < Minimum ->
    bad(server_first, {iteration_count_below_minimum, Count, Minimum}, ServerFirst);
bounded(Count, _Minimum, Maximum, ServerFirst) ->
    bad(server_first, {iteration_count_above_maximum, Count, Maximum}, ServerFirst).

-spec digits(binary()) -> boolean().
digits(~"") -> false;
digits(Count) -> only_digits(Count).

-spec only_digits(binary()) -> boolean().
only_digits(~"") -> true;
only_digits(<<Digit, Rest/binary>>) when Digit >= $0, Digit =< $9 -> only_digits(Rest);
only_digits(_Count) -> false.

-spec decoded(binary(), atom(), binary()) -> binary().
decoded(Value, Message, Data) ->
    try
        base64:decode(Value)
    catch
        error:_Reason -> bad(Message, {not_base64, Value}, Data)
    end.

-spec saslname(binary()) -> binary().
saslname(Username) ->
    Escaped = binary:replace(Username, ~"=", ~"=3D", [global]),
    binary:replace(Escaped, ~",", ~"=2C", [global]).

-spec bad(term(), term(), term()) -> no_return().
bad(Message, Reason, Data) ->
    error({minato_scram, #{message => Message, reason => Reason, data => Data}}).
