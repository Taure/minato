-module(minato_codec_scalar).
-moduledoc """
Codecs for the scalar types that are not temporal and not `numeric`:
`bool`, `bytea`, `int2`, `int4`, `int8`, `float4`, `float8`, `text`, `varchar`,
`json`, `jsonb` and `uuid`.

Internal to minato. The supported surface is `m:minato_codec`.

## Wire formats

- `bool` is one byte, 0 or 1, in binary, and `t` or `f` in text.
- `bytea` is the raw bytes in binary. In text it is the `hex` output format,
  a `\x` prefix followed by hex digits; the older `escape` format is accepted
  when decoding but never produced.
- The integers are big-endian two's complement of 2, 4 and 8 bytes.
- `float4` and `float8` are big-endian IEEE 754.
- `text`, `varchar` and `json` are the raw encoded bytes in both formats, which
  for a connection using `client_encoding = UTF8` means UTF-8. minato does not
  validate the encoding; the server rejects what it will not accept.
- `jsonb` in binary is a single version byte, currently 1, followed by the JSON
  text. In text it is the JSON text alone.
- `uuid` is the 16 raw bytes in binary and the 36 character hyphenated form in
  text.

## Erlang representation

Strings, `json` and `bytea` are binaries when decoded and accept any `iodata()`
when encoded.

`jsonb` is **not parsed**. It decodes to the JSON document as a binary, with the
version byte removed, and encodes from JSON `iodata()`. Callers that want terms
run `json:decode/1` and `json:encode/1` themselves, which keeps the choice of
JSON representation with the caller and keeps the codec free of a JSON parser.

`float4` and `float8` decode to a float, or to `nan`, `infinity` or
`neg_infinity`, because the BEAM has no float value for those three. The same
three atoms are accepted when encoding. `nan` encodes to the quiet NaN, which
is what PostgreSQL itself emits and what IEEE 754 recommends; a signalling NaN
can trap on hardware that honours the distinction.

A `float4` decoded from text is narrowed to `float4` precision, so that the
same value read in either wire format gives the same term. PostgreSQL prints a
`float4` with only the digits a `float4` needs, and reading those digits as a
double gives a number no `float4` holds.

In the text format PostgreSQL prints a float in its shortest round-tripping
form, which for many values carries no decimal point at all: `0`, `1e+30`,
`1e-30`. `binary_to_float/1` rejects every one of those, so the text decoder
supplies the missing point before parsing.

`uuid` decoding is governed by the `uuid_format` option: `string`, the default,
gives the 36 character hyphenated lowercase binary, and `binary` gives the 16
raw bytes. Encoding always accepts all three input forms: 16 raw bytes, 32 hex
characters, or the 36 character hyphenated form, in either case.
""".

-export([encode/4, decode/4]).

-define(INT2_MIN, -32768).
-define(INT2_MAX, 32767).
-define(INT4_MIN, -2147483648).
-define(INT4_MAX, 2147483647).
-define(INT8_MIN, -9223372036854775808).
-define(INT8_MAX, 9223372036854775807).

-doc "Encode a scalar value to `Format` wire bytes.".
-spec encode(minato_oid:name(), term(), minato_codec:format(), minato_codec:opts()) -> iodata().
encode(bool, true, binary, _Opts) ->
    <<1>>;
encode(bool, false, binary, _Opts) ->
    <<0>>;
encode(bool, true, text, _Opts) ->
    ~"t";
encode(bool, false, text, _Opts) ->
    ~"f";
encode(bool, Value, _Format, _Opts) ->
    minato_codec:bad(bool, not_a_boolean, Value);
encode(bytea, Value, binary, _Opts) ->
    bytes(bytea, Value);
encode(bytea, Value, text, _Opts) ->
    [~"\\x", binary:encode_hex(bytes(bytea, Value), lowercase)];
encode(Type, Value, Format, _Opts) when Type =:= int2; Type =:= int4; Type =:= int8 ->
    integer(Type, Value, Format);
