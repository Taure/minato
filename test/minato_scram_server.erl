-module(minato_scram_server).
-moduledoc """
The server half of SCRAM-SHA-256, written for the tests.

`m:minato_scram` is the client half, and a client checked only against itself
proves nothing. This is a separate reading of RFC 5802 from the other side of
the exchange: it stores a verifier the way a server does, challenges with its
own nonce, and verifies `ClientProof` by reconstructing `ClientKey` from it
rather than by recomputing the proof. A property that runs the two against each
other therefore fails if either one has the derivation wrong.

It is deliberately not a hardened server. It has no timeouts, no user lookup and
no defence against anything, because nothing here is ever on a socket.

`challenge/3` builds a `server-first-message` from parts, which is how the
negative tests produce a hostile server without hand-writing the derivation
again.
""".

-export([new/1, new/2, first/2, final/2, challenge/3, stored_key/1, server_key/1]).

-define(SALT_BYTES, 16).
-define(NONCE_BYTES, 18).
-define(ITERATIONS, 4096).
-define(KEY_LENGTH, 32).

-record(server, {
    salt :: binary(),
    iterations :: pos_integer(),
    stored_key :: binary(),
    server_key :: binary(),
    nonce = ~"" :: binary(),
    bare = ~"" :: binary(),
    server_first = ~"" :: binary()
}).

-opaque server() :: #server{}.
-export_type([server/0]).

-doc "A server holding a verifier for `Password`, with a random salt.".
-spec new(binary()) -> server().
new(Password) ->
    new(Password, #{}).

-doc """
A server holding a verifier for `Password`.

`salt`, `iterations` and `nonce` override what would otherwise be generated, so
a test can pin the exchange to published values.
""".
-spec new(binary(), map()) -> server().
new(Password, Opts) ->
    Salt = maps:get(salt, Opts, crypto:strong_rand_bytes(?SALT_BYTES)),
    Iterations = maps:get(iterations, Opts, ?ITERATIONS),
    Salted = crypto:pbkdf2_hmac(
        sha256, minato_saslprep:prepare(Password), Salt, Iterations, ?KEY_LENGTH
    ),
    #server{
        salt = Salt,
        iterations = Iterations,
        stored_key = crypto:hash(sha256, crypto:mac(hmac, sha256, Salted, ~"Client Key")),
        server_key = crypto:mac(hmac, sha256, Salted, ~"Server Key"),
        nonce = maps:get(nonce, Opts, base64:encode(crypto:strong_rand_bytes(?NONCE_BYTES)))
    }.

-doc "The `StoredKey` this server holds, for comparing against a server's own verifier.".
-spec stored_key(server()) -> binary().
stored_key(#server{stored_key = StoredKey}) -> StoredKey.

-doc "The `ServerKey` this server holds.".
-spec server_key(server()) -> binary().
server_key(#server{server_key = ServerKey}) -> ServerKey.

-doc "Answer a `client-first-message` with a `server-first-message`.".
-spec first(binary(), server()) -> {binary(), server()}.
first(ClientFirst, Server) ->
    Bare = bare(ClientFirst),
    ClientNonce = attribute($r, Bare),
    Nonce = <<ClientNonce/binary, (Server#server.nonce)/binary>>,
    ServerFirst = challenge(Nonce, Server#server.salt, Server#server.iterations),
    {ServerFirst, Server#server{nonce = Nonce, bare = Bare, server_first = ServerFirst}}.

-doc "Build a `server-first-message` from its three parts.".
-spec challenge(binary(), binary(), integer()) -> binary().
challenge(Nonce, Salt, Iterations) ->
    Encoded = base64:encode(Salt),
    Count = integer_to_binary(Iterations),
    <<"r=", Nonce/binary, ",s=", Encoded/binary, ",i=", Count/binary>>.

-doc """
Verify a `client-final-message` and answer it.

`{error, invalid_proof}` is the failure a server reports as `e=invalid-proof`,
and `{error, invalid_nonce}` is a client that did not echo the full nonce back.
""".
-spec final(binary(), server()) -> {ok, binary()} | {error, atom()}.
final(ClientFinal, Server) ->
    [WithoutProof, Proof] = binary:split(ClientFinal, ~",p="),
    case attribute($r, WithoutProof) =:= Server#server.nonce of
        true -> proved(base64:decode(Proof), auth_message(WithoutProof, Server), Server);
        false -> {error, invalid_nonce}
    end.

-spec proved(binary(), binary(), server()) -> {ok, binary()} | {error, atom()}.
proved(Proof, AuthMessage, #server{stored_key = StoredKey, server_key = ServerKey}) ->
    ClientKey = crypto:exor(Proof, crypto:mac(hmac, sha256, StoredKey, AuthMessage)),
    case crypto:hash(sha256, ClientKey) =:= StoredKey of
        true ->
            Signature = base64:encode(crypto:mac(hmac, sha256, ServerKey, AuthMessage)),
            {ok, <<"v=", Signature/binary>>};
        false ->
            {error, invalid_proof}
    end.

-spec auth_message(binary(), server()) -> binary().
auth_message(WithoutProof, #server{bare = Bare, server_first = ServerFirst}) ->
    <<Bare/binary, ",", ServerFirst/binary, ",", WithoutProof/binary>>.

-spec bare(binary()) -> binary().
bare(<<"n,,", Bare/binary>>) -> Bare.

-spec attribute(byte(), binary()) -> binary().
attribute(Key, Message) ->
    [Value] = [V || <<K, $=, V/binary>> <- binary:split(Message, ~",", [global]), K =:= Key],
    Value.
