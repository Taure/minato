-module(minato_protocol_backend).
-moduledoc """
Decoders for the messages a PostgreSQL server sends to a client.

Internal to minato. The supported surface is `m:minato_protocol`.

A payload reaches this module only once every byte of it has arrived, because
the framer in `m:minato_protocol` reads the length first and holds a short
message back. A payload that is complete and still does not fit its documented
format raises `error({minato_protocol, minato_protocol:report()})`.

## `BackendKeyData` is kept

The process ID and secret key a server sends at startup are the whole of what
`CancelRequest` needs. Discarding them costs nothing at the time and makes
query cancellation impossible for the life of the connection, so they are
decoded and handed on.

## Command tags become atoms

`CommandComplete` carries a tag such as `SELECT 5` or `CREATE TABLE`, and it is
turned into `{select, 5}` and `{create, table}`. The atoms are safe to create
from server bytes because the tag vocabulary is compiled into the server: a
tag is chosen from a fixed list by the command that ran, and no query can put a
new word in it.

That argument covers a server behaving as documented and nothing else, so it
does not decide what happens to bytes that are not a tag. A word of more than
255 bytes, or one that is not valid UTF-8, is refused as a malformed message.
Left to `binary_to_atom/2` the first would raise `system_limit` and the second
`badarg`, which would let whatever is on the far end of the socket choose an
exception outside minato's own shape.

## Unrecognised messages

A type byte minato does not model decodes to `{unsupported, Type, Payload}`.
Every backend message is length prefixed, so an unmodelled one can be stepped
over without the stream losing its place, and a caller that cares can look at
it. An unrecognised `ErrorResponse` field type is discarded instead, which is
what the protocol documentation asks of a client.
""".

-export([decode/2]).

-define(LONGEST_TAG_WORD, 255).

-doc "Decode one backend message from its type byte and its complete payload.".
-spec decode(byte(), binary()) -> minato_protocol:backend().
decode($R, Payload) -> authentication(Payload);
decode($K, Payload) -> backend_key_data(Payload);
decode($S, Payload) -> parameter_status(Payload);
decode($Z, Payload) -> ready_for_query(Payload);
decode($T, Payload) -> {row_description, row_description(Payload)};
decode($D, Payload) -> {data_row, data_row(Payload)};
decode($C, Payload) -> {command_complete, command_complete(Payload)};
decode($I, Payload) -> empty(empty_query_response, Payload);
decode($E, Payload) -> {error_response, error_fields(Payload)};
decode($N, Payload) -> {notice_response, error_fields(Payload)};
decode($1, Payload) -> empty(parse_complete, Payload);
decode($2, Payload) -> empty(bind_complete, Payload);
decode($3, Payload) -> empty(close_complete, Payload);
decode($n, Payload) -> empty(no_data, Payload);
decode($t, Payload) -> {parameter_description, parameter_description(Payload)};
decode($s, Payload) -> empty(portal_suspended, Payload);
decode($A, Payload) -> notification_response(Payload);
decode(Type, Payload) -> {unsupported, Type, Payload}.

%%----------------------------------------------------------------------
%% Authentication
%%----------------------------------------------------------------------

-spec authentication(binary()) -> minato_protocol:backend().
authentication(<<Method:32, Rest/binary>>) ->
    authentication(Method, Rest);
authentication(Payload) ->
    minato_protocol:bad(authentication, malformed, Payload).

-spec authentication(non_neg_integer(), binary()) -> minato_protocol:backend().
authentication(0, ~"") ->
    authentication_ok;
authentication(3, ~"") ->
    authentication_cleartext_password;
authentication(5, <<Salt:4/binary>>) ->
    {authentication_md5_password, Salt};
authentication(10, Rest) ->
    {authentication_sasl, mechanisms(Rest)};
authentication(11, Data) ->
    {authentication_sasl_continue, Data};
authentication(12, Data) ->
    {authentication_sasl_final, Data};
authentication(Method, Payload) ->
    case lists:member(Method, [0, 3, 5]) of
        true -> minato_protocol:bad(authentication, malformed, Payload);
        false -> minato_protocol:bad(authentication, {unsupported_method, Method}, Payload)
    end.

-spec mechanisms(binary()) -> [binary()].
mechanisms(<<0>>) ->
    [];
mechanisms(Payload) ->
    {Mechanism, Rest} = cstring(authentication_sasl, Payload),
    [Mechanism | mechanisms(Rest)].

%%----------------------------------------------------------------------
%% Session
%%----------------------------------------------------------------------

-spec backend_key_data(binary()) -> minato_protocol:backend().
backend_key_data(<<Pid:32, Secret:32>>) ->
    {backend_key_data, Pid, Secret};
backend_key_data(Payload) ->
    minato_protocol:bad(backend_key_data, malformed, Payload).