encode(float4, Value, binary, _Opts) ->
    float32(Value);
encode(float8, Value, binary, _Opts) ->
    float64(Value);
encode(Type, Value, text, _Opts) when Type =:= float4; Type =:= float8 ->
    float_text(Type, Value);
encode(Type, Value, _Format, _Opts) when Type =:= text; Type =:= varchar; Type =:= json ->
    bytes(Type, Value);
encode(jsonb, Value, binary, _Opts) ->
    [<<1>>, bytes(jsonb, Value)];
encode(jsonb, Value, text, _Opts) ->
    bytes(jsonb, Value);
encode(uuid, Value, binary, _Opts) ->
    uuid_raw(Value);
encode(uuid, Value, text, _Opts) ->
    uuid_string(uuid_raw(Value));
encode(Type, Value, Format, _Opts) ->
    minato_codec:bad(Type, {unencodable, Format}, Value).

-doc "Decode `Format` wire bytes to a scalar value.".
-spec decode(minato_oid:name(), binary(), minato_codec:format(), minato_codec:opts()) ->
    minato_codec:value().
decode(bool, <<1>>, binary, _Opts) ->
    true;
decode(bool, <<0>>, binary, _Opts) ->
    false;
decode(bool, Bin, text, _Opts) when Bin =:= ~"t"; Bin =:= ~"true" ->
    true;
decode(bool, Bin, text, _Opts) when Bin =:= ~"f"; Bin =:= ~"false" ->
    false;
decode(bytea, Bin, binary, _Opts) ->
    Bin;
decode(bytea, Bin, text, _Opts) ->
    bytea_text(Bin);
decode(int2, <<Value:16/signed>>, binary, _Opts) ->
    Value;
decode(int4, <<Value:32/signed>>, binary, _Opts) ->
    Value;
decode(int8, <<Value:64/signed>>, binary, _Opts) ->
    Value;
decode(Type, Bin, text, _Opts) when Type =:= int2; Type =:= int4; Type =:= int8 ->
    to_integer(Type, Bin);
decode(float4, <<Sign:1, 255:8, Mantissa:23>>, binary, _Opts) ->
    non_finite(Sign, Mantissa);
decode(float4, <<Value:32/float>>, binary, _Opts) ->
    Value;
decode(float8, <<Sign:1, 2047:11, Mantissa:52>>, binary, _Opts) ->
    non_finite(Sign, Mantissa);
decode(float8, <<Value:64/float>>, binary, _Opts) ->
    Value;
decode(Type, Bin, text, _Opts) when Type =:= float4; Type =:= float8 ->
    float_of_text(Type, Bin);
decode(Type, Bin, _Format, _Opts) when Type =:= text; Type =:= varchar; Type =:= json ->
    Bin;
decode(jsonb, <<1, Json/binary>>, binary, _Opts) ->
    Json;
decode(jsonb, Bin, text, _Opts) ->
    Bin;
decode(uuid, <<Raw:16/binary>>, binary, Opts) ->
    uuid_out(Raw, Opts);
decode(uuid, Bin, text, Opts) ->
    uuid_out(uuid_raw(Bin), Opts);
decode(Type, Bin, Format, _Opts) ->
    minato_codec:bad(Type, {malformed, Format}, Bin).

%%----------------------------------------------------------------------
%% Integers
%%----------------------------------------------------------------------

-spec integer(minato_oid:name(), term(), minato_codec:format()) -> iodata().
integer(Type, Value, Format) when is_integer(Value) ->
    {Min, Max} = integer_range(Type),
    case Value >= Min andalso Value =< Max of
        true -> integer_wire(Type, Value, Format);
        false -> minato_codec:bad(Type, out_of_range, Value)
    end;
integer(Type, Value, _Format) ->
    minato_codec:bad(Type, not_an_integer, Value).

