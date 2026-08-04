-module(minato_backend_writer).
-moduledoc """
Writes the bytes a PostgreSQL server would send for a decoded backend message.

The framer has to be tested against streams a real server could produce:
several messages in one buffer, one message split across two buffers, a message
split a byte at a time. Building those streams needs an encoder for backend
messages, which a client has no reason to ship, so it lives here.

Written from the documented message formats rather than from
`minato_protocol_backend`, so that a field written in the wrong order or a
count that disagrees with what follows it fails the round trip instead of
cancelling out.
""".

-export([write/1, write_all/1]).

-doc """
What `write/1` accepts.

A decoded backend message, except that `CommandComplete` carries its tag as the
text a server puts on the wire rather than the parsed form, because parsing it
is one of the things under test.
""".
-type message() :: minato_protocol:backend() | {command_complete, binary()}.

-export_type([message/0]).

-doc "The wire bytes of one backend message, type byte and length included.".
-spec write(message()) -> binary().
write(authentication_ok) ->
    typed($R, <<0:32>>);
write(authentication_cleartext_password) ->
    typed($R, <<3:32>>);
write({authentication_md5_password, Salt}) ->
    typed($R, <<5:32, Salt/binary>>);
write({authentication_sasl, Mechanisms}) ->
    typed($R, <<10:32, (cstrings(Mechanisms))/binary, 0>>);
write({authentication_sasl_continue, Data}) ->
    typed($R, <<11:32, Data/binary>>);
write({authentication_sasl_final, Data}) ->
    typed($R, <<12:32, Data/binary>>);
write({backend_key_data, Pid, Secret}) ->
    typed($K, <<Pid:32, Secret:32>>);
write({parameter_status, Name, Value}) ->
    typed($S, <<Name/binary, 0, Value/binary, 0>>);
write({ready_for_query, Status}) ->
    typed($Z, <<(status(Status))>>);
write({row_description, Fields}) ->
    typed($T, <<(length(Fields)):16, (fields(Fields))/binary>>);
write({data_row, Columns}) ->
    typed($D, <<(length(Columns)):16, (columns(Columns))/binary>>);
write({command_complete, Tag}) when is_binary(Tag) ->
    typed($C, <<Tag/binary, 0>>);
write(empty_query_response) ->
    typed($I, <<>>);
write({error_response, Fields}) ->
    typed($E, error_fields(Fields));
write({notice_response, Fields}) ->
    typed($N, error_fields(Fields));
write(parse_complete) ->
    typed($1, <<>>);
write(bind_complete) ->
    typed($2, <<>>);
write(close_complete) ->
    typed($3, <<>>);
write(no_data) ->
    typed($n, <<>>);
write({parameter_description, Oids}) ->
    typed($t, <<(length(Oids)):16, (oids(Oids))/binary>>);
write(portal_suspended) ->
    typed($s, <<>>);
write({notification_response, Pid, Channel, Payload}) ->
    typed($A, <<Pid:32, Channel/binary, 0, Payload/binary, 0>>);
write({unsupported, Type, Payload}) ->
    typed(Type, Payload).

-doc "The wire bytes of a whole stream of backend messages.".
-spec write_all([message()]) -> binary().
write_all(Messages) ->
    <<<<(write(Message))/binary>> || Message <- Messages>>.

-spec typed(byte(), binary()) -> binary().
typed(Type, Payload) ->
    <<Type, (byte_size(Payload) + 4):32, Payload/binary>>.

-spec cstrings([binary()]) -> binary().
cstrings(Values) ->
    <<<<Value/binary, 0>> || Value <- Values>>.

-spec status(minato_protocol:transaction_status()) -> byte().
status(idle) -> $I;
status(transaction) -> $T;
status(failed) -> $E.

-spec fields([minato_protocol:field()]) -> binary().
fields(Fields) ->
    <<<<(field(Field))/binary>> || Field <- Fields>>.

-spec field(minato_protocol:field()) -> binary().
field(Field) ->
    #{
        name := Name,
        table_oid := TableOid,
        column := Column,
        type_oid := TypeOid,
        type_size := TypeSize,
        type_modifier := TypeModifier,
        format := Format
    } = Field,
    <<
        Name/binary,
        0,
        TableOid:32,
        Column:16/signed,
        TypeOid:32,
        TypeSize:16/signed,
        TypeModifier:32/signed,
        (format(Format)):16
    >>.

-spec format(minato_codec:format()) -> 0..1.
format(text) -> 0;
format(binary) -> 1.

-spec columns([binary() | null]) -> binary().
columns(Columns) ->
    <<<<(column(Column))/binary>> || Column <- Columns>>.

-spec column(binary() | null) -> binary().
column(null) -> <<-1:32/signed>>;
column(Value) -> <<(byte_size(Value)):32, Value/binary>>.

-spec oids([minato_oid:oid()]) -> binary().
oids(Oids) ->
    <<<<Oid:32>> || Oid <- Oids>>.

-spec error_fields(minato_protocol:fields()) -> binary().
error_fields(Fields) ->
    Written = <<<<(field_type(Name)), Value/binary, 0>> || Name := Value <- Fields>>,
    <<Written/binary, 0>>.

-spec field_type(atom()) -> byte().
field_type(severity) -> $S;
field_type(severity_non_localised) -> $V;
field_type(code) -> $C;
field_type(message) -> $M;
field_type(detail) -> $D;
field_type(hint) -> $H;
field_type(position) -> $P;
field_type(internal_position) -> $p;
field_type(internal_query) -> $q;
field_type(where) -> $W;
field_type(schema) -> $s;
field_type(table) -> $t;
field_type(column) -> $c;
field_type(data_type) -> $d;
field_type(constraint) -> $n;
field_type(file) -> $F;
field_type(line) -> $L;
field_type(routine) -> $R.
