-module(minato_auth).
-moduledoc """
The authentication exchange, as a fold over the messages the server sends.

`m:minato_protocol` decodes an `Authentication*` message; this module decides
what to answer with. It does no I/O and starts no process, so the whole cycle,
including the ones that need several round trips, can be driven in a test
without a socket.

```erlang
State = minato_auth:init(#{user => ~"minato", password => ~"pencil"}),
{send, Reply, Next} = minato_auth:step(Message, State),
%% write minato_protocol:encode(Reply), read the next message, step again
```

`step/2` answers one of three things:

- `{send, Reply, State}` to write `Reply` and wait for the next message
- `{continue, State}` when the server's message needed no answer, which is what
  `AuthenticationSASLFinal` is
- `authenticated` on `AuthenticationOk`, after which the caller reads
  `ParameterStatus`, `BackendKeyData` and `ReadyForQuery` as usual

An `ErrorResponse` from the server is not handled here. It is an ordinary
decoded message and the caller branches on it: a wrong password arrives that
way, not as an exception.

## A started SASL exchange has to finish

`AuthenticationOk` is refused while a SCRAM exchange is outstanding, and that
refusal is load bearing rather than tidiness. The check that authenticates the
server to the client lives in `AuthenticationSASLFinal`, so a server that cannot
produce a valid `ServerSignature` has an obvious move available: send
`AuthenticationOk` instead and never send the final message at all. A client
that accepted it would have proved itself to an impostor and gone on to send it
queries, which is exactly the outcome verifying the signature is meant to
prevent. Only an exchange that reached `verified`, or one that never started
because the server asked for no password, ends in `authenticated`.

## Methods

| Server asks for | minato answers with |
| --- | --- |
| `AuthenticationOk` | nothing, the cycle is over |
| `AuthenticationCleartextPassword` | the password, unmodified |
| `AuthenticationMD5Password` | the salted MD5 digest |
| `AuthenticationSASL` | `SCRAM-SHA-256`, through `m:minato_scram` |

SCRAM-SHA-256 is the one that matters: it is what `password_encryption` has
defaulted to since PostgreSQL 14, and CloudNativePG issues nothing else. The
other two are here because a PostgreSQL is not always a recent PostgreSQL, and
they cost a handful of lines each.

MD5 is broken as a hash and PostgreSQL has deprecated it, so a server asking for
it is one to reconfigure rather than one to trust. minato answers anyway,
because refusing would only mean a connection that cannot be made at all,
whereas the server has already decided what it will accept.

GSSAPI, SSPI and the rest of the `Authentication` codes never reach this module:
`m:minato_protocol` models the four above and raises on any other code as it
decodes, because there is no useful reply to build and a message silently passed
on would look to a caller like a hung connection. A message that is not an
authentication message at all raises here, for the same reason.

## Channel binding

`SCRAM-SHA-256-PLUS` is not implemented, so it is not chosen even when the
server offers it. Choosing it would need the server certificate from the TLS
session, which lives with the connection rather than here. `m:minato_scram`
documents what that leaves open.
""".

-export([init/1, step/2]).

-define(SCRAM_SHA_256, ~"SCRAM-SHA-256").

-record(state, {
    user :: binary(),
    password :: binary() | undefined,
    scram_opts :: minato_scram:opts(),
    sasl :: sasl()
}).

-type sasl() :: none | {pending, minato_scram:client()} | verified.

-doc """
Who to authenticate as.

```erlang
#{user := binary(),
  password => binary(),
  scram => minato_scram:opts()}
```

`password` is absent for a server that asks for none, and a server that then
asks for one raises rather than sending an empty string. `scram` is passed to
`m:minato_scram` and is only worth setting for a server deliberately configured
away from its iteration count defaults.
""".
-type credentials() :: #{
    user := binary(),
    password => binary(),
    scram => minato_scram:opts()
}.

-doc "The exchange so far. Never holds anything derived from the password.".
-opaque state() :: #state{}.

-doc "What to do with the message that was just decoded.".
-type step() ::
    {send, minato_protocol:frontend(), state()}
    | {continue, state()}
    | authenticated.

