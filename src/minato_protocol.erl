-module(minato_protocol).
-moduledoc """
The PostgreSQL frontend/backend protocol, version 3.0, as a pure function of
bytes.

Terms in, wire bytes out for the messages a client sends. Wire bytes in, terms
out for the messages a server sends. This module does no I/O, starts no process
and keeps no state, so every message can be tested exhaustively without a
database and without a socket.

## Framing

`frame/1` takes whatever bytes have accumulated and returns every complete
message in them together with the bytes left over:

```erlang
{Messages, Rest} = minato_protocol:frame(<<Carried/binary, Received/binary>>).
```

That signature is the point. A backend message is a type byte, a 32 bit length
and a payload, so it is tempting to read the five byte header, then read the
payload, then repeat. That is two reads per message and it scales with the
number of rows. Reading whatever the socket has and carrying the remainder
forward reads a whole result set in a handful of calls instead.

`minato_framer_bench` measures both against each other over a loopback socket.
A 5000 row result set of eight columns takes 61 reads bulk against 10,006 reads
header-then-payload, and 5.3 to 9.1 times less wall clock over repeated runs on
OTP 28 and 29. The read counts are exact and the multiple is not: it moves with
the machine, and on a real network it moves with the round trip too.

Carry-over only works if a decoder can say "not yet" without failing, so
`decode/1` answers `incomplete` for any buffer that stops short of a whole
message, at any byte boundary, and `frame/1` hands those bytes back untouched.

## Total over arbitrary bytes

`frame/1` and `decode/1` never fail in any way other than
`error({minato_protocol, t:report/0})`. Every other input, including bytes that
are not a PostgreSQL stream at all, yields messages and a remainder. That
matters because the bytes reaching the framer are whatever the far end sent, and
a client that can be made to raise `badarg` from a length field has handed the
far end a way to choose which exception the caller sees.

## Bounds

A declared length longer than `max_message_length` raises rather than asking for
more bytes. Without that a five byte header claiming four gigabytes would put
the framer into `incomplete`, and a reader loop doing as it is told would
accumulate until the node died. Refusing the header ends the connection instead,
which is the correct outcome for a server that cannot be believed.

The default is 64 MiB. It is above any row an application selects on purpose and
far below what would hurt a node, and the failure it guards against is not a
large result set: a result set arrives as many messages, and only one message
has to fit under the limit. Raise it for a single very large `bytea` or `text`
column, since PostgreSQL caps one value, and therefore one message, at just
under 1 GiB. A declared length above that ceiling cannot have come from
PostgreSQL at all.

## Binary retention

The messages share the buffer's bytes. `{data_row, Payload}` hands back the
row's bytes rather than a copy, which is what makes framing a large result set
cheap: nothing in a five thousand row buffer is copied on the way out, and the
payload is consumed by `decode_row/2` and dropped a row later.

The cost of that is the usual one. A sub-binary keeps the whole buffer it points
into alive, so a column value the application keeps holds the megabyte it
arrived in. `binary:copy/1` on a value being kept for longer than the query is
the caller's fix, and it is the caller's because only the caller knows which
values those are. Copying them all here would put a copy of the entire result
set on the hot path to protect the few values that outlive it.

The remainder is the one place where the framer copies, because it is the one
sub-binary whose lifetime the framer knows. It is held until the next read
completes, which on an idle pooled connection is unbounded, and it is by
construction small while the buffer it points into is not: a three byte partial
header retaining a 64 KiB read, across a hundred pooled connections, is
megabytes of buffers kept alive by bytes nobody is waiting on. So a remainder is
copied when it is at most a quarter of its buffer, which bounds the copy at a
third of what it releases. A larger remainder is left alone, because copying it
would cost more than it frees, and a half arrived multi-megabyte row would then
be copied again on every read as it grew.

## Errors from the server are data

`{error_response, t:fields/0}` is an ordinary decoded message, not an exception.
A failing statement is a normal outcome of running SQL and the caller has to
branch on it. `server_error/1` wraps the fields in the tagged form consumers
match on:

```erlang
{error, {pgsql_error, #{code := ~"23505", constraint := ~"users_email_key"}}}
```

Keys are atoms and values are binaries, `code` is the SQLSTATE, and `code` and
`message` are always present.

A malformed message is the opposite case and raises
`error({minato_protocol, t:report/0})`. Bytes that do not fit the format the
server itself announced are a bug, not a condition to branch on.

## Rows

`{data_row, Payload}` carries the row's bytes undivided, because a `DataRow`
cannot be read on its own: the type OID and wire format of each column live in
the `RowDescription` that preceded it. `decoder/2` turns that description into
the answer once, and `decode_row/2` walks the payload cutting and decoding each
column in the same pass - which is the whole reason the payload is not split
here.

```erlang
{[{row_description, Fields}], _} = minato_protocol:frame(Bytes),
{[{data_row, Payload}], _} = minato_protocol:frame(MoreBytes),
Decoder = minato_protocol:decoder(Fields, #{}),
minato_protocol:decode_row(Decoder, Payload).
```

`columns/1` splits a payload into the raw column bytes for a caller that wants
them without decoding.

## Options

```erlang
#{return_rows_as_maps => boolean(),
  column_name_as_atom => boolean(),
  uuid_format => string | binary,
  datetime_format => datetime | microseconds,
  numeric_format => binary | float}
```

`return_rows_as_maps` defaults to `false`, giving a tuple per row. `true` gives
a map keyed by column name. `column_name_as_atom` defaults to `false` and only
affects those map keys.

`column_name_as_atom` is off by default because a column name is not always
something the application wrote. A query built at run time can alias a column
after a value, and every distinct alias would then make an atom that is never
collected. Turn it on for queries whose column names you chose.

`uuid_format`, `datetime_format` and `numeric_format` are passed through to
`m:minato_codec` unchanged.

## Messages not modelled

Copy-mode messages, function calls and protocol version negotiation decode to
`{unsupported, TypeByte, Payload}` rather than raising. Every backend message
is length prefixed, so a message minato does not model can still be stepped
over without losing the stream.
""".

