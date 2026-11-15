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
    forall(gen_frontend(), fun(Message) ->
        Message =:= minato_frontend_reader:read(encode(Message))
    end).

prop_password_roundtrip() ->
    forall(gen_password(), fun(Message) ->
        {password_message, Payload} = minato_frontend_reader:read(encode(Message)),
        Message =:= minato_frontend_reader:password(element(1, Message), Payload)
    end).

prop_frontend_declares_its_length() ->
    forall(oneof([gen_frontend(), gen_password()]), fun(Message) ->
        Bytes = encode(Message),
        Offset = type_byte_size(Message),
        <<_:Offset/binary, Length:32, _/binary>> = Bytes,
        Length =:= byte_size(Bytes) - Offset
    end).

prop_frame_roundtrip() ->
    forall({list(gen_backend()), list(integer(1, 32))}, fun({Messages, Sizes}) ->
        Bytes = minato_backend_writer:write_all(Messages),
        {Decoded, Rest} = feed(chunks(Bytes, Sizes)),
        Decoded =:= [decoded(Message) || Message <- Messages] andalso Rest =:= ~""
    end).

prop_every_split_frames_the_same() ->
    forall(gen_stream(), fun(Messages) ->
        Bytes = minato_backend_writer:write_all(Messages),
        Expected = {[decoded(Message) || Message <- Messages], ~""},
        lists:all(
            fun(At) -> feed_two(Bytes, At) =:= Expected end,
            lists:seq(0, byte_size(Bytes))
        )
    end).