-spec integer_range(minato_oid:name()) -> {integer(), integer()}.
integer_range(int2) -> {?INT2_MIN, ?INT2_MAX};
integer_range(int4) -> {?INT4_MIN, ?INT4_MAX};
integer_range(_) -> {?INT8_MIN, ?INT8_MAX}.

-spec integer_wire(minato_oid:name(), integer(), minato_codec:format()) -> iodata().
integer_wire(_Type, Value, text) -> integer_to_binary(Value);
integer_wire(int2, Value, binary) -> <<Value:16/signed>>;
integer_wire(int4, Value, binary) -> <<Value:32/signed>>;
integer_wire(_Type, Value, binary) -> <<Value:64/signed>>.

-spec to_integer(minato_oid:name(), binary()) -> integer().
to_integer(Type, Bin) ->
    try
        binary_to_integer(Bin)
    catch
        error:badarg -> minato_codec:bad(Type, malformed_text, Bin)
    end.

%%----------------------------------------------------------------------
%% Floats
%%----------------------------------------------------------------------

-spec float32(term()) -> binary().
float32(nan) ->
    <<0:1, 255:8, 1:1, 0:22>>;
float32(infinity) ->
    <<0:1, 255:8, 0:23>>;
float32(neg_infinity) ->
    <<1:1, 255:8, 0:23>>;
float32(Value) when is_number(Value) ->
    narrow(as_float(float4, Value));
float32(Value) ->
    minato_codec:bad(float4, not_a_float, Value).

-spec narrow(float()) -> binary().
narrow(Value) ->
    case <<Value:32/float>> of
        <<_:1, 255:8, _:23>> -> minato_codec:bad(float4, out_of_range, Value);
        <<_:1, 0:8, 0:23>> when Value /= 0.0 -> minato_codec:bad(float4, out_of_range, Value);
        Wire -> Wire
    end.

-spec as_float(minato_oid:name(), number()) -> float().
as_float(_Type, Value) when is_float(Value) ->
    Value;
as_float(Type, Value) ->
    try
        float(Value)
    catch
        error:badarg -> minato_codec:bad(Type, out_of_range, Value)
    end.

-spec float64(term()) -> binary().
float64(nan) ->
    <<0:1, 2047:11, 1:1, 0:51>>;
float64(infinity) ->
    <<0:1, 2047:11, 0:52>>;
float64(neg_infinity) ->
    <<1:1, 2047:11, 0:52>>;
float64(Value) when is_number(Value) ->
    <<(as_float(float8, Value)):64/float>>;
float64(Value) ->
    minato_codec:bad(float8, not_a_float, Value).

-spec non_finite(non_neg_integer(), non_neg_integer()) -> nan | infinity | neg_infinity.
non_finite(_Sign, Mantissa) when Mantissa =/= 0 -> nan;
non_finite(0, _Mantissa) -> infinity;
non_finite(_Sign, _Mantissa) -> neg_infinity.

-spec float_text(minato_oid:name(), term()) -> binary().
float_text(_Type, nan) ->
    ~"NaN";
float_text(_Type, infinity) ->
    ~"Infinity";
float_text(_Type, neg_infinity) ->
    ~"-Infinity";
float_text(_Type, Value) when is_float(Value) ->
    float_to_binary(Value, [short]);
float_text(_Type, Value) when is_integer(Value) ->
    integer_to_binary(Value);
float_text(Type, Value) ->
    minato_codec:bad(Type, not_a_float, Value).

-spec float_of_text(minato_oid:name(), binary()) -> float() | nan | infinity | neg_infinity.
float_of_text(_Type, ~"NaN") ->
    nan;
float_of_text(_Type, ~"Infinity") ->
    infinity;
float_of_text(_Type, ~"-Infinity") ->
    neg_infinity;
float_of_text(_Type, ~"inf") ->
    infinity;
float_of_text(_Type, ~"-inf") ->
    neg_infinity;
float_of_text(float4, Bin) ->
    case narrow(parse_float(float4, Bin)) of
        <<Narrowed:32/float>> -> Narrowed
    end;