-spec parameter_status(binary()) -> minato_protocol:backend().
parameter_status(Payload) ->
    {Name, Rest} = cstring(parameter_status, Payload),
    {Value, Tail} = cstring(parameter_status, Rest),
    exhausted(parameter_status, Tail),
    {parameter_status, Name, Value}.

-spec ready_for_query(binary()) -> minato_protocol:backend().
ready_for_query(<<$I>>) -> {ready_for_query, idle};
ready_for_query(<<$T>>) -> {ready_for_query, transaction};
ready_for_query(<<$E>>) -> {ready_for_query, failed};
ready_for_query(Payload) -> minato_protocol:bad(ready_for_query, malformed, Payload).

-spec notification_response(binary()) -> minato_protocol:backend().
notification_response(<<Pid:32, Rest/binary>>) ->
    {Channel, Tail} = cstring(notification_response, Rest),
    {Payload, End} = cstring(notification_response, Tail),
    exhausted(notification_response, End),
    {notification_response, Pid, Channel, Payload};
notification_response(Payload) ->
    minato_protocol:bad(notification_response, malformed, Payload).

-spec empty(minato_protocol:backend(), binary()) -> minato_protocol:backend().
empty(Message, ~"") -> Message;
empty(Message, Payload) -> minato_protocol:bad(Message, unexpected_payload, Payload).

%%----------------------------------------------------------------------
%% Result set
%%----------------------------------------------------------------------

-spec row_description(binary()) -> [minato_protocol:field()].
row_description(<<Count:16, Rest/binary>>) ->
    described_fields(Count, Rest);
row_description(Payload) ->
    minato_protocol:bad(row_description, malformed, Payload).

-spec described_fields(non_neg_integer(), binary()) -> [minato_protocol:field()].
described_fields(0, ~"") ->
    [];
described_fields(Remaining, Payload) when Remaining > 0 ->
    {Name, Rest} = cstring(row_description, Payload),
    case Rest of
        <<
            TableOid:32,
            Column:16/signed,
            TypeOid:32,
            TypeSize:16/signed,
            TypeModifier:32/signed,
            Format:16,
            Tail/binary
        >> ->
            Field = #{
                name => Name,
                table_oid => TableOid,
                column => Column,
                type_oid => TypeOid,
                type_size => TypeSize,
                type_modifier => TypeModifier,
                format => format(row_description, Format)
            },
            [Field | described_fields(Remaining - 1, Tail)];
        _ ->
            minato_protocol:bad(row_description, malformed, Rest)
    end;
described_fields(_Remaining, Payload) ->
    minato_protocol:bad(row_description, malformed, Payload).

-spec format(atom(), non_neg_integer()) -> minato_codec:format().
format(_Message, 0) -> text;
format(_Message, 1) -> binary;
format(Message, Code) -> minato_protocol:bad(Message, {unknown_format_code, Code}, Code).

-spec data_row(binary()) -> [binary() | null].
data_row(<<Count:16, Rest/binary>>) ->
    columns(Count, Rest);
data_row(Payload) ->
    minato_protocol:bad(data_row, malformed, Payload).

-spec columns(non_neg_integer(), binary()) -> [binary() | null].
columns(0, ~"") ->
    [];
columns(Remaining, <<Length:32/signed, Rest/binary>>) when Remaining > 0 ->
    column(Remaining, Length, Rest);
columns(_Remaining, Payload) ->
    minato_protocol:bad(data_row, malformed, Payload).

-spec column(pos_integer(), integer(), binary()) -> [binary() | null].
column(Remaining, -1, Rest) ->
    [null | columns(Remaining - 1, Rest)];
column(Remaining, Length, Rest) when Length >= 0 ->
    case Rest of
        <<Value:Length/binary, Tail/binary>> -> [Value | columns(Remaining - 1, Tail)];
        _ -> minato_protocol:bad(data_row, malformed, Rest)
    end;
column(_Remaining, Length, _Rest) ->
    minato_protocol:bad(data_row, {negative_column_length, Length}, Length).

-spec parameter_description(binary()) -> [minato_oid:oid()].
parameter_description(<<Count:16, Rest/binary>>) ->
    parameter_oids(Count, Rest);
parameter_description(Payload) ->
    minato_protocol:bad(parameter_description, malformed, Payload).

-spec parameter_oids(non_neg_integer(), binary()) -> [minato_oid:oid()].
parameter_oids(0, ~"") ->
    [];
parameter_oids(Remaining, <<Oid:32, Rest/binary>>) when Remaining > 0 ->
    [Oid | parameter_oids(Remaining - 1, Rest)];
parameter_oids(_Remaining, Payload) ->
    minato_protocol:bad(parameter_description, malformed, Payload).

%%----------------------------------------------------------------------
%% Command tags
%%----------------------------------------------------------------------

