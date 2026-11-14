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
%% Bounds
%%----------------------------------------------------------------------

an_exponent_outside_the_type_is_refused_before_anything_is_built_test_() ->
    Huge = <<"1e", (binary:copy(~"9", 100000))/binary>>,
    [
        {
            binary_to_list(Format) ++ " " ++ Label,
            ?_assertError(
                {minato_codec, #{type := numeric, reason := out_of_range}},
                enc(Decimal, binary_to_existing_atom(Format))
            )
        }
     || Format <- [~"binary", ~"text"],
        {Label, Decimal} <- [
            {"1e99999999999", ~"1e99999999999"},
            {"1e-99999999999", ~"1e-99999999999"},
            {"one digit past the integer limit", ~"1e131072"},
            {"one digit past the scale limit", ~"1e-16384"},
            {"an exponent too long to read", Huge}
        ]
    ].

the_limits_themselves_encode_test_() ->
    [
        ?_assertEqual(<<1:16, 32767:16/signed, 0:16, 0:16, 1000:16>>, enc(~"1e131071", binary)),
        ?_assertEqual(
            <<1:16, -4096:16/signed, 0:16, 16383:16, 10:16>>, enc(~"1e-16383", binary)
        ),
        ?_assertEqual(131072, byte_size(enc(~"1e131071", text))),
        ?_assertEqual(~"1000", roundtrip(~"1e0000000003", binary))
    ].

zero_is_zero_whatever_its_exponent_test_() ->
    [
        ?_assertEqual(~"0", roundtrip(~"0e99999999999", binary)),
        ?_assertEqual(~"0", roundtrip(~"0e99999999999", text)),
        ?_assertEqual(~"0", roundtrip(~"-0.000e99999999999", binary)),
        ?_assertError(
            {minato_codec, #{reason := out_of_range}}, enc(~"0e-99999999999", binary)
        )
    ].

the_largest_numeric_round_trips_test_() ->
    Largest = <<
        (binary:copy(~"9", 131072))/binary, $., (binary:copy(~"9", 16383))/binary
    >>,
    [
        ?_assertEqual(Largest, roundtrip(Largest, binary)),
        ?_assertEqual(<<$-, Largest/binary>>, roundtrip(<<$-, Largest/binary>>, binary)),
        ?_assertEqual(Largest, roundtrip(Largest, text)),
        ?_assertError(
            {minato_codec, #{reason := out_of_range}}, enc(<<$9, Largest/binary>>, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := out_of_range}}, enc(<<Largest/binary, $9>>, binary)
        )
    ].

a_header_no_server_writes_is_refused_test_() ->
    [
        ?_assertError(
            {minato_codec, #{reason := scale_out_of_range}},
            minato_codec:decode(?NUMERIC, <<0:16, 0:16/signed, 0:16, 16384:16>>, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := digit_out_of_range, value := 10000}},
            minato_codec:decode(?NUMERIC, <<1:16, 0:16/signed, 0:16, 0:16, 10000:16>>, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := digit_out_of_range}},
            minato_codec:decode(
                ?NUMERIC, <<2:16, 1:16/signed, 0:16, 0:16, 1:16, 65535:16>>, binary
            )
        ),
        ?_assertError(
            {minato_codec, #{reason := digit_out_of_range}},
            minato_codec:decode(
                ?NUMERIC, <<2:16, 0:16/signed, 0:16, 4:16, 1:16, 10000:16>>, binary
            )
        ),
        ?_assertError(
            {minato_codec, #{reason := digit_out_of_range}},
            minato_codec:decode(
                ?NUMERIC, <<1:16, -1:16/signed, 0:16, 2:16, 10000:16>>, binary
            )
        )
    ].

the_widest_header_decodes_to_a_bounded_value_test() ->
    Wire = <<1:16, 32767:16/signed, 16#4000:16, 16383:16, 9999:16>>,
    Decoded = minato_codec:decode(?NUMERIC, Wire, binary),
    ?assertMatch(<<"-9999", _:(131072 - 4 + 1 + 16383)/binary>>, Decoded).

a_numeric_too_large_for_a_float_is_a_codec_failure_test() ->
    Wire = <<1:16, 100:16/signed, 0:16, 0:16, 1:16>>,
    ?assertError(
        {minato_codec, #{type := numeric, reason := not_a_float}},
        minato_codec_numeric:decode(numeric, Wire, binary, #{numeric_format => float})
    ).

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

%%----------------------------------------------------------------------
%% Edges the cases above leave between them
%%----------------------------------------------------------------------

a_digit_out_of_range_is_named_wherever_it_stands_test_() ->
    Refused = fun(Wire) ->
        ?_assertError(
            {minato_codec, #{reason := digit_out_of_range, value := 10000}},
            minato_codec:decode(?NUMERIC, Wire, binary)
        )
    end,
    [
        {"a later group of the whole part",
            Refused(<<2:16, 1:16/signed, 0:16, 0:16, 1:16, 10000:16>>)},
        {"a whole group of the fraction",
            Refused(<<2:16, 0:16/signed, 0:16, 4:16, 1:16, 10000:16>>)},
        {"the last, partly shown group of the fraction",
            Refused(<<1:16, -1:16/signed, 0:16, 2:16, 10000:16>>)}
    ].

the_largest_digit_is_read_wherever_it_stands_test_() ->
    [
        ?_assertEqual(
            ~"19999",
            minato_codec:decode(?NUMERIC, <<2:16, 1:16/signed, 0:16, 0:16, 1:16, 9999:16>>, binary)
        ),
        ?_assertEqual(
            ~"0.9999",
            minato_codec:decode(?NUMERIC, <<1:16, -1:16/signed, 0:16, 4:16, 9999:16>>, binary)
        ),
        ?_assertEqual(
            ~"0.99",
            minato_codec:decode(?NUMERIC, <<1:16, -1:16/signed, 0:16, 2:16, 9999:16>>, binary)
        )
    ].

a_negative_sign_on_no_digits_is_zero_test() ->
    ?assertEqual(
        ~"0", minato_codec:decode(?NUMERIC, <<0:16, 0:16/signed, 16#4000:16, 0:16>>, binary)
    ).

an_exponent_of_zero_changes_nothing_test_() ->
    [
        {binary_to_list(Written), [
            ?_assertEqual(enc(~"1", binary), enc(Written, binary)),
            ?_assertEqual(~"1", roundtrip(Written, binary))
        ]}
     || Written <- [~"1e0", ~"1e00", ~"1E-0", ~"1e+0"]
    ].

zero_to_any_power_is_zero_test_() ->
    [
        {binary_to_list(Written), [
            ?_assertEqual(enc(~"0", binary), enc(Written, binary)),
            ?_assertEqual(~"0", roundtrip(Written, binary))
        ]}
     || Written <- [~"0e1", ~"0e5", ~"00e2"]
    ].

leading_zeros_are_not_digits_test_() ->
    [
        {binary_to_list(Written), ?_assertEqual(Plain, roundtrip(Written, binary))}
     || {Written, Plain} <- [{~"007", ~"7"}, {~"000", ~"0"}, {~"00.5", ~"0.5"}, {~"0010e1", ~"100"}]
    ] ++
        [
            {binary_to_list(Written), ?_assertEqual(Plain, enc(Written, text))}
         || {Written, Plain} <- [
                {~"007", ~"7"},
                {~"000", ~"0"},
                {~"00.5", ~"0.5"},
                {~"0e5", ~"0"},
                {~"0e1", ~"0"},
                {~"1e2", ~"100"},
                {~"1e0", ~"1"},
                {~"-0.50", ~"-0.50"}
            ]
        ].