float_of_text(Type, Bin) ->
    parse_float(Type, Bin).

-spec parse_float(minato_oid:name(), binary()) -> float().
parse_float(Type, Bin) ->
    try
        binary_to_float(with_point(Bin))
    catch
        error:badarg -> minato_codec:bad(Type, malformed_text, Bin)
    end.

-spec with_point(binary()) -> binary().
with_point(Bin) ->
    case binary:split(Bin, [~"e", ~"E"]) of
        [Mantissa] -> point(Mantissa);
        [Mantissa, Exponent] -> <<(point(Mantissa))/binary, $e, Exponent/binary>>;
        _ -> Bin
    end.

-spec point(binary()) -> binary().
point(Bin) ->
    case binary:match(Bin, ~".") of
        nomatch -> <<Bin/binary, ".0">>;
        _ -> Bin
    end.

%%----------------------------------------------------------------------
%% Bytes and bytea text
%%----------------------------------------------------------------------

-spec bytes(minato_oid:name(), term()) -> binary().
bytes(_Type, Value) when is_binary(Value) ->
    Value;
bytes(Type, Value) when is_list(Value) ->
    minato_codec:to_binary(Type, Value);
bytes(Type, Value) ->
    minato_codec:bad(Type, not_iodata, Value).

-spec bytea_text(binary()) -> binary().
bytea_text(<<$\\, $x, Hex/binary>>) ->
    try
        binary:decode_hex(Hex)
    catch
        error:badarg -> minato_codec:bad(bytea, malformed_hex, Hex)
    end;
bytea_text(Bin) ->
    unescape(Bin, ~"").

-spec unescape(binary(), binary()) -> binary().
unescape(~"", Acc) ->
    Acc;
unescape(<<$\\, $\\, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, $\\>>);
unescape(<<$\\, A, B, C, Rest/binary>>, Acc) when
    A >= $0, A =< $3, B >= $0, B =< $7, C >= $0, C =< $7
->
    Byte = (A - $0) * 64 + (B - $0) * 8 + (C - $0),
    unescape(Rest, <<Acc/binary, Byte>>);
unescape(<<Byte, Rest/binary>>, Acc) ->
    unescape(Rest, <<Acc/binary, Byte>>).

%%----------------------------------------------------------------------
%% UUID
%%----------------------------------------------------------------------

-spec uuid_raw(term()) -> binary().
uuid_raw(<<A:8/binary, $-, B:4/binary, $-, C:4/binary, $-, D:4/binary, $-, E:12/binary>>) ->
    decode_hex(<<A/binary, B/binary, C/binary, D/binary, E/binary>>);
uuid_raw(Value) when is_binary(Value), byte_size(Value) =:= 32 ->
    decode_hex(Value);
uuid_raw(Value) when is_binary(Value), byte_size(Value) =:= 16 ->
    Value;
uuid_raw(Value) ->
    minato_codec:bad(uuid, not_a_uuid, Value).

-spec decode_hex(binary()) -> binary().
decode_hex(Hex) ->
    try
        binary:decode_hex(Hex)
    catch
        error:badarg -> minato_codec:bad(uuid, malformed_hex, Hex)
    end.

-spec uuid_out(binary(), minato_codec:opts()) -> binary().
uuid_out(Raw, #{uuid_format := binary}) -> Raw;
uuid_out(Raw, _Opts) -> uuid_string(Raw).

-spec uuid_string(binary()) -> binary().
uuid_string(<<A:4/binary, B:2/binary, C:2/binary, D:2/binary, E:6/binary>>) ->
    <<
        (binary:encode_hex(A, lowercase))/binary,
        $-,
        (binary:encode_hex(B, lowercase))/binary,
        $-,
        (binary:encode_hex(C, lowercase))/binary,
        $-,
        (binary:encode_hex(D, lowercase))/binary,
        $-,
        (binary:encode_hex(E, lowercase))/binary
    >>.
