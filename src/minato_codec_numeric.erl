-module(minato_codec_numeric).
-moduledoc """
Codec for `numeric`.

Internal to minato. The supported surface is `m:minato_codec`.

## Wire format

The binary representation is a header of four `int16` fields followed by
`ndigits` further `int16` values:

```text
int16  ndigits   how many base-10000 digits follow
int16  weight    base-10000 exponent of the first digit
int16  sign      0x0000 positive, 0x4000 negative,
                 0xC000 NaN, 0xD000 Infinity, 0xF000 -Infinity
int16  dscale    how many decimal digits are displayed after the point
int16  digits[]  each 0..9999, most significant first
```

The value is `digits[0] * 10000^weight + digits[1] * 10000^(weight-1) + ...`,
signed, and displayed with exactly `dscale` digits after the decimal point.
Zero is `ndigits = 0` with a positive sign. The special values carry no digits.

## Erlang representation

`numeric` decodes to a **binary decimal string**, never to a float: the point of
the type is that it is exact, and float would throw that away. `dscale` is
preserved as trailing zeros, so `123.4500` decodes to `~"123.4500"` and not to
`~"123.45"`.

The special values decode to the atoms `nan`, `infinity` and `neg_infinity`.

Encoding accepts a binary decimal string (with an optional exponent, as
PostgreSQL itself accepts), an integer, a float, or one of the three atoms.
A float is converted through its shortest round-tripping decimal form, so it
encodes the value the float actually holds. Floats are accepted for
convenience but never produced, because decoding one would defeat the type.

Negative zero normalises to positive zero, as it does on the server.
""".

-export([encode/4, decode/4]).

