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

## Lengths are checked, not truncated

A length is 32 bits on the wire and a count is 16, and a number that does not
fit would be written modulo the field: a parameter over 4 GiB would announce a
short message, and the server would read the rest of it as messages of its own.
So nothing is ever written modulo anything. A message longer than
1,073,741,823 bytes, which is the longest PostgreSQL itself accepts, raises
`error({minato_protocol, #{reason := message_too_long}})`, and a `Parse` or
`Bind` with more than 65,535 parameters or format codes raises
`too_many_values`. Both are raised while encoding, so nothing of the message
has been sent. A parameter is part of its `Bind`, so the same bound covers it.

## A string cannot end early

Strings are null terminated, so a null byte inside one ends it where the caller
did not mean it to. In a `StartupMessage` that is worse than a truncated name:
the bytes after it are read as the next parameter, so a database name taken
from outside could carry an `options` of its own. A startup parameter whose name
or value holds a null byte, and a name that is empty, raise
`error({minato_protocol, #{message := startup}})` naming the parameter and not
its value.

The other strings are a statement's text and the names of statements and
portals, in `Query`, `Parse`, `Bind`, `Describe`, `Execute` and `Close`. One
that holds a null byte raises
`error({minato_protocol, #{message := Message, reason := null_byte, data :=
Field}})`, where `Field` is `query`, `name`, `portal` or `statement`, before
anything is sent. A parameter value is length prefixed and may hold any byte.

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
-define(LONGEST_MESSAGE, 16#3FFFFFFF).
-define(MOST_VALUES, 16#FFFF).

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
    typed($Q, string(query, query, Query));
encode({parse, Name, Query, Parameters}) ->
    typed($P, [
        string(parse, name, Name),
        string(parse, query, Query),
        count(Parameters),
        [<<Oid:32>> || Oid <- Parameters]
    ]);
encode({bind, Portal, Statement, ParameterFormats, Parameters, ResultFormats}) ->
    typed($B, [
        string(bind, portal, Portal),
        string(bind, statement, Statement),
        formats(ParameterFormats),
        count(Parameters),
        [length_prefixed(Parameter) || Parameter <- Parameters],
        formats(ResultFormats)
    ]);
encode({describe, Target, Name}) ->
    typed($D, [target(Target), string(describe, name, Name)]);
encode({execute, Portal, MaxRows}) ->
    typed($E, [string(execute, portal, Portal), <<MaxRows:32>>]);
encode(sync) ->
    <<$S, 4:32>>;
encode(flush) ->
    <<$H, 4:32>>;
encode({close, Target, Name}) ->
    typed($C, [target(Target), string(close, name, Name)]);
encode(terminate) ->
    <<$X, 4:32>>.

-spec typed(byte(), iodata()) -> iodata().
typed(Type, Payload) ->
    [<<Type, (message_length(Type, Payload)):32>>, Payload].

-spec untyped(iodata()) -> iodata().
untyped(Payload) ->
    [<<(message_length(startup, Payload)):32>>, Payload].

-spec message_length(byte() | startup, iodata()) -> pos_integer().
message_length(Type, Payload) ->
    case iolist_size(Payload) + 4 of
        Length when Length =< ?LONGEST_MESSAGE -> Length;
        Length -> minato_protocol:bad(frontend, message_too_long, {Type, Length, ?LONGEST_MESSAGE})
    end.

-spec startup_parameters(#{binary() => binary()}) -> iodata().
startup_parameters(Parameters) ->
    [[parameter_name(Name), 0, parameter_value(Name, Value), 0] || Name := Value <- Parameters].

-spec parameter_name(binary()) -> binary().
parameter_name(~"") ->
    minato_protocol:bad(startup, empty_parameter_name, ~"");
parameter_name(Name) ->
    parameter_value(Name, Name).

-spec parameter_value(binary(), binary()) -> binary().
parameter_value(Name, Value) ->
    case binary:match(Value, <<0>>) of
        nomatch -> Value;
        _Found -> minato_protocol:bad(startup, null_byte_in_parameter, Name)
    end.

%% A string with its terminator, once it is known to hold no other. The reason
%% names which string of which message and not what was in it.
-spec string(atom(), atom(), iodata()) -> iodata().
string(Message, Field, Text) ->
    case holds_null(Text) of
        false -> [Text, 0];
        true -> minato_protocol:bad(Message, null_byte, Field)
    end.

-spec holds_null(iodata() | byte()) -> boolean().
holds_null(Text) when is_binary(Text) -> binary:match(Text, <<0>>) =/= nomatch;
holds_null([Head | Tail]) -> holds_null(Head) orelse holds_null(Tail);
holds_null([]) -> false;
holds_null(Byte) -> Byte =:= 0.

-spec count([term()]) -> binary().
count(Values) ->
    case length(Values) of
        Count when Count =< ?MOST_VALUES -> <<Count:16>>;
        Count -> minato_protocol:bad(frontend, too_many_values, {Count, ?MOST_VALUES})
    end.

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