-export([
    encode/1,
    decode/1,
    decode/2,
    frame/1,
    frame/2,
    max_message_length/1,
    ssl_response/1,
    row/3,
    rows/3,
    columns/1,
    decoder/2,
    decode_row/2,
    decode_columns/2,
    result/2,
    server_error/1,
    bad/3
]).

-define(DEFAULT_MAX_MESSAGE_LENGTH, 67108864).
-define(SMALLEST_MESSAGE_LENGTH, 4).
-define(HEAP_BINARY_LIMIT, 64).
-define(RETENTION_RATIO, 4).

-doc "A message a client sends to a server.".
-type frontend() ::
    {startup, #{binary() => binary()}}
    | ssl_request
    | {cancel_request, Pid :: integer(), Secret :: integer()}
    | {password, iodata()}
    | {sasl_initial_response, Mechanism :: iodata(), Data :: iodata() | null}
    | {sasl_response, iodata()}
    | {query, iodata()}
    | {parse, Name :: iodata(), Query :: iodata(), Parameters :: [minato_oid:oid()]}
    | {bind, Portal :: iodata(), Statement :: iodata(),
        ParameterFormats :: [
            minato_codec:format()
        ],
        Parameters :: [iodata() | null], ResultFormats :: [minato_codec:format()]}
    | {describe, target(), Name :: iodata()}
    | {execute, Portal :: iodata(), MaxRows :: non_neg_integer()}
    | sync
    | flush
    | {close, target(), Name :: iodata()}
    | terminate.

-doc "A message a server sends to a client.".
-type backend() ::
    authentication_ok
    | authentication_cleartext_password
    | {authentication_md5_password, Salt :: binary()}
    | {authentication_sasl, Mechanisms :: [binary()]}
    | {authentication_sasl_continue, Data :: binary()}
    | {authentication_sasl_final, Data :: binary()}
    | {backend_key_data, Pid :: integer(), Secret :: integer()}
    | {parameter_status, Name :: binary(), Value :: binary()}
    | {ready_for_query, transaction_status()}
    | {row_description, [field()]}
    | {data_row, Payload :: binary()}
    | {rows, [row()]}
    | {command_complete, tag()}
    | empty_query_response
    | {error_response, fields()}
    | {notice_response, fields()}
    | parse_complete
    | bind_complete
    | close_complete
    | no_data
    | {parameter_description, [minato_oid:oid()]}
    | portal_suspended
    | {notification_response, Pid :: integer(), Channel :: binary(), Payload :: binary()}
    | {unsupported, byte(), binary()}.

-doc "What `Describe` and `Close` can be pointed at.".
-type target() :: statement | portal.

-doc """
What `ReadyForQuery` reports.

`failed` is a transaction block in which a statement has already errored, so
every further statement is rejected until it is rolled back.
""".
-type transaction_status() :: idle | transaction | failed.

-doc "One column of a `RowDescription`.".
-type field() :: #{
    name := binary(),
    table_oid := non_neg_integer(),
    column := integer(),
    type_oid := minato_oid:oid(),
    type_size := integer(),
    type_modifier := integer(),
    format := minato_codec:format()
}.