prop_arbitrary_bytes_are_total() ->
    forall(oneof([gen_binary(), gen_corrupted_stream()]), fun(Bytes) ->
        try minato_protocol:frame(Bytes) of
            {Messages, Rest} -> is_list(Messages) andalso is_binary(Rest)
        catch
            error:{minato_protocol, #{message := _, reason := _, data := _}} -> true;
            _Class:_Reason -> false
        end
    end).

prop_every_prefix_is_incomplete() ->
    forall(gen_backend(), fun(Message) ->
        Bytes = minato_backend_writer:write(Message),
        [] =:=
            [
                Size
             || Size <- lists:seq(0, byte_size(Bytes) - 1),
                minato_protocol:decode(binary:part(Bytes, 0, Size)) =/= incomplete
            ]
    end).

prop_data_row_roundtrip() ->
    forall(list(oneof([null, integer(-2147483648, 2147483647)])), fun(Values) ->
        {Fields, Columns} = int4_row(Values),
        Bytes = minato_backend_writer:write({data_row, Columns}),
        {[{data_row, Raw}], ~""} = minato_protocol:frame(Bytes),
        Decoder = minato_protocol:decoder(Fields, #{}),
        list_to_tuple(Values) =:= minato_protocol:decode_row(Decoder, Raw)
    end).

prop_data_row_map_roundtrip() ->
    forall(list(oneof([null, integer(-2147483648, 2147483647)])), fun(Values) ->
        {Fields, Columns} = int4_row(Values),
        Expected = maps:from_list(lists:zip(column_names(length(Values)), Values)),
        Expected =:= minato_protocol:row(Fields, Columns, #{return_rows_as_maps => true})
    end).

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
        from(gen_parameters(), fun(Parameters) -> {startup, Parameters} end),
        ssl_request,
        from({gen_int32(), gen_int32()}, fun({Pid, Secret}) -> {cancel_request, Pid, Secret} end),
        from(gen_cstring(), fun(Query) -> {query, Query} end),
        from({gen_cstring(), gen_cstring(), list(gen_oid())}, fun({Name, Query, Oids}) ->
            {parse, Name, Query, Oids}
        end),
        gen_bind(),
        from({gen_target(), gen_cstring()}, fun({Target, Name}) -> {describe, Target, Name} end),
        from({gen_cstring(), integer(0, 2147483647)}, fun({Portal, MaxRows}) ->
            {execute, Portal, MaxRows}
        end),
        sync,
        flush,
        from({gen_target(), gen_cstring()}, fun({Target, Name}) -> {close, Target, Name} end),
        terminate
    ]).

gen_password() ->
    oneof([
        from(gen_cstring(), fun(Password) -> {password, Password} end),
        from({gen_cstring(), oneof([null, gen_binary()])}, fun({Mechanism, Data}) ->
            {sasl_initial_response, Mechanism, Data}
        end),
        from(gen_binary(), fun(Data) -> {sasl_response, Data} end)
    ]).

gen_bind() ->
    from(
        {
            gen_cstring(),
            gen_cstring(),
            list(gen_format()),
            list(oneof([null, gen_binary()])),
            list(gen_format())
        },
        fun({Portal, Statement, ParameterFormats, Parameters, ResultFormats}) ->
            {bind, Portal, Statement, ParameterFormats, Parameters, ResultFormats}
        end
    ).

gen_backend() ->
    oneof([
        authentication_ok,
        authentication_cleartext_password,
        from(gen_bytes(4), fun(Salt) -> {authentication_md5_password, Salt} end),
        from(list(gen_cstring()), fun(Mechanisms) -> {authentication_sasl, Mechanisms} end),
        from(gen_binary(), fun(Data) -> {authentication_sasl_continue, Data} end),
        from(gen_binary(), fun(Data) -> {authentication_sasl_final, Data} end),
        from({gen_int32(), gen_int32()}, fun({Pid, Secret}) -> {backend_key_data, Pid, Secret} end),
        from({gen_cstring(), gen_cstring()}, fun({Name, Value}) ->
            {parameter_status, Name, Value}
        end),
        from(oneof([idle, transaction, failed]), fun(Status) -> {ready_for_query, Status} end),
        from(list(gen_described_field()), fun(Fields) -> {row_description, Fields} end),
        from(list(oneof([null, gen_binary()])), fun(Columns) -> {data_row, Columns} end),
        from(oneof([Tag || {Tag, _} <- command_tags()]), fun(Tag) -> {command_complete, Tag} end),
        empty_query_response,
        from(gen_error_fields(), fun(Fields) -> {error_response, Fields} end),
        from(gen_error_fields(), fun(Fields) -> {notice_response, Fields} end),
        parse_complete,
        bind_complete,
        close_complete,
        no_data,
        from(list(gen_oid()), fun(Oids) -> {parameter_description, Oids} end),
        portal_suspended,
        from({gen_int32(), gen_cstring(), gen_cstring()}, fun({Pid, Channel, Payload}) ->
            {notification_response, Pid, Channel, Payload}
        end)
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
    from(resize(6, list(resize(6, gen_backend()))), fun(Messages) -> lists:sublist(Messages, 6) end).

gen_corrupted_stream() ->
    from({gen_stream(), integer(0, 255)}, fun({Messages, Byte}) ->
        Bytes = minato_backend_writer:write_all(Messages),
        from(integer(0, last_offset(Bytes)), fun(At) ->
            case Bytes of
                ~"" ->
                    ~"";
                _ ->
                    <<Head:At/binary, _, Tail/binary>> = Bytes,
                    <<Head/binary, Byte, Tail/binary>>
            end
        end)
    end).

gen_described_field() ->
    from(
        {
            gen_cstring(),
            gen_oid(),
            integer(-32768, 32767),
            gen_oid(),
            integer(-32768, 32767),
            integer(-2147483648, 2147483647),
            gen_format()
        },
        fun({Name, TableOid, Column, TypeOid, TypeSize, TypeModifier, Format}) ->
            #{
                name => Name,
                table_oid => TableOid,
                column => Column,
                type_oid => TypeOid,
                type_size => TypeSize,
                type_modifier => TypeModifier,
                format => Format
            }
        end
    ).

gen_error_fields() ->
    from({gen_cstring(), gen_cstring(), list({gen_field_name(), gen_cstring()})}, fun(
        {Code, Message, Extra}
    ) ->
        maps:from_list(Extra ++ [{code, Code}, {message, Message}])
    end).

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

%% An empty name is how the packet ends its parameter list, so the encoder
%% refuses one and the generator leaves it out.
gen_parameters() ->
    from(list({non_empty(gen_cstring()), gen_cstring()}), fun maps:from_list/1).

gen_target() ->
    oneof([statement, portal]).

gen_format() ->
    oneof([text, binary]).

gen_oid() ->
    integer(0, 4294967295).

gen_int32() ->
    integer(0, 4294967295).

gen_cstring() ->
    from(list(integer(1, 255)), fun(Bytes) -> list_to_binary(Bytes) end).

gen_binary() ->
    from(list(integer(0, 255)), fun(Bytes) -> list_to_binary(Bytes) end).

gen_bytes(Count) ->
    from(vector(Count, integer(0, 255)), fun(Bytes) -> list_to_binary(Bytes) end).

-spec last_offset(binary()) -> non_neg_integer().
last_offset(~"") -> 0;
last_offset(Bytes) -> byte_size(Bytes) - 1.

%%----------------------------------------------------------------------
%% What PropEr generates
%%----------------------------------------------------------------------

%% A generated value has no type until the test runs, so it is `dynamic()`
%% here and nowhere else.
-spec forall(proper_types:raw_type(), fun((dynamic()) -> proper:test())) -> proper:test().
forall(Type, Property) ->
    ?FORALL(Generated, Type, Property(Generated)).

-spec from(proper_types:raw_type(), fun((dynamic()) -> term())) -> proper_types:type().
from(Type, Made) ->
    ?LET(Generated, Type, Made(Generated)).