-spec command_complete(binary()) -> minato_protocol:tag().
command_complete(Payload) ->
    {Tag, Rest} = cstring(command_complete, Payload),
    exhausted(command_complete, Rest),
    tag(Tag).

-spec tag(binary()) -> minato_protocol:tag().
tag(Tag) ->
    case binary:split(Tag, ~" ", [global]) of
        [Command] -> {word(Command), undefined};
        [~"INSERT", _Oid, Rows] -> {insert, count_or_word(Rows)};
        [Command, Second] -> {word(Command), count_or_word(Second)};
        [Command | Object] -> {word(Command), word(join(Object))}
    end.

-spec count_or_word(binary()) -> non_neg_integer() | atom().
count_or_word(Bin) ->
    case count(Bin) of
        {ok, Count} -> Count;
        error -> word(Bin)
    end.

-spec count(binary()) -> {ok, non_neg_integer()} | error.
count(Bin) ->
    try binary_to_integer(Bin) of
        Count when Count >= 0 -> {ok, Count};
        _Negative -> error
    catch
        error:badarg -> error
    end.

-spec word(binary()) -> atom().
word(Bin) when byte_size(Bin) =< ?LONGEST_TAG_WORD ->
    try
        % elp:ignore W0023 - the tag vocabulary is compiled into the server
        binary_to_atom(lowercase(Bin), utf8)
    catch
        error:badarg -> minato_protocol:bad(command_complete, tag_word_not_utf8, Bin)
    end;
word(Bin) ->
    minato_protocol:bad(command_complete, tag_word_too_long, byte_size(Bin)).

-spec join([binary()]) -> binary().
join([Word]) ->
    Word;
join([Word | Rest]) ->
    <<Word/binary, $_, (join(Rest))/binary>>.

-spec lowercase(binary()) -> binary().
lowercase(Bin) ->
    <<<<(lowercase_byte(Byte))>> || <<Byte>> <= Bin>>.

-spec lowercase_byte(byte()) -> byte().
lowercase_byte(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
lowercase_byte(Byte) -> Byte.

%%----------------------------------------------------------------------
%% Error and notice fields
%%----------------------------------------------------------------------

-spec error_fields(binary()) -> minato_protocol:fields().
error_fields(Payload) ->
    collect(Payload, #{code => ~"", message => ~""}).

-spec collect(binary(), minato_protocol:fields()) -> minato_protocol:fields().
collect(<<0>>, Acc) ->
    Acc;
collect(<<0, Rest/binary>>, _Acc) ->
    minato_protocol:bad(error_response, trailing_bytes, Rest);
collect(<<Type, Rest/binary>>, Acc) ->
    {Value, Tail} = cstring(error_response, Rest),
    collect(Tail, put_field(Type, Value, Acc));
collect(~"", _Acc) ->
    minato_protocol:bad(error_response, missing_terminator, ~"").

-spec put_field(byte(), binary(), minato_protocol:fields()) -> minato_protocol:fields().
put_field($S, Value, Fields) -> Fields#{severity => Value};
put_field($V, Value, Fields) -> Fields#{severity_non_localised => Value};
put_field($C, Value, Fields) -> Fields#{code => Value};
put_field($M, Value, Fields) -> Fields#{message => Value};
put_field($D, Value, Fields) -> Fields#{detail => Value};
put_field($H, Value, Fields) -> Fields#{hint => Value};
put_field($P, Value, Fields) -> Fields#{position => Value};
put_field($p, Value, Fields) -> Fields#{internal_position => Value};
put_field($q, Value, Fields) -> Fields#{internal_query => Value};
put_field($W, Value, Fields) -> Fields#{where => Value};
put_field($s, Value, Fields) -> Fields#{schema => Value};
put_field($t, Value, Fields) -> Fields#{table => Value};
put_field($c, Value, Fields) -> Fields#{column => Value};
put_field($d, Value, Fields) -> Fields#{data_type => Value};
put_field($n, Value, Fields) -> Fields#{constraint => Value};
put_field($F, Value, Fields) -> Fields#{file => Value};
put_field($L, Value, Fields) -> Fields#{line => Value};
put_field($R, Value, Fields) -> Fields#{routine => Value};
put_field(_Type, _Value, Fields) -> Fields.

%%----------------------------------------------------------------------
%% Primitives
%%----------------------------------------------------------------------

-spec cstring(atom(), binary()) -> {binary(), binary()}.
cstring(Message, Payload) ->
    case binary:split(Payload, <<0>>) of
        [Value, Rest] -> {Value, Rest};
        _ -> minato_protocol:bad(Message, missing_null_terminator, Payload)
    end.

-spec exhausted(atom(), binary()) -> ok.
exhausted(_Message, ~"") -> ok;
exhausted(Message, Rest) -> minato_protocol:bad(Message, trailing_bytes, Rest).
