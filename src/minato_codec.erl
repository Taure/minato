-module(minato_codec).
-moduledoc """
Erlang terms to PostgreSQL wire bytes and back, for both the binary and the text
wire format.

This module is pure. It does no I/O, starts no process, reads no ETS table and
keeps no state, so a codec can be tested exhaustively without a database and
reused wherever the bytes come from.

## The two formats

PostgreSQL will send and accept every value in either a binary or a text
representation, chosen per parameter and per result column. minato implements
both. Binary is what the protocol layer asks for on the types it knows;
text is what makes an unknown type still usable, because any value at all can be
carried as its text representation.

`preferred_format/1` says which format to request for a given OID.

## NULL

`null` is the NULL sentinel in both directions, and it is the only one.

NULL is not a value in the wire format: it is a length of -1 where the bytes
would be. `encode/4` therefore returns the atom `null` rather than `iodata()`
when the value is `null`, and the caller writing the message body turns that
into a length of -1. `decode/4` accepts `null` in the same place and returns
`null`.

## Errors

Every function in this module either returns a value or raises. A codec failure
is `error({minato_codec, Report})`, where `Report` is a map with `type`,
`reason` and `value` keys.

Raising rather than returning `{error, _}` is deliberate: decoding a result set
calls `decode/4` once per cell, and a failure there means the bytes disagree
with the OID the server itself announced, which is a bug and not a condition to
branch on. One `try` around a whole row costs nothing, a tagged tuple per cell
does.

## Options

```erlang
#{uuid_format => string | binary,
  datetime_format => datetime | microseconds,
  numeric_format => binary | float}
```

All three are decode-time options; encoding accepts every form regardless.

- `numeric_format` defaults to `binary`, giving the exact decimal text
  PostgreSQL sent. `float` converts it, which loses exactness and is the right
  answer for an average or a ratio and the wrong one for money. A client that
  did this by default would be quietly lossy about the one type chosen for not
  being lossy, which is why it has to be asked for.
- `uuid_format` defaults to `string`, giving the 36 character hyphenated form.
  `binary` gives the 16 raw bytes.
- `datetime_format` defaults to `datetime`, giving `{Hour, Minute, Second}` and
  `{{Year, Month, Day}, {Hour, Minute, Second}}` tuples with sub-second
  precision discarded. `microseconds` is lossless and gives integers. See
  `m:minato_codec_datetime` for exactly how the two differ.

## Types covered

`bool`, `bytea`, `int2`, `int4`, `int8`, `float4`, `float8`, `numeric`, `text`,
`varchar`, `json`, `jsonb`, `uuid`, `date`, `time`, `timestamp`, `timestamptz`,
and the array type of each of them.

## Examples

```erlang
1> minato_codec:encode(23, 42, binary).
<<0,0,0,42>>
2> minato_codec:decode(23, <<0,0,0,42>>, binary).
42
3> minato_codec:decode(1009, ~"{a,NULL,\"b,c\"}", text).
[<<"a">>,null,<<"b,c">>]
4> minato_codec:encode(2950, ~"0196f0a9-1c4f-7e21-9b3a-6d2c5e8f1a44", binary).
<<1,150,240,169,28,79,126,33,155,58,109,44,94,143,26,68>>
```
""".

-export([
    encode/3,
    encode/4,
    decode/3,
    decode/4,
    supports/1,
    preferred_format/1,
    bad/3,
    to_binary/2
]).

-doc "Which of the two PostgreSQL wire representations a call is about.".
-type format() :: binary | text.

-doc "A calendar date, the shape of `t:calendar:date/0` without the range refinements.".
-type date() :: {integer(), integer(), integer()}.

-doc "A wall clock time, the shape of `t:calendar:time/0` without the range refinements.".
-type time() :: {integer(), integer(), integer()}.

-doc "A date and a time, the shape of `t:calendar:datetime/0`.".
-type datetime() :: {date(), time()}.

-doc "Every Erlang shape a codec in minato produces or accepts.".
-type value() ::
    null
    | boolean()
    | integer()
    | float()
    | binary()
    | nan
    | infinity
    | neg_infinity
    | date()
    | datetime()
    | [value()].

-doc "Decode-time options. See the module documentation.".
-type opts() :: #{
    uuid_format => string | binary,
    numeric_format => binary | float,
    datetime_format => datetime | microseconds
}.

-doc "The map carried by an `error({minato_codec, Report})` exception.".
-type report() :: #{type := term(), reason := term(), value := term()}.

-export_type([format/0, value/0, opts/0, date/0, time/0, datetime/0, report/0]).

