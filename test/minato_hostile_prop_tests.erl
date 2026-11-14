-module(minato_hostile_prop_tests).
-moduledoc """
Properties over bytes a server chose, rather than bytes a codec produced.

The round-trip properties in `m:minato_codec_prop_tests` only ever decode what
minato encoded, so they say nothing about a header no encoder writes. These
generate the header fields independently of each other and assert the two
things that have to hold for any of them: the decoder answers or raises its own
tagged error, and what it answers is no larger than the type allows.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% eqWAlizer: the PropEr macros expand to term(), so the functions that use them
%% cannot be given a useful type.
-eqwalizer({nowarn_function, prop_numeric_header_is_total/0}).
-eqwalizer({nowarn_function, prop_numeric_matches_integer_arithmetic/0}).
-eqwalizer({nowarn_function, prop_numeric_encode_is_bounded/0}).
-eqwalizer({nowarn_function, gen_numeric_wire/0}).
-eqwalizer({nowarn_function, gen_valid_numeric/0}).
-eqwalizer({nowarn_function, gen_decimal/0}).

-define(NUMTESTS, 500).
-define(NUMERIC, 1700).
-define(LARGEST_NUMERIC_TEXT, 1 + 131072 + 1 + 16383).
-define(LARGEST_NUMERIC_WIRE, 8 + 2 * ((131072 + 16383 + 3) div 4 + 1)).

numeric_property_test_() ->
    {timeout, 300, [
        {"any numeric header decodes or is refused", fun() ->
            check(prop_numeric_header_is_total())
        end},
        {"a valid numeric decodes to what integer arithmetic says", fun() ->
            check(prop_numeric_matches_integer_arithmetic())
        end},
        {"any decimal encodes within the type or is refused", fun() ->
            check(prop_numeric_encode_is_bounded())
        end}
    ]}.

check(Prop) ->
    ?assert(proper:quickcheck(Prop, [?NUMTESTS, {to_file, user}])).

%%----------------------------------------------------------------------
%% numeric
%%----------------------------------------------------------------------

prop_numeric_header_is_total() ->
    ?FORALL(
        Wire,
        gen_numeric_wire(),
        case decoded(?NUMERIC, Wire) of
            {ok, Text} when is_binary(Text) -> byte_size(Text) =< ?LARGEST_NUMERIC_TEXT;
            {ok, Special} -> lists:member(Special, [nan, infinity, neg_infinity]);
            refused -> true
        end
    ).

prop_numeric_matches_integer_arithmetic() ->
    ?FORALL(
        {Negative, Weight, DScale, Digits},
        gen_valid_numeric(),
        begin
            Wire = <<
                (length(Digits)):16,
                Weight:16/signed,
                (sign(Negative)):16,
                DScale:16,
                <<<<D:16>> || D <- Digits>>/binary
            >>,
            expected(Negative, Weight, DScale, Digits) =:=
                minato_codec:decode(?NUMERIC, Wire, binary)
        end
    ).

prop_numeric_encode_is_bounded() ->
    ?FORALL(
        {Decimal, Format},
        {gen_decimal(), oneof([binary, text])},
        try minato_codec:encode(?NUMERIC, Decimal, Format) of
            Wire when Format =:= binary -> iolist_size(Wire) =< ?LARGEST_NUMERIC_WIRE;
            Text -> iolist_size(Text) =< ?LARGEST_NUMERIC_TEXT
        catch
            error:{minato_codec, #{type := numeric, reason := out_of_range}} -> true
        end
    ).

decoded(Oid, Wire) ->
    try
        {ok, minato_codec:decode(Oid, Wire, binary)}
    catch
        error:{minato_codec, #{reason := _}} -> refused
    end.

sign(true) -> 16#4000;
sign(false) -> 16#0000.

%% The value as one integer scaled by 10^DScale, truncated the way the display
%% scale truncates, and then printed. Nothing here walks base-10000 groups, so
%% it cannot share a mistake with the decoder.
expected(Negative, Weight, DScale, Digits) ->
    Unscaled = unscaled(Digits, 0),
    Shift = Weight - length(Digits) + 1,
    Scaled = shifted(Unscaled * pow10(DScale), Shift),
    Whole = integer_to_binary(Scaled div pow10(DScale)),
    Fraction = fraction(Scaled rem pow10(DScale), DScale),
    iolist_to_binary([minus(Negative), Whole, Fraction]).

unscaled([], Acc) -> Acc;
unscaled([D | Rest], Acc) -> unscaled(Rest, Acc * 10000 + D).

shifted(Value, Shift) when Shift >= 0 -> Value * pow10(4 * Shift);
shifted(Value, Shift) -> Value div pow10(-4 * Shift).

pow10(0) ->
    1;
pow10(N) when N rem 2 =:= 0 ->
    Half = pow10(N div 2),
    Half * Half;
pow10(N) ->
    10 * pow10(N - 1).

fraction(_Value, 0) ->
    [];
fraction(Value, DScale) ->
    Text = integer_to_binary(Value),
    [$., binary:copy(~"0", DScale - byte_size(Text)), Text].

minus(true) -> ~"-";
minus(false) -> ~"".

gen_numeric_wire() ->
    ?LET(
        {Digits, Lie, Weight, Sign, DScale},
        {
            list(oneof([range(0, 9999), range(0, 65535)])),
            frequency([{8, 0}, {1, range(-3, 3)}]),
            oneof([range(-32768, 32767), range(-8, 8)]),
            oneof([16#0000, 16#4000, 16#C000, 16#D000, 16#F000, range(0, 65535)]),
            oneof([range(0, 65535), range(0, 40)])
        },
        <<
            (max(0, length(Digits) + Lie)):16,
            Weight:16/signed,
            Sign:16,
            DScale:16,
            <<<<D:16>> || D <- Digits>>/binary
        >>
    ).

%% A leading digit of zero is something no server writes, and the decoder
%% prints it as it finds it, so it is left to the unit tests.
gen_valid_numeric() ->
    ?LET(
        {First, Rest, Weight, DScale},
        {range(1, 9999), list(range(0, 9999)), range(-40, 40), range(0, 200)},
        {boolean(), Weight, DScale, [First | Rest]}
    ).

gen_decimal() ->
    ?LET(
        {Sign, Whole, Fraction, Exponent},
        {
            oneof([~"", ~"-", ~"+"]),
            list(range($0, $9)),
            list(range($0, $9)),
            oneof([
                range(-40, 40),
                range(-17000, -16000),
                range(130000, 132000),
                range(-999999999999, 999999999999)
            ])
        },
        iolist_to_binary([
            Sign, [$1 | Whole], $., Fraction, $e, integer_to_binary(Exponent)
        ])
    ).
