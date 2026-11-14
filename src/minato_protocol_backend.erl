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

## Command tags are read against a closed vocabulary

`CommandComplete` carries a tag such as `SELECT 5` or `CREATE TABLE`, and it is
turned into `{select, 5}` and `{create, table}`. The atoms come from a table
compiled into this module, holding the words PostgreSQL's own tag list is made
of. No atom is ever created from bytes that arrived on the socket, so nothing on
the far end of it can grow the atom table, whatever it claims to have run.

A word that is not in the table is kept as the binary it arrived as:
`FROBNICATE 3` from a server that is not quite PostgreSQL is
`{~"FROBNICATE", 3}`, with the count still a count. Such a word has to be valid
UTF-8 and no longer than 255 bytes, or the tag is refused as a malformed
message; PostgreSQL's own tags fit in 64.

The four tags every workload actually ends on are matched whole, ahead of the
table.

## Unrecognised messages

A type byte minato does not model decodes to `{unsupported, Type, Payload}`.
Every backend message is length prefixed, so an unmodelled one can be stepped
over without the stream losing its place, and a caller that cares can look at
it. An unrecognised `ErrorResponse` field type is discarded instead, which is
what the protocol documentation asks of a client.
""".

-export([decode/2]).

-define(LONGEST_TAG_WORD, 255).
-define(LONGEST_COUNT, 20).

-doc "Decode one backend message from its type byte and its complete payload.".
-spec decode(byte(), binary()) -> minato_protocol:backend().
decode($R, Payload) -> authentication(Payload);
decode($K, Payload) -> backend_key_data(Payload);
decode($S, Payload) -> parameter_status(Payload);
decode($Z, Payload) -> ready_for_query(Payload);
decode($T, Payload) -> {row_description, row_description(Payload)};
decode($D, Payload) -> {data_row, Payload};
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
    Size = byte_size(Payload) - 1,
    case Payload of
        <<Tag:Size/binary, 0>> -> tag(Tag);
        _Unterminated_or_trailing -> malformed_tag(Payload)
    end.

-spec malformed_tag(binary()) -> no_return().
malformed_tag(Payload) ->
    {_Tag, Rest} = cstring(command_complete, Payload),
    minato_protocol:bad(command_complete, trailing_bytes, Rest).

-spec tag(binary()) -> minato_protocol:tag().
tag(<<"SELECT ", Rows/binary>>) ->
    {select, count_or_object(Rows)};
tag(<<"INSERT 0 ", Rows/binary>>) ->
    {insert, count_or_object(Rows)};
tag(<<"UPDATE ", Rows/binary>>) ->
    {update, count_or_object(Rows)};
tag(<<"DELETE ", Rows/binary>>) ->
    {delete, count_or_object(Rows)};
tag(Tag) ->
    case binary:split(Tag, ~" ") of
        [Command] -> {command(Command), undefined};
        [~"INSERT", Rest] -> {insert, count_or_object(after_oid(Rest))};
        [Command, Rest] -> {command(Command), count_or_object(Rest)}
    end.

-spec after_oid(binary()) -> binary().
after_oid(Rest) ->
    case binary:split(Rest, ~" ") of
        [_Oid, Rows] -> Rows;
        [Rows] -> Rows
    end.

-spec count_or_object(binary()) -> non_neg_integer() | atom() | binary().
count_or_object(Bin) ->
    case count(Bin) of
        {ok, Count} -> Count;
        error -> object(Bin)
    end.

%% Reading a decimal string costs more than linear time in its length, and a
%% count that fits in 64 bits has at most 20 digits, so a longer one is not
%% read at all.
-spec count(binary()) -> {ok, non_neg_integer()} | error.
count(Bin) when byte_size(Bin) =< ?LONGEST_COUNT ->
    try binary_to_integer(Bin) of
        Count when Count >= 0 -> {ok, Count};
        _Negative -> error
    catch
        error:badarg -> error
    end;
count(_Bin) ->
    error.

-spec command(binary()) -> atom() | binary().
command(~"ALTER") -> alter;
command(~"ANALYZE") -> analyze;
command(~"BEGIN") -> 'begin';
command(~"CALL") -> call;
command(~"CHECKPOINT") -> checkpoint;
command(~"CLOSE") -> close;
command(~"CLUSTER") -> cluster;
command(~"COMMENT") -> comment;
command(~"COMMIT") -> commit;
command(~"COPY") -> copy;
command(~"CREATE") -> create;
command(~"DEALLOCATE") -> deallocate;
command(~"DECLARE") -> declare;
command(~"DELETE") -> delete;
command(~"DISCARD") -> discard;
command(~"DO") -> do;
command(~"DROP") -> drop;
command(~"EXECUTE") -> execute;
command(~"EXPLAIN") -> explain;
command(~"FETCH") -> fetch;
command(~"GRANT") -> grant;
command(~"IMPORT") -> import;
command(~"INSERT") -> insert;
command(~"LISTEN") -> listen;
command(~"LOAD") -> load;
command(~"LOCK") -> lock;
command(~"MERGE") -> merge;
command(~"MOVE") -> move;
command(~"NOTIFY") -> notify;
command(~"PREPARE") -> prepare;
command(~"REASSIGN") -> reassign;
command(~"REFRESH") -> refresh;
command(~"REINDEX") -> reindex;
command(~"RELEASE") -> release;
command(~"RESET") -> reset;
command(~"REVOKE") -> revoke;
command(~"ROLLBACK") -> rollback;
command(~"SAVEPOINT") -> savepoint;
command(~"SECURITY") -> security;
command(~"SELECT") -> select;
command(~"SET") -> set;
command(~"SHOW") -> show;
command(~"START") -> start;
command(~"TRUNCATE") -> truncate;
command(~"UNLISTEN") -> unlisten;
command(~"UPDATE") -> update;
command(~"VACUUM") -> vacuum;
command(Word) -> unlisted(Word).

-spec object(binary()) -> atom() | binary().
object(~"ACCESS METHOD") -> access_method;
object(~"AGGREGATE") -> aggregate;
object(~"ALL") -> all;
object(~"CAST") -> cast;
object(~"COLLATION") -> collation;
object(~"CONSTRAINT") -> constraint;
object(~"CONSTRAINTS") -> constraints;
object(~"CONVERSION") -> conversion;
object(~"CURSOR") -> cursor;
object(~"CURSOR ALL") -> cursor_all;
object(~"DATABASE") -> database;
object(~"DEFAULT PRIVILEGES") -> default_privileges;
object(~"DOMAIN") -> domain;
object(~"EVENT TRIGGER") -> event_trigger;
object(~"EXTENSION") -> extension;
object(~"FOR KEY SHARE") -> for_key_share;
object(~"FOR NO KEY UPDATE") -> for_no_key_update;
object(~"FOR SHARE") -> for_share;
object(~"FOR UPDATE") -> for_update;
object(~"FOREIGN DATA WRAPPER") -> foreign_data_wrapper;
object(~"FOREIGN SCHEMA") -> foreign_schema;
object(~"FOREIGN TABLE") -> foreign_table;
object(~"FROM") -> from;
object(~"FUNCTION") -> function;
object(~"INDEX") -> index;
object(~"INTO") -> into;
object(~"LABEL") -> label;
object(~"LANGUAGE") -> language;
object(~"LARGE OBJECT") -> large_object;
object(~"MATERIALIZED VIEW") -> materialized_view;
object(~"OPERATOR") -> operator;
object(~"OPERATOR CLASS") -> operator_class;
object(~"OPERATOR FAMILY") -> operator_family;
object(~"OWNED") -> owned;
object(~"PLANS") -> plans;
object(~"POLICY") -> policy;
object(~"PREPARED") -> prepared;
object(~"PROCEDURE") -> procedure;
object(~"PUBLICATION") -> publication;
object(~"REPLICATION SLOT") -> replication_slot;
object(~"ROLE") -> role;
object(~"ROUTINE") -> routine;
object(~"RULE") -> rule;
object(~"SCHEMA") -> schema;
object(~"SEQUENCE") -> sequence;
object(~"SEQUENCES") -> sequences;
object(~"SERVER") -> server;
object(~"STATISTICS") -> statistics;
object(~"SUBSCRIPTION") -> subscription;
object(~"SYSTEM") -> system;
object(~"TABLE") -> table;
object(~"TABLE AS") -> table_as;
object(~"TABLESPACE") -> tablespace;
object(~"TEMP") -> temp;
object(~"TEXT SEARCH CONFIGURATION") -> text_search_configuration;
object(~"TEXT SEARCH DICTIONARY") -> text_search_dictionary;
object(~"TEXT SEARCH PARSER") -> text_search_parser;
object(~"TEXT SEARCH TEMPLATE") -> text_search_template;
object(~"TRANSACTION") -> transaction;
object(~"TRANSFORM") -> transform;
object(~"TRIGGER") -> trigger;
object(~"TYPE") -> type;
object(~"USER MAPPING") -> user_mapping;
object(~"VIEW") -> view;
object(Words) -> unlisted(Words).

%% Copied, because it is kept in a result for as long as the caller keeps the
%% result, and uncopied it would hold the buffer it arrived in for as long.
-spec unlisted(binary()) -> binary().
unlisted(Bin) when byte_size(Bin) =< ?LONGEST_TAG_WORD ->
    case utf8(Bin) of
        true -> binary:copy(Bin);
        false -> minato_protocol:bad(command_complete, tag_word_not_utf8, Bin)
    end;
unlisted(Bin) ->
    minato_protocol:bad(command_complete, tag_word_too_long, byte_size(Bin)).

-spec utf8(binary()) -> boolean().
utf8(<<_/utf8, Rest/binary>>) -> utf8(Rest);
utf8(~"") -> true;
utf8(_Invalid) -> false.

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