-doc "`encode/4` with the default options.".
-spec encode(minato_oid:oid(), term(), format()) -> iodata() | null.
encode(Oid, Value, Format) ->
    encode(Oid, Value, Format, #{}).

-doc """
Encode an Erlang term to the wire bytes of the type named by `Oid`.

Returns the atom `null` for a `null` value, because NULL is carried by a length
of -1 and has no bytes of its own. Raises `error({minato_codec, t:report/0})`
when the term does not fit the type.

For an OID minato has no codec for, the text format passes `iodata()` through
unchanged and the binary format raises: minato cannot invent a binary
representation for a type it does not know, but it can always let the server
parse the text one.
""".
-spec encode(minato_oid:oid(), term(), format(), opts()) -> iodata() | null.
encode(_Oid, null, _Format, _Opts) ->
    null;
encode(Oid, Value, Format, Opts) ->
    case minato_oid:name(Oid) of
        undefined -> encode_unknown(Oid, Value, Format);
        {array, _Element} -> minato_codec_array:encode(Oid, Value, Format, Opts);
        Name -> encode_named(Name, Value, Format, Opts)
    end.

-doc "`decode/4` with the default options.".
-spec decode(minato_oid:oid(), binary() | null, format()) -> value().
decode(Oid, Bin, Format) ->
    decode(Oid, Bin, Format, #{}).

-doc """
Decode wire bytes of the type named by `Oid` to an Erlang term.

`null` in, `null` out. Raises `error({minato_codec, t:report/0})` when the bytes
do not fit the type.

For an OID minato has no codec for, the text format returns the bytes unchanged
so the caller can parse them, and the binary format raises.
""".
-spec decode(minato_oid:oid(), binary() | null, format(), opts()) -> value().
decode(_Oid, null, _Format, _Opts) ->
    null;
decode(Oid, Bin, Format, Opts) ->
    case minato_oid:name(Oid) of
        undefined -> decode_unknown(Oid, Bin, Format);
        {array, _Element} -> minato_codec_array:decode(Oid, Bin, Format, Opts);
        Name -> decode_named(Name, Bin, Format, Opts)
    end.

-doc "Whether minato has a codec for this OID.".
-spec supports(minato_oid:oid()) -> boolean().
supports(Oid) ->
    minato_oid:name(Oid) =/= undefined.

-doc """
The wire format to request for a column or parameter of this type.

`binary` for every type minato has a codec for, `text` for everything else, so
that an unrecognised type still arrives in a form the caller can read.
""".
-spec preferred_format(minato_oid:oid()) -> format().
preferred_format(Oid) ->
    case supports(Oid) of
        true -> binary;
        false -> text
    end.

-doc """
Raise a codec failure.

Exported so that the codec modules share one exception shape. Not part of the
API a caller of minato uses.
""".
-spec bad(term(), term(), term()) -> no_return().
bad(Type, Reason, Value) ->
    error({minato_codec, #{type => Type, reason => Reason, value => Value}}).

-doc """
Flatten a value the caller offered as `iodata()` into a binary.

Written out rather than handed to `iolist_to_binary/1` so that a caller who
passes something that is not `iodata()` gets a codec failure naming the type
instead of a bare `badarg`. Binaries, which is what every hot path passes,
never reach it.

Exported so that the codec modules share one implementation. Not part of the
API a caller of minato uses.
""".
-spec to_binary(term(), term()) -> binary().
to_binary(Type, Value) ->
    to_binary(Type, Value, ~"").

-spec to_binary(term(), term(), binary()) -> binary().
to_binary(_Type, [], Acc) ->
    Acc;
to_binary(Type, [Head | Tail], Acc) when is_integer(Head), Head >= 0, Head =< 255 ->
    to_binary(Type, Tail, <<Acc/binary, Head>>);
to_binary(Type, [Head | Tail], Acc) when is_binary(Head) ->
    to_binary(Type, Tail, <<Acc/binary, Head/binary>>);
to_binary(Type, [Head | Tail], Acc) when is_list(Head) ->
    to_binary(Type, Tail, to_binary(Type, Head, Acc));
to_binary(_Type, Tail, Acc) when is_binary(Tail) ->
    <<Acc/binary, Tail/binary>>;
to_binary(Type, Value, _Acc) ->
    bad(Type, not_iodata, Value).

-spec encode_named(minato_oid:name(), term(), format(), opts()) -> iodata().
encode_named(numeric, Value, Format, Opts) ->
    minato_codec_numeric:encode(numeric, Value, Format, Opts);
encode_named(Name, Value, Format, Opts) when
    Name =:= date; Name =:= time; Name =:= timestamp; Name =:= timestamptz
->
    minato_codec_datetime:encode(Name, Value, Format, Opts);
encode_named(Name, Value, Format, Opts) ->
    minato_codec_scalar:encode(Name, Value, Format, Opts).

-spec decode_named(minato_oid:name(), binary(), format(), opts()) -> value().
decode_named(numeric, Bin, Format, Opts) ->
    minato_codec_numeric:decode(numeric, Bin, Format, Opts);
decode_named(Name, Bin, Format, Opts) when
    Name =:= date; Name =:= time; Name =:= timestamp; Name =:= timestamptz
->
    minato_codec_datetime:decode(Name, Bin, Format, Opts);
decode_named(Name, Bin, Format, Opts) ->
    minato_codec_scalar:decode(Name, Bin, Format, Opts).

-spec encode_unknown(minato_oid:oid(), term(), format()) -> iodata().
encode_unknown(_Oid, Value, text) when is_binary(Value) ->
    Value;
encode_unknown(Oid, Value, text) when is_list(Value) ->
    to_binary(Oid, Value);
encode_unknown(Oid, Value, _Format) ->
    bad(Oid, unsupported_oid, Value).

-spec decode_unknown(minato_oid:oid(), binary(), format()) -> binary().
decode_unknown(_Oid, Bin, text) when is_binary(Bin) ->
    Bin;
decode_unknown(Oid, Bin, _Format) ->
    bad(Oid, unsupported_oid, Bin).
