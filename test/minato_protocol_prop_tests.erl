-module(minato_protocol_prop_tests).
-moduledoc """
Round-trip properties for the protocol layer.

Frontend messages are encoded by minato and read back by
`m:minato_frontend_reader`, which is a separate reading of the documented
formats, so a length field or a terminator that only one of the two believes in
fails the property.

Backend messages go the other way: `m:minato_backend_writer` builds the bytes a
server would send and the framer has to give the messages back, whole and in
order, whatever sizes the buffers arrive in.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% eqWAlizer: the PropEr macros expand to term(), so the functions that use them
%% cannot be given a useful type.
-eqwalizer({nowarn_function, prop_password_roundtrip/0}).
-eqwalizer({nowarn_function, prop_frame_roundtrip/0}).
-eqwalizer({nowarn_function, prop_every_split_frames_the_same/0}).
-eqwalizer({nowarn_function, prop_arbitrary_bytes_are_total/0}).
-eqwalizer({nowarn_function, prop_every_prefix_is_incomplete/0}).
-eqwalizer({nowarn_function, gen_stream/0}).
-eqwalizer({nowarn_function, gen_corrupted_stream/0}).
-eqwalizer({nowarn_function, prop_data_row_roundtrip/0}).
-eqwalizer({nowarn_function, prop_data_row_map_roundtrip/0}).
-eqwalizer({nowarn_function, gen_error_fields/0}).
-eqwalizer({nowarn_function, gen_parameters/0}).
-eqwalizer({nowarn_function, gen_bytes/1}).
-eqwalizer({nowarn_function, gen_cstring/0}).
-eqwalizer({nowarn_function, gen_binary/0}).

-define(NUMTESTS, 300).

frontend_property_test_() ->
    {timeout, 300, [
        {"a frontend message reads back as itself", fun() -> check(prop_frontend_roundtrip()) end},
        {"a password message reads back as itself", fun() -> check(prop_password_roundtrip()) end},
        {"a frontend message declares its own length", fun() ->
            check(prop_frontend_declares_its_length())
        end}
    ]}.

framing_property_test_() ->
    {timeout, 600, [
        {"a stream frames back to the messages it was built from", fun() ->
            check(prop_frame_roundtrip())
        end},
        {"a stream frames the same wherever it is split", fun() ->
            check(prop_every_split_frames_the_same())
        end},
        {"every prefix of a message is incomplete", fun() ->
            check(prop_every_prefix_is_incomplete())
        end},
        {"arbitrary bytes frame or raise, and do neither else", fun() ->
            check(prop_arbitrary_bytes_are_total())
        end}
    ]}.

row_property_test_() ->
    {timeout, 300, [
        {"a data row decodes to the values it was built from", fun() ->
            check(prop_data_row_roundtrip())
        end},
        {"a data row decodes to a map keyed by column name", fun() ->
            check(prop_data_row_map_roundtrip())
        end}
    ]}.

check(Prop) ->
    ?assert(proper:quickcheck(Prop, [?NUMTESTS, {to_file, user}])).

%%----------------------------------------------------------------------
%% Properties
%%----------------------------------------------------------------------

prop_frontend_roundtrip() ->
    ?FORALL(
        Message,
        gen_frontend(),
        Message =:= minato_frontend_reader:read(encode(Message))
    ).

prop_password_roundtrip() ->
    ?FORALL(
        Message,
        gen_password(),
        begin
            {password_message, Payload} = minato_frontend_reader:read(encode(Message)),
            Message =:= minato_frontend_reader:password(element(1, Message), Payload)
        end
    ).

prop_frontend_declares_its_length() ->
    ?FORALL(
        Message,
        oneof([gen_frontend(), gen_password()]),
        begin
            Bytes = encode(Message),
            Offset = type_byte_size(Message),
            <<_:Offset/binary, Length:32, _/binary>> = Bytes,
            Length =:= byte_size(Bytes) - Offset
        end
    ).

prop_frame_roundtrip() ->
    ?FORALL(
        {Messages, Sizes},
        {list(gen_backend()), list(integer(1, 32))},
        begin
            Bytes = minato_backend_writer:write_all(Messages),
            {Decoded, Rest} = feed(chunks(Bytes, Sizes)),
            Decoded =:= [decoded(Message) || Message <- Messages] andalso Rest =:= ~""
        end
    ).

prop_every_split_frames_the_same() ->
    ?FORALL(
        Messages,
        gen_stream(),
        begin
            Bytes = minato_backend_writer:write_all(Messages),
            Expected = {[decoded(Message) || Message <- Messages], ~""},
            lists:all(
                fun(At) -> feed_two(Bytes, At) =:= Expected end,
                lists:seq(0, byte_size(Bytes))
            )
        end
    ).

prop_arbitrary_bytes_are_total() ->
    ?FORALL(
        Bytes,
        oneof([gen_binary(), gen_corrupted_stream()]),
        try minato_protocol:frame(Bytes) of
            {Messages, Rest} -> is_list(Messages) andalso is_binary(Rest)
        catch
            error:{minato_protocol, #{message := _, reason := _, data := _}} -> true;
            _Class:_Reason -> false
        end
    ).

prop_every_prefix_is_incomplete() ->
    ?FORALL(
        Message,
        gen_backend(),
        begin
            Bytes = minato_backend_writer:write(Message),
            lists:all(
                fun(Size) ->
                    minato_protocol:decode(binary:part(Bytes, 0, Size)) =:= incomplete
                end,
                lists:seq(0, byte_size(Bytes) - 1)
            )
        end
    ).

prop_data_row_roundtrip() ->
    ?FORALL(
        Values,
        list(oneof([null, integer(-2147483648, 2147483647)])),
        begin
            {Fields, Columns} = int4_row(Values),
            Bytes = minato_backend_writer:write({data_row, Columns}),
            {[{data_row, Raw}], ~""} = minato_protocol:frame(Bytes),
            Decoder = minato_protocol:decoder(Fields, #{}),
            list_to_tuple(Values) =:= minato_protocol:decode_row(Decoder, Raw)
        end
    ).

prop_data_row_map_roundtrip() ->
    ?FORALL(
        Values,
        list(oneof([null, integer(-2147483648, 2147483647)])),
        begin
            {Fields, Columns} = int4_row(Values),
            Expected = maps:from_list(lists:zip(column_names(length(Values)), Values)),
            Expected =:= minato_protocol:row(Fields, Columns, #{return_rows_as_maps => true})
        end
    ).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

encode(Message) ->
    iolist_to_binary(minato_protocol:encode(Message)).

type_byte_size({startup, _}) -> 0;
type_byte_size(ssl_request) -> 0;
type_byte_size({cancel_request, _, _}) -> 0;
type_byte_size(_Message) -> 1.

int4_row(Values) ->
    Names = column_names(length(Values)),
    Fields = [
        #{
            name => Name,
            table_oid => 0,
            column => 0,
            type_oid => 23,
            type_size => 4,
            type_modifier => -1,
            format => binary
        }
     || Name <- Names
    ],
    {Fields, [int4(Value) || Value <- Values]}.

column_names(Count) ->
    [integer_to_binary(Index) || Index <- lists:seq(1, Count)].

int4(null) ->
    null;
int4(Value) ->
    case minato_codec:encode(23, Value, binary) of
        null -> null;
        Encoded -> iolist_to_binary(Encoded)
    end.

feed_two(Bytes, At) ->
    <<Head:At/binary, Tail/binary>> = Bytes,
    {First, Carried} = minato_protocol:frame(Head),
    {Second, Rest} = minato_protocol:frame(<<Carried/binary, Tail/binary>>),
    {First ++ Second, Rest}.

feed(Chunks) ->
    feed(Chunks, ~"", []).

feed([], Buffer, Acc) ->
    {lists:reverse(Acc), Buffer};
feed([Chunk | Rest], Buffer, Acc) ->
    {Messages, Carried} = minato_protocol:frame(<<Buffer/binary, Chunk/binary>>),
    feed(Rest, Carried, lists:reverse(Messages, Acc)).

chunks(~"", _Sizes) ->
    [];
chunks(Bytes, []) ->
    [Bytes];
chunks(Bytes, [Size | Rest]) ->
    case Bytes of
        <<Head:Size/binary, Tail/binary>> -> [Head | chunks(Tail, Rest)];
        _ -> [Bytes]
    end.

decoded({command_complete, Tag}) ->
    {command_complete, parsed_tag(Tag)};
decoded({data_row, Columns}) when is_list(Columns) ->
    %% A DataRow is generated as its columns and decodes to the payload that
    %% carries them, because splitting is the reader's job now.
    {data_row, payload_of(Columns)};
decoded(Message) ->
    Message.

payload_of(Columns) ->
    iolist_to_binary([
        <<(length(Columns)):16>>,
        [
            case Column of
                null -> <<-1:32/signed>>;
                Value -> <<(byte_size(Value)):32, Value/binary>>
            end
         || Column <- Columns
        ]
    ]).

command_tags() ->
    [
        {~"SELECT 5", {select, 5}},
        {~"INSERT 0 1", {insert, 1}},
        {~"UPDATE 0", {update, 0}},
        {~"BEGIN", {'begin', undefined}},
        {~"CREATE TABLE", {create, table}}
    ].

parsed_tag(Tag) ->
    {Tag, Parsed} = lists:keyfind(Tag, 1, command_tags()),
    Parsed.

%%----------------------------------------------------------------------
%% Generators
%%----------------------------------------------------------------------

gen_frontend() ->
    oneof([
        ?LET(Parameters, gen_parameters(), {startup, Parameters}),
        ssl_request,
        ?LET({Pid, Secret}, {gen_int32(), gen_int32()}, {cancel_request, Pid, Secret}),
        ?LET(Query, gen_cstring(), {query, Query}),
        ?LET(
            {Name, Query, Oids},
            {gen_cstring(), gen_cstring(), list(gen_oid())},
            {parse, Name, Query, Oids}
        ),
        gen_bind(),
        ?LET({Target, Name}, {gen_target(), gen_cstring()}, {describe, Target, Name}),
        ?LET(
            {Portal, MaxRows},
            {gen_cstring(), integer(0, 2147483647)},
            {execute, Portal, MaxRows}
        ),
        sync,
        flush,
        ?LET({Target, Name}, {gen_target(), gen_cstring()}, {close, Target, Name}),
        terminate
    ]).

gen_password() ->
    oneof([
        ?LET(Password, gen_cstring(), {password, Password}),
        ?LET(
            {Mechanism, Data},
            {gen_cstring(), oneof([null, gen_binary()])},
            {sasl_initial_response, Mechanism, Data}
        ),
        ?LET(Data, gen_binary(), {sasl_response, Data})
    ]).

gen_bind() ->
    ?LET(
        {Portal, Statement, ParameterFormats, Parameters, ResultFormats},
        {
            gen_cstring(),
            gen_cstring(),
            list(gen_format()),
            list(oneof([null, gen_binary()])),
            list(gen_format())
        },
        {bind, Portal, Statement, ParameterFormats, Parameters, ResultFormats}
    ).

gen_backend() ->
    oneof([
        authentication_ok,
        authentication_cleartext_password,
        ?LET(Salt, gen_bytes(4), {authentication_md5_password, Salt}),
        ?LET(Mechanisms, list(gen_cstring()), {authentication_sasl, Mechanisms}),
        ?LET(Data, gen_binary(), {authentication_sasl_continue, Data}),
        ?LET(Data, gen_binary(), {authentication_sasl_final, Data}),
        ?LET({Pid, Secret}, {gen_int32(), gen_int32()}, {backend_key_data, Pid, Secret}),
        ?LET({Name, Value}, {gen_cstring(), gen_cstring()}, {parameter_status, Name, Value}),
        ?LET(Status, oneof([idle, transaction, failed]), {ready_for_query, Status}),
        ?LET(Fields, list(gen_described_field()), {row_description, Fields}),
        ?LET(Columns, list(oneof([null, gen_binary()])), {data_row, Columns}),
        ?LET(Tag, oneof([Tag || {Tag, _} <- command_tags()]), {command_complete, Tag}),
        empty_query_response,
        ?LET(Fields, gen_error_fields(), {error_response, Fields}),
        ?LET(Fields, gen_error_fields(), {notice_response, Fields}),
        parse_complete,
        bind_complete,
        close_complete,
        no_data,
        ?LET(Oids, list(gen_oid()), {parameter_description, Oids}),
        portal_suspended,
        ?LET(
            {Pid, Channel, Payload},
            {gen_int32(), gen_cstring(), gen_cstring()},
            {notification_response, Pid, Channel, Payload}
        )
    ]).

-doc """
A short stream of small messages.