-doc """
The fields of an `ErrorResponse` or a `NoticeResponse`.

`code` is the SQLSTATE and `message` is the primary human readable text. Both
are documented as always sent, and both are filled in with an empty binary if a
server omits them, so that a consumer can match on them without a case for the
server having lied.

Every other field is present only when the server sent it. Field types minato
does not recognise are discarded, which is what the protocol documentation asks
a client to do with them.
""".
-type fields() :: #{
    code := binary(),
    message := binary(),
    severity => binary(),
    severity_non_localised => binary(),
    detail => binary(),
    hint => binary(),
    position => binary(),
    internal_position => binary(),
    internal_query => binary(),
    where => binary(),
    schema => binary(),
    table => binary(),
    column => binary(),
    data_type => binary(),
    constraint => binary(),
    file => binary(),
    line => binary(),
    routine => binary()
}.

-doc """
A parsed `CommandComplete` tag: what ran, and how much of it.

The second element is a row count for the tags that carry one, and an atom
otherwise: `undefined` where there is nothing to count, as in `{'begin',
undefined}`, and the object acted on for a tag that names one, as in `{create,
table}`.
""".
-type tag() :: {atom(), non_neg_integer() | atom()}.

-doc "A row returned under `return_rows_as_maps`, keyed by column name.".
-type row_map() :: #{atom() | binary() => minato_codec:value()}.

-doc "How to read a row, from `decoder/2`.".
-opaque decoder() :: {boolean(), [{atom() | binary(), minato_codec:decoder()}]}.

-doc "One decoded row, a tuple by default and a `t:row_map/0` under `return_rows_as_maps`.".
-type row() :: tuple() | row_map().

-doc "Everything a completed query produced.".
-type result() :: #{
    command := atom(),
    rows := [row()],
    num_rows := non_neg_integer() | atom()
}.

-doc "Decode-time options. See the module documentation.".
-type opts() :: #{
    return_rows_as_maps => boolean(),
    column_name_as_atom => boolean(),
    uuid_format => string | binary,
    datetime_format => datetime | microseconds,
    numeric_format => binary | float
}.

-doc """
Framing options.

`max_message_length` is the longest message the framer will wait for, in bytes,
and defaults to 64 MiB. See the module documentation for what it is for and when
to raise it. There is no value that turns the bound off; a caller that wants the
most PostgreSQL can send asks for `1073741823`.
""".
-type frame_opts() :: #{
    max_message_length => pos_integer(), decoder => decoder(), decode_opts => opts()
}.

-doc "The map carried by an `error({minato_protocol, Report})` exception.".
-type report() :: #{message := term(), reason := term(), data := term()}.