-define(SIGN_POS, 16#0000).
-define(SIGN_NEG, 16#4000).
-define(SIGN_NAN, 16#C000).
-define(SIGN_PINF, 16#D000).
-define(SIGN_NINF, 16#F000).

-doc "Encode a numeric value to `Format` wire bytes.".
-spec encode(numeric, term(), minato_codec:format(), minato_codec:opts()) -> iodata().
encode(numeric, nan, binary, _Opts) ->
    header(0, 0, ?SIGN_NAN, 0);
encode(numeric, infinity, binary, _Opts) ->
    header(0, 0, ?SIGN_PINF, 0);
encode(numeric, neg_infinity, binary, _Opts) ->
    header(0, 0, ?SIGN_NINF, 0);
encode(numeric, Value, binary, _Opts) ->
    {Negative, Digits, Exponent} = parse(Value),
    to_binary_wire(Negative, Digits, Exponent);
encode(numeric, nan, text, _Opts) ->
    ~"NaN";
encode(numeric, infinity, text, _Opts) ->
    ~"Infinity";
encode(numeric, neg_infinity, text, _Opts) ->
    ~"-Infinity";
encode(numeric, Value, text, _Opts) ->
    {Negative, Digits, Exponent} = parse(Value),
    to_decimal_text(Negative, Digits, Exponent).

-doc "Decode `Format` wire bytes to a numeric value.".
-spec decode(numeric, binary(), minato_codec:format(), minato_codec:opts()) ->
    binary() | nan | infinity | neg_infinity.
decode(numeric, <<_:16, _:16/signed, ?SIGN_NAN:16, _:16, _/binary>>, binary, _Opts) ->
    nan;
decode(numeric, <<_:16, _:16/signed, ?SIGN_PINF:16, _:16, _/binary>>, binary, _Opts) ->
    infinity;
decode(numeric, <<_:16, _:16/signed, ?SIGN_NINF:16, _:16, _/binary>>, binary, _Opts) ->
    neg_infinity;
decode(
    numeric, <<NDigits:16, Weight:16/signed, Sign:16, DScale:16, Rest/binary>> = Wire, binary, _Opts
) when
    Sign =:= ?SIGN_POS; Sign =:= ?SIGN_NEG
->
    case byte_size(Rest) =:= NDigits * 2 of
        true ->
            Digits = [D || <<D:16>> <= Rest],
            iolist_to_binary([
                sign_text(Sign =:= ?SIGN_NEG andalso NDigits > 0),
                integer_text(Digits, Weight),
                fraction_text(Digits, Weight, DScale)
            ]);
        false ->
            minato_codec:bad(numeric, digit_count_mismatch, Wire)
    end;
decode(numeric, Bin, text, _Opts) ->
    decode_text(Bin);
decode(numeric, Bin, Format, _Opts) ->
    minato_codec:bad(numeric, {malformed, Format}, Bin).

-spec decode_text(binary()) -> binary() | nan | infinity | neg_infinity.
decode_text(~"NaN") -> nan;
decode_text(~"Infinity") -> infinity;
decode_text(~"-Infinity") -> neg_infinity;
decode_text(~"inf") -> infinity;
decode_text(~"-inf") -> neg_infinity;
decode_text(Bin) -> valid_decimal(Bin).

-spec valid_decimal(binary()) -> binary().
valid_decimal(Bin) ->
    _ = parse(Bin),
    Bin.

-spec header(non_neg_integer(), integer(), non_neg_integer(), non_neg_integer()) -> binary().
header(NDigits, Weight, Sign, DScale) ->
    <<NDigits:16, Weight:16/signed, Sign:16, DScale:16>>.

-spec sign_text(boolean()) -> binary().
sign_text(true) -> ~"-";
sign_text(false) -> ~"".

-spec to_decimal_text(boolean(), binary(), integer()) -> iodata().
to_decimal_text(Negative, AllDigits, Exponent) ->
    {IntegerPart, FractionPart} = split_at_point(AllDigits, Exponent),
    [
        sign_text(Negative andalso not all_zero(AllDigits)),
        strip_zeros(IntegerPart),
        point_text(FractionPart)
    ].

-spec point_text(binary()) -> iodata().
point_text(~"") -> [];
point_text(FractionPart) -> [$., FractionPart].

-spec strip_zeros(binary()) -> binary().
strip_zeros(<<$0, Rest/binary>>) when Rest =/= ~"" -> strip_zeros(Rest);
strip_zeros(~"") -> ~"0";
strip_zeros(Bin) -> Bin.

-spec all_zero(binary()) -> boolean().
all_zero(Bin) ->
    binary:copy(~"0", byte_size(Bin)) =:= Bin.

%%----------------------------------------------------------------------
%% Decimal string to base-10000 digits
%%----------------------------------------------------------------------

-spec to_binary_wire(boolean(), binary(), integer()) -> iodata().
to_binary_wire(Negative, AllDigits, Exponent) ->
    {IntegerPart, FractionPart} = split_at_point(AllDigits, Exponent),
    DScale = display_scale(Exponent),
    IntegerGroups = group(pad_left(IntegerPart)),
    Groups = IntegerGroups ++ group(pad_right(FractionPart)),
    {Trimmed, Weight} = drop_leading_zeros(Groups, length(IntegerGroups) - 1),
    Digits = drop_trailing_zeros(Trimmed),
    case Digits of
        [] ->
            header(0, 0, ?SIGN_POS, DScale);
        _ ->
            [
                header(length(Digits), Weight, wire_sign(Negative), DScale),
                <<<<D:16>> || D <- Digits>>
            ]
    end.

-spec display_scale(integer()) -> non_neg_integer().
display_scale(Exponent) when Exponent < 0 -> -Exponent;
display_scale(_Exponent) -> 0.

-spec wire_sign(boolean()) -> non_neg_integer().
wire_sign(true) -> ?SIGN_NEG;
wire_sign(false) -> ?SIGN_POS.

-spec split_at_point(binary(), integer()) -> {binary(), binary()}.
split_at_point(AllDigits, Exponent) when Exponent >= 0 ->
    {<<AllDigits/binary, (zeros(Exponent))/binary>>, ~""};
split_at_point(AllDigits, Exponent) ->
    Shift = -Exponent,
    Len = byte_size(AllDigits),
    case Shift < Len of
        true ->
            {binary_part(AllDigits, 0, Len - Shift), binary_part(AllDigits, Len - Shift, Shift)};
        false ->
            {~"", <<(zeros(Shift - Len))/binary, AllDigits/binary>>}
    end.

-spec pad_left(binary()) -> binary().
pad_left(Bin) ->
    <<(zeros(fill(byte_size(Bin))))/binary, Bin/binary>>.

-spec pad_right(binary()) -> binary().
pad_right(Bin) ->
    <<Bin/binary, (zeros(fill(byte_size(Bin))))/binary>>.

-spec fill(non_neg_integer()) -> non_neg_integer().
fill(Size) -> (4 - Size rem 4) rem 4.

-spec zeros(non_neg_integer()) -> binary().
zeros(N) -> binary:copy(~"0", N).

-spec group(binary()) -> [non_neg_integer()].
group(~"") ->
    [];
group(<<A, B, C, D, Rest/binary>>) ->
    [(A - $0) * 1000 + (B - $0) * 100 + (C - $0) * 10 + (D - $0) | group(Rest)].

-spec drop_leading_zeros([non_neg_integer()], integer()) -> {[non_neg_integer()], integer()}.
drop_leading_zeros([0 | Rest], Weight) -> drop_leading_zeros(Rest, Weight - 1);
drop_leading_zeros(Groups, Weight) -> {Groups, Weight}.

-spec drop_trailing_zeros([non_neg_integer()]) -> [non_neg_integer()].
drop_trailing_zeros([]) ->
    [];
drop_trailing_zeros([0 | Rest]) ->
    case drop_trailing_zeros(Rest) of
        [] -> [];
        Tail -> [0 | Tail]
    end;
drop_trailing_zeros([Digit | Rest]) ->
    [Digit | drop_trailing_zeros(Rest)].

%%----------------------------------------------------------------------
%% Base-10000 digits to decimal string
%%----------------------------------------------------------------------

-spec integer_text([non_neg_integer()], integer()) -> iodata().
integer_text(_Digits, Weight) when Weight < 0 ->
    ~"0";
integer_text(Digits, Weight) ->
    [leading_group(Digits) | [four(digit_at(Digits, I)) || I <- lists:seq(1, Weight)]].

-spec leading_group([non_neg_integer()]) -> binary().
leading_group(Digits) ->
    integer_to_binary(digit_at(Digits, 0)).

-spec fraction_text([non_neg_integer()], integer(), non_neg_integer()) -> iodata().
fraction_text(_Digits, _Weight, 0) ->
    [];
fraction_text(Digits, Weight, DScale) ->
    Groups = [four(digit_at(Digits, Weight + K)) || K <- lists:seq(1, (DScale + 3) div 4)],
    [$., binary_part(iolist_to_binary(Groups), 0, DScale)].

-spec digit_at([non_neg_integer()], integer()) -> non_neg_integer().
digit_at([Digit | _Rest], 0) -> Digit;
digit_at([_Digit | Rest], Index) when Index > 0 -> digit_at(Rest, Index - 1);
digit_at(_Digits, _Index) -> 0.

-spec four(non_neg_integer()) -> binary().
four(D) ->
    Bin = integer_to_binary(D),
    <<(zeros(4 - byte_size(Bin)))/binary, Bin/binary>>.

%%----------------------------------------------------------------------
%% Parsing the accepted Erlang forms into sign, digits and exponent
%%----------------------------------------------------------------------

-spec parse(term()) -> {boolean(), binary(), integer()}.
parse(Value) when is_integer(Value) ->
    parse(integer_to_binary(Value));
parse(Value) when is_float(Value) ->
    parse(float_to_binary(Value, [short]));
parse(Value) when is_binary(Value) ->
    case parse_decimal(Value) of
        invalid -> minato_codec:bad(numeric, malformed_decimal, Value);
        Parsed -> Parsed
    end;
parse(Value) ->
    minato_codec:bad(numeric, not_a_numeric, Value).

-spec parse_decimal(binary()) -> {boolean(), binary(), integer()} | invalid.
parse_decimal(Bin) ->
    {Negative, Body} = take_sign(Bin),
    {IntegerPart, AfterInteger} = take_digits(Body),
    {FractionPart, AfterFraction} = take_fraction(AfterInteger),
    case {IntegerPart, FractionPart, take_exponent(AfterFraction)} of
        {~"", ~"", _} ->
            invalid;
        {_, _, invalid} ->
            invalid;
        {_, _, Exponent} ->
            Digits = <<IntegerPart/binary, FractionPart/binary>>,
            {Negative, Digits, Exponent - byte_size(FractionPart)}
    end.

-spec take_sign(binary()) -> {boolean(), binary()}.
take_sign(<<$-, Rest/binary>>) -> {true, Rest};
take_sign(<<$+, Rest/binary>>) -> {false, Rest};
take_sign(Bin) -> {false, Bin}.

-spec take_digits(binary()) -> {binary(), binary()}.
take_digits(Bin) ->
    take_digits(Bin, 0).

-spec take_digits(binary(), non_neg_integer()) -> {binary(), binary()}.
take_digits(Bin, Taken) ->
    case Bin of
        <<_:Taken/binary, C, _/binary>> when C >= $0, C =< $9 ->
            take_digits(Bin, Taken + 1);
        _ ->
            {binary_part(Bin, 0, Taken), binary_part(Bin, Taken, byte_size(Bin) - Taken)}
    end.

-spec take_fraction(binary()) -> {binary(), binary()}.
take_fraction(<<$., Rest/binary>>) -> take_digits(Rest);
take_fraction(Bin) -> {~"", Bin}.

-spec take_exponent(binary()) -> integer() | invalid.
take_exponent(~"") ->
    0;
take_exponent(<<E, Rest/binary>>) when E =:= $e; E =:= $E ->
    {Negative, Body} = take_sign(Rest),
    case take_digits(Body) of
        {~"", _} -> invalid;
        {_, Trailing} when Trailing =/= ~"" -> invalid;
        {Digits, _} -> exponent_value(Negative, binary_to_integer(Digits))
    end;
take_exponent(_) ->
    invalid.

-spec exponent_value(boolean(), integer()) -> integer().
exponent_value(true, Value) -> -Value;
exponent_value(false, Value) -> Value.