-doc "The map carried by an `error({minato_auth, Report})` exception.".
-type report() :: #{message := term(), reason := term(), data := term()}.

-export_type([credentials/0, state/0, step/0, report/0]).

-doc """
Begin an authentication exchange.

Nothing is sent and nothing is derived yet: the server has not said what it
wants, and every method but one needs something from it first.
""".
-spec init(credentials()) -> state().
init(#{user := User} = Credentials) ->
    #state{
        user = User,
        password = maps:get(password, Credentials, undefined),
        scram_opts = maps:get(scram, Credentials, #{}),
        sasl = none
    }.

-doc """
Answer one `Authentication*` message.

Raises `error({minato_auth, t:report/0})` when the server asks for a method
minato does not implement, when it asks for a password that was not configured,
when it offers no SASL mechanism minato can speak, or when a SASL message
arrives outside an exchange. Raises `error({minato_scram, _})` for a server that
breaks SCRAM or fails to prove itself; see `m:minato_scram`.
""".
-spec step(minato_protocol:backend(), state()) -> step().
step(authentication_ok, #state{sasl = none}) ->
    authenticated;
step(authentication_ok, #state{sasl = verified}) ->
    authenticated;
step(authentication_ok, #state{user = User}) ->
    bad(authentication_ok, sasl_exchange_unfinished, User);
step(authentication_cleartext_password, State) ->
    {send, {password, password(State, authentication_cleartext_password)}, State};
step({authentication_md5_password, Salt}, #state{user = User} = State) ->
    Password = password(State, authentication_md5_password),
    {send, {password, md5(User, Password, Salt)}, State};
step({authentication_sasl, Mechanisms}, #state{user = User} = State) ->
    Mechanism = mechanism(Mechanisms, User),
    {Message, Client} = minato_scram:client_first(User, State#state.scram_opts),
    {send, {sasl_initial_response, Mechanism, Message}, State#state{sasl = {pending, Client}}};
step({authentication_sasl_continue, Data}, #state{sasl = Sasl} = State) ->
    sasl_continue(Sasl, Data, State);
step({authentication_sasl_final, Data}, #state{sasl = Sasl} = State) ->
    sasl_final(Sasl, Data, State);
step(Message, #state{user = User}) ->
    bad(Message, unsupported_method, User).

-spec sasl_continue(sasl(), binary(), state()) -> step().
sasl_continue({pending, Client}, Data, State) ->
    Password = password(State, authentication_sasl_continue),
    {Message, Next} = minato_scram:client_final(Data, Password, Client),
    {send, {sasl_response, Message}, State#state{sasl = {pending, Next}}};
sasl_continue(_Sasl, _Data, #state{user = User}) ->
    bad(authentication_sasl_continue, sasl_exchange_not_started, User).

-spec sasl_final(sasl(), binary(), state()) -> step().
sasl_final({pending, Client}, Data, State) ->
    ok = minato_scram:server_final(Data, Client),
    {continue, State#state{sasl = verified}};
sasl_final(_Sasl, _Data, #state{user = User}) ->
    bad(authentication_sasl_final, sasl_exchange_not_started, User).

-spec mechanism([binary()], binary()) -> binary().
mechanism(Mechanisms, User) ->
    case lists:member(?SCRAM_SHA_256, Mechanisms) of
        true -> ?SCRAM_SHA_256;
        false -> bad(authentication_sasl, {no_supported_mechanism, Mechanisms}, User)
    end.

-spec password(state(), atom()) -> binary().
password(#state{password = undefined, user = User}, Message) ->
    bad(Message, password_required, User);
password(#state{password = Password}, _Message) ->
    Password.

-spec md5(binary(), binary(), binary()) -> binary().
md5(User, Password, Salt) ->
    Inner = binary:encode_hex(crypto:hash(md5, <<Password/binary, User/binary>>), lowercase),
    Outer = binary:encode_hex(crypto:hash(md5, <<Inner/binary, Salt/binary>>), lowercase),
    <<"md5", Outer/binary>>.

-spec bad(term(), term(), term()) -> no_return().
bad(Message, Reason, Data) ->
    error({minato_auth, #{message => Message, reason => Reason, data => Data}}).