-export_type([
    frontend/0,
    backend/0,
    target/0,
    transaction_status/0,
    field/0,
    fields/0,
    tag/0,
    decoder/0,
    row/0,
    row_map/0,
    result/0,
    opts/0,
    frame_opts/0,
    report/0
]).

-doc """
Encode a frontend message.

```erlang
1> iolist_to_binary(minato_protocol:encode(sync)).
<<83,0,0,0,4>>
2> iolist_to_binary(minato_protocol:encode({execute, ~"", 0})).
<<69,0,0,0,9,0,0,0,0,0>>
```

`{startup, Parameters}` and `{cancel_request, Pid, Secret}` carry no type byte,
which is why the startup packet and a cancellation are told apart by their
length and version fields rather than by a tag. A cancellation is sent on a
connection of its own and is never answered.

Encoding is total for every well formed message and raises `function_clause` on
anything else, because a frontend message is built by minato itself and a term
that does not fit is a mistake in the calling code rather than something the
network did.
""".
-spec encode(frontend()) -> iodata().
encode(Message) ->
    minato_protocol_frontend:encode(Message).

-doc """
Decode the one backend message at the front of a buffer, under the default
bound.
""".
-spec decode(binary()) -> {ok, backend(), binary()} | incomplete.
decode(Buffer) ->
    message(Buffer, ?DEFAULT_MAX_MESSAGE_LENGTH).

-doc """
Decode the one backend message at the front of a buffer.

Returns `{ok, Message, Rest}` with the bytes that follow it, or `incomplete`
when the buffer stops anywhere short of a whole message, header included.

Raises `error({minato_protocol, t:report/0})` when a message that is entirely
present does not fit its documented format, and when a header declares a length
longer than `max_message_length` or shorter than the four bytes the length field
itself occupies.
""".
-spec decode(binary(), frame_opts()) -> {ok, backend(), binary()} | incomplete.
decode(Buffer, Opts) ->
    message(Buffer, max_message_length(Opts)).

-doc """
Decode every complete message in a buffer and hand back the remainder, under the
default bound.

```erlang
1> minato_protocol:frame(<<49, 0,0,0,4, 50, 0,0,0,4, 51, 0,0>>).
{[parse_complete,bind_complete],<<51,0,0>>}
```

The remainder is the input to the next call, prepended to whatever arrives
next. A buffer holding no complete message returns `{[], Buffer}`, so feeding
bytes one at a time is correct, just slow.
""".
-spec frame(binary()) -> {[backend()], binary()}.
frame(Buffer) ->
    framed(Buffer, ?DEFAULT_MAX_MESSAGE_LENGTH).

-doc """
Decode every complete message in a buffer and hand back the remainder.

Where a message list is split across calls makes no difference to what comes
out: framing a buffer, then framing its remainder prepended to the next read,
gives the same messages in the same order as framing the whole stream at once,
whatever byte boundaries the reads happened to fall on.

With a `decoder` in `Opts`, a contiguous run of `DataRow` messages comes back
as one `{rows, Rows}` message with the rows already decoded, instead of one
`{data_row, Payload}` for each. A result set is mostly such a run, and framing
it into a list for the layer above to walk again costs an allocation and a
traversal per row. Anything that is not a row is unaffected, and a run is ended
by the first message that is not one, so a `NoticeResponse` arriving between
rows splits the run rather than being swallowed by it.

The decoder describes one statement's rows. Framing a different statement's
rows with it would decode them against the wrong plan, which is wrong data
rather than an error, so a reader that keeps frame options across statements
has to clear it. `m:minato_conn` does that through `minato_conn:decoding/2`.
""".
-spec frame(binary(), frame_opts()) -> {[backend()], binary()}.
frame(Buffer, Opts) ->
    framed(
        Buffer,
        max_message_length(Opts),
        maps:get(decoder, Opts, undefined),
        maps:get(decode_opts, Opts, undefined)
    ).

