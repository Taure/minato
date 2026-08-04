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
forward reads a whole result set in a handful of calls instead, measured at
5.23 times faster over 1000 rows and 12.78 times over 5000.

Carry-over only works if a decoder can say "not yet" without failing, so
`decode/1` answers `incomplete` for any buffer that stops short of a whole
message, at any byte boundary, and `frame/1` hands those bytes back untouched.

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

`{data_row, Columns}` carries the raw column bytes, because a `DataRow` cannot
be read on its own: the type OID and wire format of each column live in the
`RowDescription` that preceded it. `row/3` takes that dependency as an argument
and decodes the columns through `m:minato_codec`.

```erlang
{[{row_description, Fields}], _} = minato_protocol:frame(Bytes),
{[{data_row, Columns}], _} = minato_protocol:frame(MoreBytes),
minato_protocol:row(Fields, Columns, #{}).
```

## Options

```erlang
#{return_rows_as_maps => boolean(),
  column_name_as_atom => boolean(),
  uuid_format => string | binary,
  datetime_format => datetime | microseconds}
```

`return_rows_as_maps` defaults to `false`, giving a tuple per row. `true` gives
a map keyed by column name. `column_name_as_atom` defaults to `false` and only
affects those map keys.

`column_name_as_atom` is off by default because a column name is not always
something the application wrote. A query built at run time can alias a column
after a value, and every distinct alias would then make an atom that is never
collected. Turn it on for queries whose column names you chose.

`uuid_format` and `datetime_format` are passed through to `m:minato_codec`
unchanged.

## Messages not modelled

Copy-mode messages, function calls and protocol version negotiation decode to
`{unsupported, TypeByte, Payload}` rather than raising. Every backend message
is length prefixed, so a message minato does not model can still be stepped
over without losing the stream.
""".

-export([
    encode/1,
    decode/1,
    frame/1,
    ssl_response/1,
    row/3,
    rows/3,
    result/2,
    server_error/1,
    bad/3
]).

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
    | {data_row, [binary() | null]}
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
    datetime_format => datetime | microseconds
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
    row/0,
    row_map/0,
    result/0,
    opts/0,
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
Decode the one backend message at the front of a buffer.

Returns `{ok, Message, Rest}` with the bytes that follow it, or `incomplete`
when the buffer stops anywhere short of a whole message, header included.

Raises `error({minato_protocol, t:report/0})` when a message that is entirely
present does not fit its documented format.
""".
-spec decode(binary()) -> {ok, backend(), binary()} | incomplete.
decode(<<Type, Length:32, Rest/binary>>) when Length >= 4 ->
    Size = Length - 4,
    case Rest of
        <<Payload:Size/binary, Tail/binary>> ->
            {ok, minato_protocol_backend:decode(Type, Payload), Tail};
        _ ->
            incomplete
    end;
decode(<<Type, Length:32, _/binary>>) ->
    bad(header, length_below_minimum, {Type, Length});
decode(Buffer) when is_binary(Buffer) ->
    incomplete.

-doc """
Decode every complete message in a buffer and hand back the remainder.

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
    case decode(Buffer) of
        {ok, Message, Rest} ->
            {Messages, Remaining} = frame(Rest),
            {[Message | Messages], Remaining};
        incomplete ->
            {[], Buffer}
    end.

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
    CodecOpts = codec_opts(Opts),
    case maps:get(return_rows_as_maps, Opts, false) of
        true ->
            AtomKeys = maps:get(column_name_as_atom, Opts, false),
            row_map(Fields, Columns, AtomKeys, CodecOpts, #{});
        false ->
            list_to_tuple(row_tuple(Fields, Columns, CodecOpts))
    end.

-doc "`row/3` over every row of a result set.".
-spec rows([field()], [[binary() | null]], opts()) -> [row()].
rows(Fields, Rows, Opts) ->
    [row(Fields, Columns, Opts) || Columns <- Rows].

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

-spec row_tuple([field()], [binary() | null], minato_codec:opts()) -> [minato_codec:value()].
row_tuple([], [], _CodecOpts) ->
    [];
row_tuple([#{type_oid := Oid, format := Format} | Fields], [Column | Columns], CodecOpts) ->
    [
        minato_codec:decode(Oid, Column, Format, CodecOpts)
        | row_tuple(Fields, Columns, CodecOpts)
    ];
row_tuple(Fields, Columns, _CodecOpts) ->
    bad(data_row, column_count_mismatch, {length(Fields), length(Columns)}).

-spec row_map([field()], [binary() | null], boolean(), minato_codec:opts(), row_map()) -> row_map().
row_map([], [], _AtomKeys, _CodecOpts, Acc) ->
    Acc;
row_map([Field | Fields], [Column | Columns], AtomKeys, CodecOpts, Acc) ->
    #{type_oid := Oid, format := Format} = Field,
    Value = minato_codec:decode(Oid, Column, Format, CodecOpts),
    row_map(Fields, Columns, AtomKeys, CodecOpts, Acc#{key(Field, AtomKeys) => Value});
row_map(Fields, Columns, _AtomKeys, _CodecOpts, _Acc) ->
    bad(data_row, column_count_mismatch, {length(Fields), length(Columns)}).

-spec key(field(), boolean()) -> atom() | binary().
% elp:ignore W0023 - opt in, and the caller is told what it costs
key(#{name := Name}, true) -> binary_to_atom(Name, utf8);
key(#{name := Name}, false) -> Name.

-spec codec_opts(opts()) -> minato_codec:opts().
codec_opts(#{uuid_format := Uuid, datetime_format := Datetime}) ->
    #{uuid_format => Uuid, datetime_format => Datetime};
codec_opts(#{uuid_format := Uuid}) ->
    #{uuid_format => Uuid};
codec_opts(#{datetime_format := Datetime}) ->
    #{datetime_format => Datetime};
codec_opts(_Opts) ->
    #{}.
