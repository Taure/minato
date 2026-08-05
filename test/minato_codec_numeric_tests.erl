-module(minato_codec_numeric_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NUMERIC, 1700).

enc(Value, Format) ->
    wire(minato_codec:encode(?NUMERIC, Value, Format)).

wire(null) -> null;
wire(IoData) -> iolist_to_binary(IoData).

roundtrip(Value, Format) ->
    minato_codec:decode(?NUMERIC, enc(Value, Format), Format).

%%----------------------------------------------------------------------
%% The documented header layout
%%----------------------------------------------------------------------

wire_layout_test_() ->
    Cases = [
        {~"0", <<0:16, 0:16/signed, 16#0000:16, 0:16>>},
        {~"1", <<1:16, 0:16/signed, 16#0000:16, 0:16, 1:16>>},
        {~"-1", <<1:16, 0:16/signed, 16#4000:16, 0:16, 1:16>>},
        {~"10000", <<1:16, 1:16/signed, 16#0000:16, 0:16, 1:16>>},
        {~"0.5", <<1:16, -1:16/signed, 16#0000:16, 1:16, 5000:16>>},
        {~"1.5", <<2:16, 0:16/signed, 16#0000:16, 1:16, 1:16, 5000:16>>},
        {~"12345.678", <<3:16, 1:16/signed, 16#0000:16, 3:16, 1:16, 2345:16, 6780:16>>}
    ],
    [
        {binary_to_list(Decimal), [
            ?_assertEqual(Wire, enc(Decimal, binary)),
            ?_assertEqual(Decimal, minato_codec:decode(?NUMERIC, Wire, binary))
        ]}
     || {Decimal, Wire} <- Cases
    ].

specials_use_the_documented_sign_field_test_() ->
    [
        ?_assertEqual(<<0:16, 0:16/signed, 16#C000:16, 0:16>>, enc(nan, binary)),
        ?_assertEqual(<<0:16, 0:16/signed, 16#D000:16, 0:16>>, enc(infinity, binary)),
        ?_assertEqual(<<0:16, 0:16/signed, 16#F000:16, 0:16>>, enc(neg_infinity, binary)),
        ?_assertEqual(nan, roundtrip(nan, binary)),
        ?_assertEqual(infinity, roundtrip(infinity, binary)),
        ?_assertEqual(neg_infinity, roundtrip(neg_infinity, binary)),
        ?_assertEqual(nan, roundtrip(nan, text)),
        ?_assertEqual(infinity, roundtrip(infinity, text)),
        ?_assertEqual(neg_infinity, roundtrip(neg_infinity, text)),
        ?_assertEqual(~"NaN", enc(nan, text)),
        ?_assertEqual(~"Infinity", enc(infinity, text)),
        ?_assertEqual(~"-Infinity", enc(neg_infinity, text)),
        ?_assertEqual(infinity, minato_codec:decode(?NUMERIC, ~"inf", text)),
        ?_assertEqual(neg_infinity, minato_codec:decode(?NUMERIC, ~"-inf", text))
    ].

%%----------------------------------------------------------------------
%% Display scale is exact and preserved
%%----------------------------------------------------------------------

display_scale_survives_round_trip_test_() ->
    Decimals = [
        ~"0",
        ~"0.0",
        ~"0.00",
        ~"1",
        ~"1.0",
        ~"1.00000",
        ~"123.4500",
        ~"-123.4500",
        ~"0.000001",
        ~"9999",
        ~"10000",
        ~"99999999",
        ~"100000000",
        ~"0.0001",
        ~"0.00001",
        ~"1234567890123456789012345678901234567890",
        ~"0.123456789012345678901234567890",
        ~"123456789012345678901234567890.123456789012345678901234567890"
    ],
    [
        {binary_to_list(Decimal), [
            ?_assertEqual(Decimal, roundtrip(Decimal, binary)),
            ?_assertEqual(Decimal, roundtrip(Decimal, text))
        ]}
     || Decimal <- Decimals
    ].

%%----------------------------------------------------------------------
%% Accepted input forms
%%----------------------------------------------------------------------

integers_and_floats_are_accepted_test_() ->
    [
        ?_assertEqual(~"42", roundtrip(42, binary)),
        ?_assertEqual(~"-42", roundtrip(-42, binary)),
        ?_assertEqual(~"0", roundtrip(0, binary)),
        ?_assertEqual(~"100000000", roundtrip(100000000, binary)),
        ?_assertEqual(~"1.5", roundtrip(1.5, binary)),
        ?_assertEqual(~"0.0015", roundtrip(1.5e-3, binary)),
        ?_assertEqual(~"1500", roundtrip(1.5e3, binary))
    ].

exponent_notation_is_accepted_test_() ->
    [
        ?_assertEqual(~"1000", roundtrip(~"1e3", binary)),
        ?_assertEqual(~"1000", roundtrip(~"1E3", binary)),
        ?_assertEqual(~"0.001", roundtrip(~"1e-3", binary)),
        ?_assertEqual(~"0.0015", roundtrip(~"15e-4", binary)),
        ?_assertEqual(~"1500", roundtrip(~"+15e+2", binary))
    ].

leading_zeros_and_negative_zero_normalise_test_() ->
    [
        ?_assertEqual(~"7", roundtrip(~"007", binary)),
        ?_assertEqual(~"0.50", roundtrip(~"0.50", binary)),
        ?_assertEqual(~"0.50", roundtrip(~".50", binary)),
        ?_assertEqual(~"0.00", roundtrip(~"-0.00", binary)),
        ?_assertEqual(~"0.00", roundtrip(~"-0.00", text)),
        ?_assertEqual(~"0", roundtrip(~"-0", binary))
    ].

rejects_test_() ->
    [
        ?_assertError({minato_codec, #{reason := malformed_decimal}}, enc(~"", binary)),
        ?_assertError({minato_codec, #{reason := malformed_decimal}}, enc(~"abc", binary)),
        ?_assertError({minato_codec, #{reason := malformed_decimal}}, enc(~".", binary)),
        ?_assertError({minato_codec, #{reason := malformed_decimal}}, enc(~"1e", binary)),
        ?_assertError({minato_codec, #{reason := malformed_decimal}}, enc(~"1.2.3", binary)),
        ?_assertError({minato_codec, #{reason := malformed_decimal}}, enc(~"1e2x", binary)),
        ?_assertError({minato_codec, #{reason := not_a_numeric}}, enc(an_atom, binary)),
        ?_assertError(
            {minato_codec, #{reason := malformed_decimal}},
            minato_codec:decode(?NUMERIC, ~"NaN!", text)
        ),
        ?_assertError(
            {minato_codec, #{reason := digit_count_mismatch}},
            minato_codec:decode(?NUMERIC, <<3:16, 0:16/signed, 0:16, 0:16, 1:16>>, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := {malformed, binary}}},
            minato_codec:decode(?NUMERIC, <<1, 2>>, binary)
        )
    ].

%%----------------------------------------------------------------------
%% Values that need implied zero groups on either side of the point
%%----------------------------------------------------------------------

implied_zero_groups_test_() ->
    [
        ?_assertEqual(
            ~"100000000",
            minato_codec:decode(?NUMERIC, <<1:16, 2:16/signed, 0:16, 0:16, 1:16>>, binary)
        ),
        ?_assertEqual(
            ~"0.00000001",
            minato_codec:decode(?NUMERIC, <<1:16, -2:16/signed, 0:16, 8:16, 1:16>>, binary)
        ),
        ?_assertEqual(~"0.00000001", roundtrip(~"0.00000001", binary)),
        ?_assertEqual(~"100000000.00000001", roundtrip(~"100000000.00000001", binary))
    ].

numeric_decodes_to_a_float_when_asked_test() ->
    ?assertEqual(3.5, decoded(~"3.5000", #{numeric_format => float})),
    ?assertEqual(42.0, decoded(~"42", #{numeric_format => float})),
    ?assertEqual(-0.25, decoded(~"-0.25", #{numeric_format => float})).

numeric_stays_exact_by_default_test() ->
    ?assertEqual(~"3.5000", decoded(~"3.5000", #{})),
    ?assertEqual(~"42", decoded(~"42", #{})).

a_float_form_keeps_the_specials_test() ->
    ?assertEqual(nan, decoded(nan, #{numeric_format => float})),
    ?assertEqual(infinity, decoded(infinity, #{numeric_format => float})),
    ?assertEqual(neg_infinity, decoded(neg_infinity, #{numeric_format => float})).

decoded(Value, Opts) ->
    Wire = iolist_to_binary(minato_codec_numeric:encode(numeric, Value, binary, #{})),
    minato_codec_numeric:decode(numeric, Wire, binary, Opts).
