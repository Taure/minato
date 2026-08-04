-module(minato_protocol_frontend).
-moduledoc """
Encoders for the messages a client sends to a PostgreSQL server.

Internal to minato. The supported surface is `m:minato_protocol`.

## Shape

Every message but three is a type byte, a 32 bit length and a payload. The
length counts itself and the payload but not the type byte, which is why every
encoder here adds four to the payload size.

`StartupMessage`, `SSLRequest` and `CancelRequest` carry no type byte, because
they are sent before the connection has agreed what version of the protocol it
is speaking. A server tells them apart by the 32 bit code that follows the
length: 196608 for protocol 3.0, 80877103 to ask for TLS, and 80877102 to
cancel a query on another connection.

## Payloads

Strings are null terminated. Counted sequences carry a 16 bit count first.
Parameter values in `Bind` carry a 32 bit length each, and a length of -1 is
NULL, which is why `null` is a parameter value rather than an empty binary. The
SASL data in `SASLInitialResponse` is written the same way, and -1 there means
the mechanism sent no data at all.

Format codes are 0 for text and 1 for binary. `Bind` takes them as lists, and
the protocol reads the length of those lists: an empty list means every value
is text, a single element applies to every value, and any other length has to
match the number of values.

## What is not enforced

An encoder writes the message it is given. It does not check that
`StartupMessage` names a user, that a `Bind` has as many parameters as the
statement was parsed with, or that a portal exists. Those belong to whatever
drives the exchange, which knows the session; this module only knows bytes.
""".

-export([encode/1]).

-define(PROTOCOL_VERSION, 196608).
-define(SSL_REQUEST, 80877103).
-define(CANCEL_REQUEST, 80877102).

-doc "Encode one frontend message.".
-spec encode(minato_protocol:frontend()) -> iodata().
encode({startup, Parameters}) ->
    untyped([<<?PROTOCOL_VERSION:32>>, startup_parameters(Parameters), 0]);
encode(ssl_request) ->
    <<8:32, ?SSL_REQUEST:32>>;
encode({cancel_request, Pid, Secret}) ->
    <<16:32, ?CANCEL_REQUEST:32, Pid:32, Secret:32>>;
encode({password, Password}) ->
    typed($p, [Password, 0]);
encode({sasl_initial_response, Mechanism, Data}) ->
    typed($p, [Mechanism, 0, length_prefixed(Data)]);
encode({sasl_response, Data}) ->
    typed($p, Data);
encode({query, Query}) ->
    typed($Q, [Query, 0]);
encode({parse, Name, Query, Parameters}) ->
    typed($P, [Name, 0, Query, 0, count(Parameters), [<<Oid:32>> || Oid <- Parameters]]);
encode({bind, Portal, Statement, ParameterFormats, Parameters, ResultFormats}) ->
    typed($B, [
        Portal,
        0,
        Statement,
        0,
        formats(ParameterFormats),
        count(Parameters),
        [length_prefixed(Parameter) || Parameter <- Parameters],
        formats(ResultFormats)
    ]);
encode({describe, Target, Name}) ->
    typed($D, [target(Target), Name, 0]);
encode({execute, Portal, MaxRows}) ->
    typed($E, [Portal, 0, <<MaxRows:32>>]);
encode(sync) ->
    <<$S, 4:32>>;
encode(flush) ->
    <<$H, 4:32>>;
encode({close, Target, Name}) ->
    typed($C, [target(Target), Name, 0]);
encode(terminate) ->
    <<$X, 4:32>>.

-spec typed(byte(), iodata()) -> iodata().
typed(Type, Payload) ->
    [<<Type, (iolist_size(Payload) + 4):32>>, Payload].

-spec untyped(iodata()) -> iodata().
untyped(Payload) ->
    [<<(iolist_size(Payload) + 4):32>>, Payload].

-spec startup_parameters(#{binary() => binary()}) -> iodata().
startup_parameters(Parameters) ->
    [[Name, 0, Value, 0] || Name := Value <- Parameters].

-spec count([term()]) -> binary().
count(Values) ->
    <<(length(Values)):16>>.

-spec formats([minato_codec:format()]) -> iodata().
formats(Formats) ->
    [count(Formats), [<<(format_code(Format)):16>> || Format <- Formats]].

-spec format_code(minato_codec:format()) -> 0..1.
format_code(text) -> 0;
format_code(binary) -> 1.

-spec length_prefixed(iodata() | null) -> iodata().
length_prefixed(null) -> <<-1:32/signed>>;
length_prefixed(Value) -> [<<(iolist_size(Value)):32>>, Value].

-spec target(minato_protocol:target()) -> byte().
target(statement) -> $S;
target(portal) -> $P.