`prop_every_split_frames_the_same/0` frames the whole stream once per byte of
it, so the work it does is quadratic in the bytes generated and a stream of a
few kilobytes takes minutes. The size is bounded here rather than the number of
split points, because the split points are the property: skipping some of them
would leave exactly the boundary that fails untested, while a shorter message
tests the same boundaries. Long payloads are covered by
`prop_frame_roundtrip/0`, which frames each stream once at random chunk sizes.
""".
gen_stream() ->
    ?LET(Messages, resize(6, list(resize(6, gen_backend()))), lists:sublist(Messages, 6)).

gen_corrupted_stream() ->
    ?LET(
        {Messages, Byte},
        {gen_stream(), integer(0, 255)},
        begin
            Bytes = minato_backend_writer:write_all(Messages),
            ?LET(
                At,
                integer(0, max(0, byte_size(Bytes) - 1)),
                case Bytes of
                    ~"" ->
                        ~"";
                    _ ->
                        <<Head:At/binary, _, Tail/binary>> = Bytes,
                        <<Head/binary, Byte, Tail/binary>>
                end
            )
        end
    ).

gen_described_field() ->
    ?LET(
        {Name, TableOid, Column, TypeOid, TypeSize, TypeModifier, Format},
        {
            gen_cstring(),
            gen_oid(),
            integer(-32768, 32767),
            gen_oid(),
            integer(-32768, 32767),
            integer(-2147483648, 2147483647),
            gen_format()
        },
        #{
            name => Name,
            table_oid => TableOid,
            column => Column,
            type_oid => TypeOid,
            type_size => TypeSize,
            type_modifier => TypeModifier,
            format => Format
        }
    ).

gen_error_fields() ->
    ?LET(
        {Code, Message, Extra},
        {gen_cstring(), gen_cstring(), list({gen_field_name(), gen_cstring()})},
        maps:from_list(Extra ++ [{code, Code}, {message, Message}])
    ).

gen_field_name() ->
    oneof([
        severity,
        severity_non_localised,
        detail,
        hint,
        position,
        internal_position,
        internal_query,
        where,
        schema,
        table,
        column,
        data_type,
        constraint,
        file,
        line,
        routine
    ]).

gen_parameters() ->
    ?LET(Pairs, list({gen_cstring(), gen_cstring()}), maps:from_list(Pairs)).

gen_target() ->
    oneof([statement, portal]).

gen_format() ->
    oneof([text, binary]).

gen_oid() ->
    integer(0, 4294967295).

gen_int32() ->
    integer(0, 4294967295).

gen_cstring() ->
    ?LET(Bytes, list(integer(1, 255)), list_to_binary(Bytes)).

gen_binary() ->
    ?LET(Bytes, list(integer(0, 255)), list_to_binary(Bytes)).

gen_bytes(Count) ->
    ?LET(Bytes, vector(Count, integer(0, 255)), list_to_binary(Bytes)).
