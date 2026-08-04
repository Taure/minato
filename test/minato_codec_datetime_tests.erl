-module(minato_codec_datetime_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PG_EPOCH_MICROS, 946684800000000).

enc(Oid, Value, Format) ->
    wire(minato_codec:encode(Oid, Value, Format)).

%%----------------------------------------------------------------------
%% The calendar arithmetic, cross checked against OTP's calendar module
%%----------------------------------------------------------------------

days_from_civil_matches_otp_test_() ->
    Dates = [
        {1, 1, 1},
        {1582, 10, 15},
        {1900, 2, 28},
        {1900, 3, 1},
        {1969, 12, 31},
        {1970, 1, 1},
        {1999, 12, 31},
        {2000, 1, 1},
        {2000, 2, 29},
        {2024, 2, 29},
        {2100, 3, 1},
        {9999, 12, 31}
    ],
    [
        {
            lists:flatten(io_lib:format("~p", [Date])),
            ?_assertEqual(
                calendar:date_to_gregorian_days(Date) - 719528,
                minato_codec_datetime:days_from_civil(Y, M, D)
            )
        }
     || {Y, M, D} = Date <- Dates
    ].

civil_from_days_is_the_inverse_test_() ->
    [
        ?_assertEqual({1970, 1, 1}, minato_codec_datetime:civil_from_days(0)),
        ?_assertEqual({1969, 12, 31}, minato_codec_datetime:civil_from_days(-1)),
        ?_assertEqual({2000, 1, 1}, minato_codec_datetime:civil_from_days(10957)),
        ?_assertEqual({1, 1, 1}, minato_codec_datetime:civil_from_days(-719162)),
        ?_assertEqual({0, 12, 31}, minato_codec_datetime:civil_from_days(-719163))
    ].

%%----------------------------------------------------------------------
%% date
%%----------------------------------------------------------------------

date_wire_is_days_from_2000_test_() ->
    [
        ?_assertEqual(<<0:32/signed>>, enc(1082, {2000, 1, 1}, binary)),
        ?_assertEqual(<<1:32/signed>>, enc(1082, {2000, 1, 2}, binary)),
        ?_assertEqual(<<-10957:32/signed>>, enc(1082, {1970, 1, 1}, binary)),
        ?_assertEqual({2000, 1, 1}, minato_codec:decode(1082, <<0:32/signed>>, binary)),
        ?_assertEqual({1970, 1, 1}, minato_codec:decode(1082, <<-10957:32/signed>>, binary))
    ].

date_text_test_() ->
    [
        ?_assertEqual(~"2024-01-15", enc(1082, {2024, 1, 15}, text)),
        ?_assertEqual(~"0001-01-01", enc(1082, {1, 1, 1}, text)),
        ?_assertEqual({2024, 1, 15}, minato_codec:decode(1082, ~"2024-01-15", text)),
        ?_assertEqual({1, 1, 1}, minato_codec:decode(1082, ~"0001-01-01", text))
    ].

date_infinities_test_() ->
    [
        ?_assertEqual(<<2147483647:32/signed>>, enc(1082, infinity, binary)),
        ?_assertEqual(<<-2147483648:32/signed>>, enc(1082, neg_infinity, binary)),
        ?_assertEqual(infinity, minato_codec:decode(1082, <<2147483647:32/signed>>, binary)),
        ?_assertEqual(neg_infinity, minato_codec:decode(1082, <<-2147483648:32/signed>>, binary)),
        ?_assertEqual(infinity, minato_codec:decode(1082, ~"infinity", text)),
        ?_assertEqual(neg_infinity, minato_codec:decode(1082, ~"-infinity", text)),
        ?_assertEqual(~"infinity", enc(1082, infinity, text))
    ].

