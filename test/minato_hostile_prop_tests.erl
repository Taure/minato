-module(minato_hostile_prop_tests).
-moduledoc """
Properties over bytes a server chose, rather than bytes a codec produced.

The round-trip properties in `m:minato_codec_prop_tests` only ever decode what
minato encoded, so they say nothing about a header no encoder writes. These
generate the header fields independently of each other and assert the two
things that have to hold for any of them: the decoder answers or raises its own
tagged error, and what it answers is no larger than the type allows. The same
is asked of the framer, for a stream of messages no server would write.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(NUMTESTS, 500).
-define(NUMERIC, 1700).
-define(INT4_ARRAY, 1007).
-define(TEXT_ARRAY, 1009).
-define(MAX_DIMENSIONS, 6).
-define(FRAME_BOUND, 65536).
-define(LARGEST_NUMERIC_TEXT, (1 + 131072 + 1 + 16383)).
-define(LARGEST_NUMERIC_WIRE, (8 + 2 * ((131072 + 16383 + 3) div 4 + 1))).

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

array_property_test_() ->
    {timeout, 300, [
        {"any array header decodes or is refused", fun() ->
            check(prop_array_header_is_total())
        end},
        {"any array text decodes or is refused", fun() ->
            check(prop_array_text_is_total())
        end}
    ]}.

framing_property_test_() ->
    {timeout, 300, [
        {"any bytes frame into messages or are refused", fun() ->
            check(prop_frame_is_total())
        end},
        {"a length over the bound is refused before its payload arrives", fun() ->
            check(prop_frame_refuses_a_length_over_its_bound())
        end},
        {"any row decodes against its columns or is refused", fun() ->
            check(prop_rows_are_total())
        end}
    ]}.

check(Prop) ->
    ?assert(proper:quickcheck(Prop, [?NUMTESTS, {to_file, user}])).

%%----------------------------------------------------------------------
%% numeric
%%----------------------------------------------------------------------

prop_numeric_header_is_total() ->
    forall(gen_numeric_wire(), fun(Wire) ->
        case decoded(?NUMERIC, Wire) of
            {ok, Text} when is_binary(Text) -> byte_size(Text) =< ?LARGEST_NUMERIC_TEXT;
            {ok, Special} -> lists:member(Special, [nan, infinity, neg_infinity]);
            refused -> true
        end
    end).

prop_numeric_matches_integer_arithmetic() ->
    forall(gen_valid_numeric(), fun({Negative, Weight, DScale, Digits}) ->
        Wire = <<
            (length(Digits)):16,
            Weight:16/signed,
            (sign(Negative)):16,
            DScale:16,
            <<<<D:16>> || D <- Digits>>/binary
        >>,
        expected(Negative, Weight, DScale, Digits) =:=
            minato_codec:decode(?NUMERIC, Wire, binary)
    end).

prop_numeric_encode_is_bounded() ->
    forall({gen_decimal(), oneof([binary, text])}, fun({Decimal, Format}) ->
        try minato_codec:encode(?NUMERIC, Decimal, Format) of
            null -> false;
            Wire when Format =:= binary -> iolist_size(Wire) =< ?LARGEST_NUMERIC_WIRE;
            Text -> iolist_size(Text) =< ?LARGEST_NUMERIC_TEXT
        catch
            error:{minato_codec, #{type := numeric, reason := out_of_range}} -> true
        end
    end).

%%----------------------------------------------------------------------
%% framing
%%----------------------------------------------------------------------

prop_frame_is_total() ->
    forall(gen_stream(), fun(Stream) ->
        try minato_protocol:frame(Stream, #{max_message_length => ?FRAME_BOUND}) of
            {Messages, Rest} ->
                is_list(Messages) andalso is_binary(Rest) andalso
                    byte_size(Rest) =< byte_size(Stream)
        catch
            error:{minato_protocol, #{reason := _}} -> true
        end
    end).

prop_frame_refuses_a_length_over_its_bound() ->
    forall({byte(), range(?FRAME_BOUND + 1, 2147483647), binary()}, fun({Type, Length, Arrived}) ->
        try
            minato_protocol:frame(<<Type, Length:32, Arrived/binary>>, #{
                max_message_length => ?FRAME_BOUND
            })
        of
            _Waited_for_it -> false
        catch
            error:{minato_protocol, #{reason := message_too_long}} -> true
        end
    end).

prop_rows_are_total() ->
    Decoder = minato_protocol:decoder(
        [column(~"id", 23), column(~"amount", ?NUMERIC), column(~"tags", ?INT4_ARRAY)], #{}
    ),
    forall(gen_row(), fun(Row) ->
        try minato_protocol:frame(Row, #{decoder => Decoder}) of
            {Messages, Rest} -> is_list(Messages) andalso is_binary(Rest)
        catch
            error:{minato_protocol, #{reason := _}} -> true;
            error:{minato_codec, #{reason := _}} -> true
        end
    end).

column(Name, Oid) ->
    #{
        name => Name,
        table_oid => 0,
        column => 0,
        type_oid => Oid,
        type_size => -1,
        type_modifier => -1,
        format => binary
    }.

gen_stream() ->
    from(list(gen_message()), fun(Messages) -> iolist_to_binary(Messages) end).

%% A type byte the protocol has and one it may not, a length that is right,
%% nearly right or anything at all, and a payload that is noise.
gen_message() ->
    from(
        {
            oneof([elements("RKSZTDCIEN123ntsAGHWdcv"), byte()]),
            oneof([binary(), ~"", <<0>>, <<0, 0, 0, 0>>]),
            frequency([{6, 0}, {2, range(-6, 6)}, {1, range(-2147483648, 2147483647)}])
        },
        fun({Type, Payload, Lie}) ->
            <<Type, (byte_size(Payload) + 4 + Lie):32/signed, Payload/binary>>
        end
    ).

gen_row() ->
    from(
        {
            oneof([3, range(-1, 5), range(0, 65535)]),
            list(oneof([null, binary(), range(-2147483648, 2147483647)]))
        },
        fun({Count, Values}) ->
            Payload = <<Count:16, <<<<(element(Value))/binary>> || Value <- Values>>/binary>>,
            <<$D, (byte_size(Payload) + 4):32, Payload/binary>>
        end
    ).

%%----------------------------------------------------------------------
%% arrays
%%----------------------------------------------------------------------

prop_array_header_is_total() ->
    forall(gen_array_wire(), fun(Wire) ->
        case decoded(?INT4_ARRAY, Wire) of
            {ok, List} -> is_list(List) andalso depth(List) =< ?MAX_DIMENSIONS;
            refused -> true
        end
    end).

prop_array_text_is_total() ->
    forall(gen_array_text(), fun(Text) ->
        try minato_codec:decode(?TEXT_ARRAY, Text, text) of
            List -> is_list(List) andalso depth(List) =< ?MAX_DIMENSIONS
        catch
            error:{minato_codec, #{reason := _}} -> true
        end
    end).

depth([First | _Rest]) when is_list(First) -> 1 + depth(First);
depth(_Flat) -> 1.

gen_array_wire() ->
    from(
        {
            oneof([range(-2, 9), range(-2147483648, 2147483647)]),
            list(oneof([range(-1, 3), range(-2147483648, 2147483647)])),
            list(oneof([null, range(-2147483648, 2147483647), binary()])),
            oneof([~"", binary()])
        },
        fun({NDim, Sizes, Elements, Trailing}) ->
            <<
                NDim:32/signed,
                0:32,
                23:32,
                <<<<Size:32/signed, 1:32/signed>> || Size <- Sizes>>/binary,
                <<<<(element(Element))/binary>> || Element <- Elements>>/binary,
                Trailing/binary
            >>
        end
    ).

element(null) -> <<-1:32/signed>>;
element(Value) when is_integer(Value) -> <<4:32/signed, Value:32/signed>>;
element(Bytes) -> <<(byte_size(Bytes)):32/signed, Bytes/binary>>.

gen_array_text() ->
    from(
        list(
            frequency([
                {6, ${}, {4, $}}, {3, $,}, {1, $"}, {1, $\\}, {2, $a}, {1, $N}, {1, $\s}
            ])
        ),
        fun(Characters) -> list_to_binary(Characters) end
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
    from(
        {
            list(oneof([range(0, 9999), range(0, 65535)])),
            frequency([{8, 0}, {1, range(-3, 3)}]),
            oneof([range(-32768, 32767), range(-8, 8)]),
            oneof([16#0000, 16#4000, 16#C000, 16#D000, 16#F000, range(0, 65535)]),
            oneof([range(0, 65535), range(0, 40)])
        },
        fun({Digits, Lie, Weight, Sign, DScale}) ->
            <<
                (claimed(length(Digits), Lie)):16,
                Weight:16/signed,
                Sign:16,
                DScale:16,
                <<<<D:16>> || D <- Digits>>/binary
            >>
        end
    ).

%% A leading digit of zero is something no server writes, and the decoder
%% prints it as it finds it, so it is left to the unit tests.
gen_valid_numeric() ->
    from({range(1, 9999), list(range(0, 9999)), range(-40, 40), range(0, 200)}, fun(
        {First, Rest, Weight, DScale}
    ) ->
        {boolean(), Weight, DScale, [First | Rest]}
    end).

gen_decimal() ->
    from(
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
        fun({Sign, Whole, Fraction, Exponent}) ->
            iolist_to_binary([
                Sign, [$1 | Whole], $., Fraction, $e, integer_to_binary(Exponent)
            ])
        end
    ).

-spec claimed(non_neg_integer(), integer()) -> non_neg_integer().
claimed(Held, Lie) when Held + Lie > 0 -> Held + Lie;
claimed(_Held, _Lie) -> 0.

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
