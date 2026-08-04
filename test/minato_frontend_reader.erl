-module(minato_frontend_reader).
-moduledoc """
Reads the bytes `minato_protocol_frontend` writes back into the term they came
from, so that the round-trip properties compare terms rather than compare an
encoder against itself.

Written separately from the encoder and from the documented message formats. A
property that encodes with one implementation and decodes with the other only
passes if both agree with the format, and a length field or a null terminator
that the encoder gets wrong shows up here as a badmatch.

## Telling the untyped messages apart

`StartupMessage`, `SSLRequest` and `CancelRequest` have no type byte. Their
first byte is the top byte of a 32 bit length, which is zero for any message
short enough to send, while every typed message starts with a printable ASCII
type byte. The 32 bit code after the length then says which of the three it is.

## Telling the password messages apart

`PasswordMessage`, `SASLInitialResponse` and `SASLResponse` all use the type
byte `p` and are told apart by which authentication request the server sent
last, which is state this module does not have. `read/1` therefore stops at
`{password_message, Payload}` and `password/2` finishes the job once the caller
says which of the three was expected, exactly as a server resolves it.
""".

-export([read/1, password/2]).

-doc "Read one frontend message from the whole of a binary.".
-spec read(binary()) -> minato_protocol:frontend() | {password_message, binary()}.
read(<<0, _/binary>> = Message) ->
    <<Length:32, Body/binary>> = Message,
    untyped(payload(Length, Body));
read(<<Type, Length:32, Body/binary>>) ->
    typed(Type, payload(Length, Body)).

-doc "Finish reading a `p` message once the caller says which of the three it is.".
-spec password(password | sasl_initial_response | sasl_response, binary()) ->
    minato_protocol:frontend().
password(password, Payload) ->
    {Value, Rest} = cstring(Payload),
    <<>> = Rest,
    {password, Value};
password(sasl_initial_response, Payload) ->
    {Mechanism, Rest} = cstring(Payload),
    case Rest of
        <<16#FFFFFFFF:32>> -> {sasl_initial_response, Mechanism, null};
        <<Size:32, Data:Size/binary>> -> {sasl_initial_response, Mechanism, Data}
    end;
password(sasl_response, Payload) ->
    {sasl_response, Payload}.

-spec payload(non_neg_integer(), binary()) -> binary().
payload(Length, Body) ->
    Size = Length - 4,
    <<Payload:Size/binary>> = Body,
    Payload.

-spec untyped(binary()) -> minato_protocol:frontend().
untyped(<<80877103:32>>) ->
    ssl_request;
untyped(<<80877102:32, Pid:32, Secret:32>>) ->
    {cancel_request, Pid, Secret};
untyped(<<196608:32, Rest/binary>>) ->
    {startup, startup_parameters(Rest, #{})}.

-spec typed(byte(), binary()) -> minato_protocol:frontend() | {password_message, binary()}.
typed($p, Payload) ->
    {password_message, Payload};
typed($Q, Payload) ->
    {query, only_cstring(Payload)};
typed($P, Payload) ->
    {Name, Rest} = cstring(Payload),
    {Query, Tail} = cstring(Rest),
    <<Count:16, Oids/binary>> = Tail,
    {parse, Name, Query, oids(Count, Oids)};
typed($B, Payload) ->
    {Portal, Rest} = cstring(Payload),
    {Statement, Tail} = cstring(Rest),
    {ParameterFormats, AfterFormats} = formats(Tail),
    <<Count:16, Values/binary>> = AfterFormats,
    {Parameters, AfterValues} = parameters(Count, Values),
    {ResultFormats, End} = formats(AfterValues),
    <<>> = End,
    {bind, Portal, Statement, ParameterFormats, Parameters, ResultFormats};
typed($D, <<Target, Rest/binary>>) ->
    {describe, target(Target), only_cstring(Rest)};
typed($E, Payload) ->
    {Portal, Rest} = cstring(Payload),
    <<MaxRows:32>> = Rest,
    {execute, Portal, MaxRows};
typed($S, <<>>) ->
    sync;
typed($H, <<>>) ->
    flush;
typed($C, <<Target, Rest/binary>>) ->
    {close, target(Target), only_cstring(Rest)};
typed($X, <<>>) ->
    terminate.

-spec target(byte()) -> minato_protocol:target().
target($S) -> statement;
target($P) -> portal.

-spec startup_parameters(binary(), #{binary() => binary()}) -> #{binary() => binary()}.
startup_parameters(<<0>>, Acc) ->
    Acc;
startup_parameters(Bin, Acc) ->
    {Name, Rest} = cstring(Bin),
    {Value, Tail} = cstring(Rest),
    startup_parameters(Tail, Acc#{Name => Value}).

-spec oids(non_neg_integer(), binary()) -> [minato_oid:oid()].
oids(0, <<>>) ->
    [];
oids(Remaining, <<Oid:32, Rest/binary>>) ->
    [Oid | oids(Remaining - 1, Rest)].

-spec formats(binary()) -> {[minato_codec:format()], binary()}.
formats(<<Count:16, Rest/binary>>) ->
    formats(Count, Rest).

-spec formats(non_neg_integer(), binary()) -> {[minato_codec:format()], binary()}.
formats(0, Rest) ->
    {[], Rest};
formats(Remaining, <<Code:16, Rest/binary>>) ->
    {Formats, Tail} = formats(Remaining - 1, Rest),
    {[format(Code) | Formats], Tail}.

-spec format(non_neg_integer()) -> minato_codec:format().
format(0) -> text;
format(1) -> binary.

-spec parameters(non_neg_integer(), binary()) -> {[binary() | null], binary()}.
parameters(0, Rest) ->
    {[], Rest};
parameters(Remaining, <<16#FFFFFFFF:32, Rest/binary>>) ->
    {Parameters, Tail} = parameters(Remaining - 1, Rest),
    {[null | Parameters], Tail};
parameters(Remaining, <<Size:32, Value:Size/binary, Rest/binary>>) ->
    {Parameters, Tail} = parameters(Remaining - 1, Rest),
    {[Value | Parameters], Tail}.

-spec only_cstring(binary()) -> binary().
only_cstring(Bin) ->
    {Value, Rest} = cstring(Bin),
    <<>> = Rest,
    Value.

-spec cstring(binary()) -> {binary(), binary()}.
cstring(Bin) ->
    [Value, Rest] = binary:split(Bin, <<0>>),
    {Value, Rest}.