date_leap_years_test_() ->
    [
        ?_assertEqual({2000, 2, 29}, roundtrip(1082, {2000, 2, 29})),
        ?_assertEqual({2024, 2, 29}, roundtrip(1082, {2024, 2, 29})),
        ?_assertError(
            {minato_codec, #{reason := day_out_of_range}}, enc(1082, {1900, 2, 29}, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := day_out_of_range}}, enc(1082, {2023, 2, 29}, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := day_out_of_range}}, enc(1082, {2024, 4, 31}, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := month_out_of_range}}, enc(1082, {2024, 13, 1}, binary)
        ),
        ?_assertError({minato_codec, #{reason := not_a_date}}, enc(1082, ~"2024-01-15", binary))
    ].

date_rejects_bc_text_test_() ->
    ?_assertError(
        {minato_codec, #{reason := bc_dates_unsupported}},
        minato_codec:decode(1082, ~"0001-01-01 BC", text)
    ).

%%----------------------------------------------------------------------
%% time
%%----------------------------------------------------------------------

time_test_() ->
    [
        ?_assertEqual(<<0:64/signed>>, enc(1083, {0, 0, 0}, binary)),
        ?_assertEqual(<<86399000000:64/signed>>, enc(1083, {23, 59, 59}, binary)),
        ?_assertEqual({23, 59, 59}, minato_codec:decode(1083, <<86399000000:64/signed>>, binary)),
        ?_assertEqual(~"13:45:30", enc(1083, {13, 45, 30}, text)),
        ?_assertEqual({13, 45, 30}, minato_codec:decode(1083, ~"13:45:30", text)),
        ?_assertEqual({13, 45, 30}, minato_codec:decode(1083, ~"13:45:30.123456", text)),
        ?_assertError({minato_codec, #{reason := time_out_of_range}}, enc(1083, {25, 0, 0}, binary))
    ].

time_microseconds_option_test_() ->
    Opts = #{datetime_format => microseconds},
    [
        ?_assertEqual(
            86399123456, minato_codec:decode(1083, <<86399123456:64/signed>>, binary, Opts)
        ),
        ?_assertEqual(86399123456, minato_codec:decode(1083, ~"23:59:59.123456", text, Opts)),
        ?_assertEqual(<<86399123456:64/signed>>, enc(1083, 86399123456, binary)),
        ?_assertEqual(~"23:59:59.123456", enc(1083, 86399123456, text))
    ].

%%----------------------------------------------------------------------
%% timestamp and timestamptz
%%----------------------------------------------------------------------

timestamp_wire_is_micros_from_2000_test_() ->
    [
        {integer_to_list(Oid), [
            ?_assertEqual(<<0:64/signed>>, enc(Oid, {{2000, 1, 1}, {0, 0, 0}}, binary)),
            ?_assertEqual(
                {{2000, 1, 1}, {0, 0, 0}}, minato_codec:decode(Oid, <<0:64/signed>>, binary)
            ),
            ?_assertEqual(
                <<-?PG_EPOCH_MICROS:64/signed>>, enc(Oid, {{1970, 1, 1}, {0, 0, 0}}, binary)
            ),
            ?_assertEqual(
                {{2024, 1, 15}, {13, 45, 30}}, roundtrip(Oid, {{2024, 1, 15}, {13, 45, 30}})
            )
        ]}
     || Oid <- [1114, 1184]
    ].

timestamps_before_2000_are_negative_test_() ->
    Cases = [
        {{1969, 7, 20}, {20, 17, 40}},
        {{1900, 1, 1}, {0, 0, 0}},
        {{1, 1, 1}, {0, 0, 0}},
        {{1999, 12, 31}, {23, 59, 59}}
    ],
    [
        {lists:flatten(io_lib:format("~p", [Value])), [
            ?_assert(binary:decode_unsigned(enc(1184, Value, binary)) > 16#8000000000000000),
            ?_assertEqual(Value, roundtrip(1184, Value)),
            ?_assertEqual(Value, roundtrip_text(1184, Value))
        ]}
     || Value <- Cases
    ].

sub_second_precision_is_floored_not_truncated_test_() ->
    HalfSecondBefore2000 = <<-500000:64/signed>>,
    HalfSecondAfter2000 = <<500000:64/signed>>,
    [
        ?_assertEqual(
            {{1999, 12, 31}, {23, 59, 59}},
            minato_codec:decode(1184, HalfSecondBefore2000, binary)
        ),
        ?_assertEqual(
            {{2000, 1, 1}, {0, 0, 0}},
            minato_codec:decode(1184, HalfSecondAfter2000, binary)
        ),
        ?_assertEqual(
            {{1999, 12, 31}, {23, 59, 59}},
            minato_codec:decode(1184, <<-1:64/signed>>, binary)
        )
    ].

timestamp_microseconds_option_is_lossless_test_() ->
    Opts = #{datetime_format => microseconds},
    [
        ?_assertEqual(
            ?PG_EPOCH_MICROS - 500000,
            minato_codec:decode(1184, <<-500000:64/signed>>, binary, Opts)
        ),
        ?_assertEqual(0, minato_codec:decode(1184, <<-?PG_EPOCH_MICROS:64/signed>>, binary, Opts)),
        ?_assertEqual(<<-500000:64/signed>>, enc(1184, ?PG_EPOCH_MICROS - 500000, binary)),
        ?_assertEqual(
            ?PG_EPOCH_MICROS - 500000,
            minato_codec:decode(1184, enc(1184, ?PG_EPOCH_MICROS - 500000, binary), binary, Opts)
        )
    ].

timestamp_infinities_test_() ->
    [
        {
            integer_to_list(Oid) ++ " " ++ atom_to_list(Format) ++ " " ++ atom_to_list(Special),
            ?_assertEqual(Special, minato_codec:decode(Oid, enc(Oid, Special, Format), Format))
        }
     || Oid <- [1114, 1184], Format <- [binary, text], Special <- [infinity, neg_infinity]
    ].

timestamptz_text_carries_an_offset_test_() ->
    [
        ?_assertEqual(~"2024-01-15 13:45:30+00", enc(1184, {{2024, 1, 15}, {13, 45, 30}}, text)),
        ?_assertEqual(~"2024-01-15 13:45:30", enc(1114, {{2024, 1, 15}, {13, 45, 30}}, text)),
        ?_assertEqual(
            {{2024, 1, 15}, {13, 45, 30}},
            minato_codec:decode(1184, ~"2024-01-15 13:45:30+00", text)
        ),
        ?_assertEqual(
            {{2024, 1, 15}, {13, 45, 30}},
            minato_codec:decode(1184, ~"2024-01-15 15:45:30+02", text)
        ),
        ?_assertEqual(
            {{2024, 1, 15}, {13, 45, 30}},
            minato_codec:decode(1184, ~"2024-01-15 08:15:30-05:30", text)
        ),
        ?_assertEqual(
            {{2024, 1, 15}, {13, 45, 30}},
            minato_codec:decode(1184, ~"2024-01-15 13:45:30.999999+00", text)
        )
    ].

timestamp_text_ignores_an_offset_test() ->
    ?assertEqual(
        {{2024, 1, 15}, {13, 45, 30}}, minato_codec:decode(1114, ~"2024-01-15 13:45:30", text)
    ).

timestamp_rejects_test_() ->
    [
        ?_assertError(
            {minato_codec, #{reason := not_a_timestamp}}, enc(1184, {2024, 1, 15}, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := {malformed, binary}}},
            minato_codec:decode(1184, <<1, 2, 3>>, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := malformed_text}}, minato_codec:decode(1184, ~"nope", text)
        ),
        ?_assertError(
            {minato_codec, #{reason := bc_dates_unsupported}},
            minato_codec:decode(1184, ~"0001-01-01 00:00:00 BC", text)
        )
    ].

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

roundtrip(Oid, Value) ->
    minato_codec:decode(Oid, enc(Oid, Value, binary), binary).

roundtrip_text(Oid, Value) ->
    minato_codec:decode(Oid, enc(Oid, Value, text), text).

wire(null) -> null;
wire(IoData) -> iolist_to_binary(IoData).