-doc """
The bound `frame/2` and `decode/2` will apply to these options.

Exported so that a reader can size its own accumulation the same way the framer
does, rather than keeping a second copy of the default.
""".
-spec max_message_length(frame_opts()) -> pos_integer().
max_message_length(#{max_message_length := Max}) when
    is_integer(Max), Max >= ?SMALLEST_MESSAGE_LENGTH
->
    Max;
max_message_length(#{max_message_length := Max}) ->
    bad(frame_opts, invalid_max_message_length, Max);
max_message_length(_Opts) ->
    ?DEFAULT_MAX_MESSAGE_LENGTH.

-doc """
Read the server's one byte answer to `SSLRequest`.

`accepted` means every later byte on the connection is TLS. `rejected` means
the server will not do TLS on this connection and the caller decides whether
plaintext is acceptable.

`error_response` means the server answered with a message rather than a verdict,
which a server too old to know `SSLRequest` does. The byte is left in the buffer
in that case, so `frame/1` reads the whole `ErrorResponse` next.
""".
-spec ssl_response(binary()) -> {ok, accepted | rejected | error_response, binary()} | incomplete.
ssl_response(<<$S, Rest/binary>>) ->
    {ok, accepted, Rest};
ssl_response(<<$N, Rest/binary>>) ->
    {ok, rejected, Rest};
ssl_response(<<$E, _/binary>> = Buffer) ->
    {ok, error_response, Buffer};
ssl_response(~"") ->
    incomplete;
ssl_response(Buffer) ->
    bad(ssl_response, unexpected_answer, Buffer).

-doc """
Decode the columns of one `DataRow` against the `RowDescription` they belong to.

A tuple by default, and a map keyed by column name under
`return_rows_as_maps => true`. Two columns with the same name collapse into one
map key; a query whose columns need telling apart has to name them apart, or
take tuples.

Raises `error({minato_protocol, t:report/0})` when the row and the description
disagree on how many columns there are, and `error({minato_codec, _})` when a
column's bytes do not fit the type the description gave it.
""".
-spec row([field()], [binary() | null], opts()) -> row().
row(Fields, Columns, Opts) ->
    decode_columns(decoder(Fields, Opts), Columns).

-doc """
Work out how to read a row, once, from the description of its columns.

`row/3` answers the same questions for every row of a result set: what type is
this column, is it an array, what are the decode options, is the caller taking
maps, are the keys atoms. None of those change between rows, and a thousand
rows asked them a thousand times. A decoder answers them once, at the
`RowDescription`, and `decode_row/2` applies the answer.

`row/3` still exists and now builds one of these per call, which is the right
cost for a caller decoding a single row.
""".
-spec decoder([field()], opts()) -> decoder().
decoder(Fields, Opts) ->
    CodecOpts = codec_opts(Opts),
    Atoms = maps:get(column_name_as_atom, Opts, false),
    Columns = [
        {key(Field, Atoms), minato_codec:decoder(Oid, Format, CodecOpts)}
     || #{type_oid := Oid, format := Format} = Field <- Fields
    ],
    {maps:get(return_rows_as_maps, Opts, false), Columns}.

-doc """
Decode one `DataRow` payload with a decoder from `decoder/2`.

One pass: each column's length is read, its bytes are cut, and the value is
decoded, without building the list of sub-binaries in between. That list was
one allocation per column per row and existed only to be walked immediately
afterwards.
""".
-spec decode_row(decoder(), binary()) -> row().
decode_row({false, Columns}, <<Count:16, Payload/binary>>) ->
    list_to_tuple(decoded_tuple(Columns, Count, Payload));
decode_row({true, Columns}, <<Count:16, Payload/binary>>) ->
    decoded_map(Columns, Count, Payload, #{});
decode_row(_Decoder, Payload) ->
    bad(data_row, malformed, Payload).

-doc """
Decode a row from column bytes already split out, for a caller that has them.

The payload form in `decode_row/2` is what a result set uses, because splitting
and decoding in one pass is the point. This is for `row/3` and `rows/3`, whose
callers hold columns rather than a message.
""".
-spec decode_columns(decoder(), [binary() | null]) -> row().
decode_columns({false, Columns}, Values) ->
    list_to_tuple(listed_tuple(Columns, Values));
decode_columns({true, Columns}, Values) ->
    listed_map(Columns, Values, #{}).

-spec listed_tuple([{atom() | binary(), minato_codec:decoder()}], [binary() | null]) ->
    [minato_codec:value()].
listed_tuple([], []) ->
    [];
listed_tuple([_Column | Columns], [null | Values]) ->
    [null | listed_tuple(Columns, Values)];
listed_tuple([{_Key, Decoder} | Columns], [Value | Values]) ->
    [minato_codec:decode(Decoder, Value) | listed_tuple(Columns, Values)];
listed_tuple(Columns, Values) ->
    bad(data_row, column_count_mismatch, {length(Columns), length(Values)}).

-spec listed_map([{atom() | binary(), minato_codec:decoder()}], [binary() | null], row_map()) ->
    row_map().
listed_map([], [], Row) ->
    Row;
listed_map([{Key, _Skipped} | Columns], [null | Values], Row) ->
    listed_map(Columns, Values, Row#{Key => null});
listed_map([{Key, Decoder} | Columns], [Value | Values], Row) ->
    listed_map(Columns, Values, Row#{Key => minato_codec:decode(Decoder, Value)});
listed_map(Columns, Values, _Row) ->
    bad(data_row, column_count_mismatch, {length(Columns), length(Values)}).

-doc "Split a `DataRow` payload into its raw column bytes, without decoding.".
-spec columns(binary()) -> [binary() | null].
columns(<<Count:16, Payload/binary>>) ->
    raw(Count, Payload);
columns(Payload) ->
    bad(data_row, malformed, Payload).

-spec raw(non_neg_integer(), binary()) -> [binary() | null].
raw(0, ~"") ->
    [];
raw(Remaining, <<-1:32/signed, Rest/binary>>) when Remaining > 0 ->
    [null | raw(Remaining - 1, Rest)];
raw(Remaining, <<Length:32/signed, Rest/binary>>) when Remaining > 0, Length >= 0 ->
    {Value, Tail} = cut(Length, Rest),
    [Value | raw(Remaining - 1, Tail)];
raw(_Remaining, <<Length:32/signed, _Rest/binary>>) ->
    bad(data_row, {negative_column_length, Length}, Length);
raw(_Remaining, Payload) ->
    bad(data_row, malformed, Payload).

-doc false.
-spec cut(non_neg_integer(), binary()) -> {binary(), binary()}.
cut(Length, Payload) when byte_size(Payload) >= Length ->
    <<Value:Length/binary, Tail/binary>> = Payload,
    {Value, Tail};
cut(Length, Payload) ->
    bad(data_row, column_longer_than_the_message, {Length, byte_size(Payload)}).

-spec decoded_tuple(
    [{atom() | binary(), minato_codec:decoder()}], non_neg_integer(), binary()
) -> [minato_codec:value()].
decoded_tuple([], 0, ~"") ->
    [];
decoded_tuple([_Column | Columns], Remaining, <<-1:32/signed, Rest/binary>>) when Remaining > 0 ->
    [null | decoded_tuple(Columns, Remaining - 1, Rest)];
decoded_tuple(
    [{_Key, Decoder} | Columns], Remaining, <<Length:32/signed, Value:Length/binary, Rest/binary>>
) when
    Remaining > 0, Length >= 0
->
    [minato_codec:decode(Decoder, Value) | decoded_tuple(Columns, Remaining - 1, Rest)];
decoded_tuple(_Columns, Remaining, <<Length:32/signed, _Rest/binary>>) when
    Remaining > 0, Length < 0
->
    bad(data_row, {negative_column_length, Length}, Length);
decoded_tuple(_Columns, Remaining, <<Length:32/signed, Rest/binary>>) when Remaining > 0 ->
    bad(data_row, column_longer_than_the_message, {Length, byte_size(Rest)});
decoded_tuple(Columns, Remaining, _Payload) ->
    bad(data_row, column_count_mismatch, {length(Columns), Remaining}).

-spec decoded_map(
    [{atom() | binary(), minato_codec:decoder()}], non_neg_integer(), binary(), row_map()
) -> row_map().
decoded_map([], 0, ~"", Row) ->
    Row;
decoded_map([{Key, _Skipped} | Columns], Remaining, <<-1:32/signed, Rest/binary>>, Row) when
    Remaining > 0
->
    decoded_map(Columns, Remaining - 1, Rest, Row#{Key => null});
decoded_map(
    [{Key, Decoder} | Columns],
    Remaining,
    <<Length:32/signed, Value:Length/binary, Rest/binary>>,
    Row
) when
    Remaining > 0, Length >= 0
->
    decoded_map(Columns, Remaining - 1, Rest, Row#{Key => minato_codec:decode(Decoder, Value)});
decoded_map(_Columns, Remaining, <<Length:32/signed, _Rest/binary>>, _Row) when
    Remaining > 0, Length < 0
->
    bad(data_row, {negative_column_length, Length}, Length);
decoded_map(_Columns, Remaining, <<Length:32/signed, Rest/binary>>, _Row) when Remaining > 0 ->
    bad(data_row, column_longer_than_the_message, {Length, byte_size(Rest)});
decoded_map(Columns, Remaining, _Payload, _Row) ->
    bad(data_row, column_count_mismatch, {length(Columns), Remaining}).

-doc "`row/3` over every row of a result set.".
-spec rows([field()], [[binary() | null]], opts()) -> [row()].
rows(Fields, Rows, Opts) ->
    Decoder = decoder(Fields, Opts),
    [decode_columns(Decoder, Columns) || Columns <- Rows].

-doc """
Assemble what a completed query produced from its `CommandComplete` tag and its
rows.

`num_rows` comes from the tag rather than from the rows, because the two differ
on purpose: an `UPDATE` reports how many rows it changed while returning none,
and an `INSERT ... RETURNING` reports how many it wrote.
""".
-spec result(tag(), [row()]) -> result().
result({Command, NumRows}, Rows) ->
    #{command => Command, rows => Rows, num_rows => NumRows}.

-doc """
Wrap decoded `ErrorResponse` fields in the tagged form a caller branches on.

```erlang
1> minato_protocol:server_error(#{code => ~"23505", message => ~"duplicate key"}).
{error,{pgsql_error,#{code => <<"23505">>,message => <<"duplicate key">>}}}
```
""".
-spec server_error(fields()) -> {error, {pgsql_error, fields()}}.
server_error(Fields) ->
    {error, {pgsql_error, Fields}}.

-doc """
Raise a protocol failure.

Exported so that the protocol modules share one exception shape. Not part of the
API a caller of minato uses.
""".
-spec bad(term(), term(), term()) -> no_return().
bad(Message, Reason, Data) ->
    error({minato_protocol, #{message => Message, reason => Reason, data => Data}}).

-spec framed(binary(), pos_integer()) -> {[backend()], binary()}.
framed(Buffer, Max) ->
    framed(Buffer, Max, undefined, undefined).

-spec framed(binary(), pos_integer(), decoder() | undefined, opts() | undefined) ->
    {[backend()], binary()}.
framed(Buffer, Max, Decoder, DecodeOpts) ->
    {Messages, Rest} = messages(Buffer, Max, Decoder, DecodeOpts),
    {Messages, remainder(Rest, byte_size(Buffer))}.

-spec messages(binary(), pos_integer(), decoder() | undefined, opts() | undefined) ->
    {[backend()], binary()}.
messages(<<$D, _/binary>> = Buffer, Max, Decoder, DecodeOpts) when Decoder =/= undefined ->
    case run(Buffer, Max, Decoder) of
        {[], _Rest} ->
            {[], Buffer};
        {Run, Rest} ->
            {Messages, Remaining} = messages(Rest, Max, Decoder, DecodeOpts),
            {[{rows, Run} | Messages], Remaining}
    end;
messages(Buffer, Max, Decoder, DecodeOpts) ->
    case message(Buffer, Max) of
        {ok, Message, Rest} ->
            Next = following(Message, Decoder, DecodeOpts),
            {Messages, Remaining} = messages(Rest, Max, Next, DecodeOpts),
            {[Message | Messages], Remaining};
        incomplete ->
            {[], Buffer}
    end.

-doc false.
-spec following(backend(), decoder() | undefined, opts() | undefined) -> decoder() | undefined.
following(_Message, Decoder, undefined) ->
    Decoder;
following({row_description, Fields}, _Decoder, DecodeOpts) ->
    decoder(Fields, DecodeOpts);
following({command_complete, _Tag}, _Decoder, _DecodeOpts) ->
    undefined;
following(_Message, Decoder, _DecodeOpts) ->
    Decoder.

-spec run(binary(), pos_integer(), decoder()) -> {[row()], binary()}.
run(<<$D, Length:32/signed, _/binary>>, Max, _Decoder) when Length > Max ->
    bad(header, message_too_long, {$D, Length, Max});
run(<<$D, Length:32/signed, _/binary>>, _Max, _Decoder) when
    Length < ?SMALLEST_MESSAGE_LENGTH
->
    bad(header, length_below_minimum, {$D, Length});
run(<<$D, Length:32/signed, Body/binary>> = Buffer, Max, Decoder) ->
    Size = Length - ?SMALLEST_MESSAGE_LENGTH,
    case Body of
        <<Payload:Size/binary, Tail/binary>> ->
            Row = decode_row(Decoder, Payload),
            {Rows, Remaining} = run(Tail, Max, Decoder),
            {[Row | Rows], Remaining};
        _ ->
            {[], Buffer}
    end;
run(Buffer, _Max, _Decoder) ->
    {[], Buffer}.

-spec message(binary(), pos_integer()) -> {ok, backend(), binary()} | incomplete.
message(<<Type, Length:32/signed, _/binary>>, Max) when Length > Max ->
    bad(header, message_too_long, {Type, Length, Max});
message(<<Type, Length:32/signed, _/binary>>, _Max) when Length < ?SMALLEST_MESSAGE_LENGTH ->
    bad(header, length_below_minimum, {Type, Length});
message(<<Type, Length:32/signed, Rest/binary>>, _Max) ->
    Size = Length - ?SMALLEST_MESSAGE_LENGTH,
    case Rest of
        <<Payload:Size/binary, Tail/binary>> ->
            {ok, minato_protocol_backend:decode(Type, Payload), Tail};
        _ ->
            incomplete
    end;
message(Buffer, _Max) when is_binary(Buffer) ->
    incomplete.

-spec remainder(binary(), non_neg_integer()) -> binary().
remainder(Rest, BufferSize) when
    BufferSize > ?HEAP_BINARY_LIMIT, byte_size(Rest) * ?RETENTION_RATIO =< BufferSize
->
    binary:copy(Rest);
remainder(Rest, _BufferSize) ->
    Rest.

-spec key(field(), boolean()) -> atom() | binary().
% elp:ignore W0023 - opt in, and the caller is told what it costs
key(#{name := Name}, true) -> binary_to_atom(Name, utf8);
key(#{name := Name}, false) -> Name.

-spec codec_opts(opts()) -> minato_codec:opts().
codec_opts(Opts) ->
    #{
        uuid_format => maps:get(uuid_format, Opts, string),
        datetime_format => maps:get(datetime_format, Opts, datetime),
        numeric_format => maps:get(numeric_format, Opts, binary)
    }.
