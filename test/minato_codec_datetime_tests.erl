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

hour_24_is_only_midnight_at_the_end_of_the_day_test_() ->
    Rejected = [{24, 0, 1}, {24, 1, 0}, {24, 59, 60}],
    [
        ?_assertEqual(<<86400000000:64/signed>>, enc(1083, {24, 0, 0}, binary)),
        ?_assertEqual(~"24:00:00", enc(1083, {24, 0, 0}, text)),
        ?_assertEqual(<<86400000000:64/signed>>, enc(1114, {{2000, 1, 1}, {24, 0, 0}}, binary)),
        ?_assertEqual(<<86400000000:64/signed>>, enc(1184, {{2000, 1, 1}, {24, 0, 0}}, binary))
    ] ++
        [
            ?_assertError(
                {minato_codec, #{reason := time_out_of_range}}, enc(1083, Time, Format)
            )
         || Time <- Rejected, Format <- [binary, text]
        ] ++
        [
            ?_assertError(
                {minato_codec, #{reason := time_out_of_range}},
                enc(Oid, {{2026, 11, 3}, Time}, Format)
            )
         || Oid <- [1114, 1184], Time <- Rejected, Format <- [binary, text]
        ].

a_timestamp_or_date_on_a_day_that_does_not_exist_is_refused_test_() ->
    [
        ?_assertError(
            {minato_codec, #{reason := day_out_of_range}},
            enc(Oid, {{2026, 2, 30}, {0, 0, 0}}, Format)
        )
     || Oid <- [1114, 1184], Format <- [binary, text]
    ] ++
        [
            ?_assertError(
                {minato_codec, #{reason := day_out_of_range}}, enc(1082, {2026, 2, 30}, text)
            )
        ].

the_time_fields_are_bounded_test_() ->
    [
        ?_assertEqual(<<86400000000:64/signed>>, enc(1083, {23, 59, 60}, binary)),
        ?_assertEqual(<<0:64/signed>>, enc(1083, {0, 0, 0}, binary))
    ] ++
        [
            ?_assertError({minato_codec, #{reason := time_out_of_range}}, enc(1083, Time, binary))
         || Time <- [{-1, 0, 0}, {0, -1, 0}, {0, 0, -1}, {0, 60, 0}, {0, 0, 61}]
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

%%----------------------------------------------------------------------
%% The calendar, a day at a time
%%----------------------------------------------------------------------

every_day_of_a_year_around_each_rule_matches_otp_test() ->
    Years = [
        1,
        2,
        3,
        4,
        5,
        99,
        100,
        101,
        399,
        400,
        401,
        1582,
        1899,
        1900,
        1901,
        1969,
        1970,
        1999,
        2000,
        2001,
        2099,
        2100,
        2101,
        2399,
        2400,
        2401,
        9999
    ],
    Disagreed = [
        calendar:gregorian_days_to_date(Day)
     || Year <- Years,
        Day <- lists:seq(
            calendar:date_to_gregorian_days(Year, 1, 1),
            calendar:date_to_gregorian_days(Year, 12, 31)
        ),
        not agrees_with_otp(Day)
    ],
    ?assertEqual([], Disagreed).

agrees_with_otp(Gregorian) ->
    {Year, Month, Day} = Date = calendar:gregorian_days_to_date(Gregorian),
    Unix = Gregorian - calendar:date_to_gregorian_days(1970, 1, 1),
    minato_codec_datetime:civil_from_days(Unix) =:= Date andalso
        minato_codec_datetime:days_from_civil(Year, Month, Day) =:= Unix.

%% OTP's calendar stops at year zero. Before it, each day has to be the one
%% after the day before, in both directions, across two 400 year eras.
every_day_before_year_one_follows_the_one_before_test() ->
    First = minato_codec_datetime:days_from_civil(-801, 1, 1),
    Last = minato_codec_datetime:days_from_civil(1, 1, 1),
    ?assertEqual({-801, 1, 1}, minato_codec_datetime:civil_from_days(First)),
    ?assertEqual(ok, walked(First, Last, {-801, 1, 1})).

walked(Last, Last, _Date) ->
    ok;
walked(Day, Last, Date) ->
    {Year, Month, DayOfMonth} = Next = following(Date),
    Read = minato_codec_datetime:civil_from_days(Day + 1),
    Written = minato_codec_datetime:days_from_civil(Year, Month, DayOfMonth),
    case Read =:= Next andalso Written =:= Day + 1 of
        true -> walked(Day + 1, Last, Next);
        false -> {after_day, Date, Read, Written}
    end.

following({Year, 12, 31}) ->
    {Year + 1, 1, 1};
following({Year, Month, Day}) ->
    case Day =:= last_day(Year, Month) of
        true -> {Year, Month + 1, 1};
        false -> {Year, Month, Day + 1}
    end.

last_day(Year, 2) ->
    case Year rem 4 =:= 0 andalso (Year rem 100 =/= 0 orelse Year rem 400 =:= 0) of
        true -> 29;
        false -> 28
    end;
last_day(_Year, Month) when Month =:= 4; Month =:= 6; Month =:= 9; Month =:= 11 -> 30;
last_day(_Year, _Month) ->
    31.

each_month_ends_where_it_ends_test_() ->
    [
        {integer_to_list(Year) ++ "-" ++ integer_to_list(Month), [
            ?_assertMatch(<<_:32>>, enc(1082, {Year, Month, last_day(Year, Month)}, binary)),
            ?_assertError(
                {minato_codec, #{reason := day_out_of_range}},
                enc(1082, {Year, Month, last_day(Year, Month) + 1}, binary)
            )
        ]}
     || Year <- [1900, 2000, 2023, 2024], Month <- lists:seq(1, 12)
    ].

a_date_outside_the_calendar_is_refused_over_the_field_that_is_wrong_test_() ->
    [
        {Label, [
            ?_assertError(
                {minato_codec, #{type := date, reason := Reason, value := Date}},
                enc(1082, Date, Format)
            ),
            ?_assertError(
                {minato_codec, #{reason := Reason}}, enc(1114, {Date, {0, 0, 0}}, Format)
            ),
            ?_assertError(
                {minato_codec, #{reason := Reason}}, enc(1184, {Date, {0, 0, 0}}, Format)
            )
        ]}
     || {Label, Date, Reason} <- [
            {"month zero", {2024, 0, 1}, month_out_of_range},
            {"month thirteen", {2024, 13, 1}, month_out_of_range},
            {"a negative month", {2024, -1, 1}, month_out_of_range},
            {"day zero", {2024, 1, 0}, day_out_of_range},
            {"a negative day", {2024, 1, -1}, day_out_of_range},
            {"day thirty two", {2024, 1, 32}, day_out_of_range},
            {"neither month nor day", {2024, 0, 0}, month_out_of_range}
        ],
        Format <- [binary, text]
    ].

%% A date is four bytes of days and a timestamp eight of microseconds, with
%% the largest and smallest of each meaning infinity. A value past them was
%% written with its high bits cut off, which is another date altogether.
a_value_too_far_away_to_write_is_refused_test_() ->
    Latest = {5874897, 12, 31},
    [
        ?_assertEqual(Latest, roundtrip(1082, Latest)),
        ?_assertEqual({-4712, 1, 1}, roundtrip(1082, {-4712, 1, 1})),
        ?_assertMatch(<<_:64>>, enc(1114, {{294276, 12, 31}, {23, 59, 59}}, binary)),
        ?_assertMatch(<<_:64>>, enc(1114, 9223371331199999999 + 946684800000000, binary))
    ] ++
        [
            ?_assertError(
                {minato_codec, #{type := date, reason := out_of_range, value := Date}},
                enc(1082, Date, binary)
            )
         || Date <- [
                {5881611, 1, 1},
                {6000000, 1, 1},
                {11759222, 1, 1},
                {-5877641, 1, 1},
                {-6000000, 1, 1}
            ]
        ] ++
        [
            ?_assertError(
                {minato_codec, #{type := Type, reason := out_of_range, value := Value}},
                enc(Oid, Value, binary)
            )
         || {Oid, Type} <- [{1114, timestamp}, {1184, timestamptz}],
            Value <- [
                {{294300, 1, 1}, {0, 0, 0}},
                {{-292300, 1, 1}, {0, 0, 0}},
                {{600000, 1, 1}, {0, 0, 0}},
                (1 bsl 63) + 946684800000000,
                (1 bsl 63) - 1 + 946684800000000,
                -(1 bsl 63) + 946684800000000,
                (1 bsl 64) + 5
            ]
        ].

%% The last value before each end is still a value, and the end is not.
the_ends_of_the_wire_are_where_a_value_stops_test_() ->
    Epoch = 946684800000000,
    [
        ?_assertEqual(<<2147483646:32/signed>>, enc(1082, {5881610, 7, 10}, binary)),
        ?_assertEqual(<<-2147483647:32/signed>>, enc(1082, {-5877611, 6, 23}, binary)),
        ?_assertError(
            {minato_codec, #{type := date, reason := out_of_range}},
            enc(1082, {5881610, 7, 11}, binary)
        ),
        ?_assertError(
            {minato_codec, #{type := date, reason := out_of_range}},
            enc(1082, {-5877611, 6, 22}, binary)
        )
    ] ++
        [
            ?_assertEqual(<<Micros:64/signed>>, enc(Oid, Micros + Epoch, binary))
         || Oid <- [1114, 1184], Micros <- [(1 bsl 63) - 2, -(1 bsl 63) + 1]
        ] ++
        [
            ?_assertError(
                {minato_codec, #{reason := out_of_range}}, enc(Oid, Micros + Epoch, binary)
            )
         || Oid <- [1114, 1184], Micros <- [(1 bsl 63) - 1, -(1 bsl 63)]
        ].

a_whole_hour_is_read_as_one_test_() ->
    Times = [{1, 0, 0}, {12, 0, 0}, {23, 0, 0}, {1, 1, 1}],
    [?_assertEqual(Time, roundtrip(1083, Time)) || Time <- Times] ++
        [?_assertEqual(Time, roundtrip_text(1083, Time)) || Time <- Times] ++
        [
            ?_assertEqual({{2024, 1, 15}, Time}, roundtrip(Oid, {{2024, 1, 15}, Time}))
         || Oid <- [1114, 1184], Time <- Times
        ] ++
        [
            ?_assertEqual({{2024, 1, 15}, Time}, roundtrip_text(Oid, {{2024, 1, 15}, Time}))
         || Oid <- [1114, 1184], Time <- Times
        ].

a_time_of_day_as_microseconds_stays_inside_the_day_test_() ->
    [
        ?_assertEqual(<<0:64>>, enc(1083, 0, binary)),
        ?_assertEqual(<<86400000000:64>>, enc(1083, 86400000000, binary)),
        ?_assertEqual(~"24:00:00", iolist_to_binary(enc(1083, 86400000000, text)))
    ] ++
        [
            ?_assertError(
                {minato_codec, #{type := time, reason := time_out_of_range, value := Micros}},
                enc(1083, Micros, Format)
            )
         || Micros <- [-1, 86400000001, (1 bsl 64) + 5, -(1 bsl 64)], Format <- [binary, text]
        ].

the_last_second_of_a_minute_may_be_a_leap_second_test_() ->
    [
        ?_assertEqual(<<86400000000:64/signed>>, enc(1083, {23, 59, 60}, binary)),
        ?_assertEqual(<<86400000000:64/signed>>, enc(1083, {24, 0, 0}, binary)),
        ?_assertEqual(<<86399000000:64/signed>>, enc(1083, {23, 59, 59}, binary)),
        ?_assertError(
            {minato_codec, #{reason := time_out_of_range}}, enc(1083, {24, 0, 1}, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := time_out_of_range}}, enc(1083, {24, 1, 0}, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := time_out_of_range}}, enc(1083, {23, 60, 0}, binary)
        )
    ].

%%----------------------------------------------------------------------
%% Before the epoch, and below the second
%%----------------------------------------------------------------------

a_moment_before_1970_rounds_towards_the_past_test_() ->
    Read = fun(UnixMicros) ->
        minato_codec:decode(1114, <<(UnixMicros - ?PG_EPOCH_MICROS):64/signed>>, binary)
    end,
    [
        ?_assertEqual({{1969, 12, 31}, {23, 59, 59}}, Read(-1)),
        ?_assertEqual({{1969, 12, 31}, {23, 59, 59}}, Read(-1000000)),
        ?_assertEqual({{1969, 12, 31}, {23, 59, 58}}, Read(-1000001)),
        ?_assertEqual({{1969, 12, 31}, {0, 0, 0}}, Read(-86400000000)),
        ?_assertEqual({{1969, 12, 30}, {23, 59, 59}}, Read(-86400000001)),
        ?_assertEqual({{1970, 1, 1}, {1, 2, 3}}, Read(3723999999))
    ].

a_time_is_read_down_to_the_second_test_() ->
    [
        ?_assertEqual({1, 2, 3}, minato_codec:decode(1083, <<3723999999:64/signed>>, binary)),
        ?_assertEqual({23, 59, 59}, minato_codec:decode(1083, <<86399000000:64/signed>>, binary))
    ].

a_fraction_is_written_without_trailing_zeros_test_() ->
    [
        ?_assertEqual(~"00:00:00.5", enc(1083, 500000, text)),
        ?_assertEqual(~"00:00:00.000001", enc(1083, 1, text)),
        ?_assertEqual(~"01:02:03.04", enc(1083, 3723040000, text)),
        ?_assertEqual(~"01:02:03", enc(1083, 3723000000, text)),
        ?_assertEqual(~"10:20:30.1002", enc(1083, 37230100200, text)),
        ?_assertEqual(~"2000-01-01 00:00:00.25", enc(1114, ?PG_EPOCH_MICROS + 250000, text)),
        ?_assertEqual(~"1969-12-31 23:59:59.999999", enc(1114, -1, text)),
        ?_assertEqual(~"1969-12-30 00:00:00", enc(1114, -172800000000, text))
    ].

a_fraction_is_read_to_the_microsecond_test_() ->
    Read = fun(Text) ->
        minato_codec:decode(1083, Text, text, #{datetime_format => microseconds})
    end,
    [
        ?_assertEqual(500000, Read(~"00:00:00.5")),
        ?_assertEqual(1, Read(~"00:00:00.000001")),
        ?_assertEqual(123456, Read(~"00:00:00.123456")),
        ?_assertEqual(120000, Read(~"00:00:00.12")),
        ?_assertEqual(3723004000, Read(~"01:02:03.004")),
        ?_assertEqual(86399000000, Read(~"23:59:59")),
        ?_assertError({minato_codec, #{reason := malformed_text}}, Read(~"00:00:00.1234567")),
        ?_assertError({minato_codec, #{reason := malformed_text}}, Read(~"00:00:00.")),
        ?_assertError({minato_codec, #{reason := malformed_text}}, Read(~"00:00")),
        ?_assertError({minato_codec, #{reason := malformed_text}}, Read(~"aa:00:00"))
    ].

an_offset_is_taken_off_to_the_second_test_() ->
    Read = fun(Offset) ->
        Text = <<"2024-01-15 13:45:30", Offset/binary>>,
        minato_codec:decode(1184, Text, text, #{datetime_format => microseconds})
    end,
    Utc = Read(~"+00"),
    [
        ?_assertEqual(Utc, Read(~"")),
        ?_assertEqual(Utc - 3600000000, Read(~"+01")),
        ?_assertEqual(Utc - 5400000000, Read(~"+01:30")),
        ?_assertEqual(Utc - 3723000000, Read(~"+01:02:03")),
        ?_assertEqual(Utc + 3723000000, Read(~"-01:02:03")),
        ?_assertError(
            {minato_codec, #{reason := malformed_offset}}, Read(~"+01:02:03:04")
        )
    ].

%% The longest text a server writes for each, and what is longer than that in
%% one field or as a whole. A field is read as an integer, and that costs more
%% than its length; the whole is split on its separators, and that makes a
%% list as long as there are separators.
the_longest_date_and_time_a_server_writes_is_read_test_() ->
    Micros = #{datetime_format => microseconds},
    [
        ?_assertEqual({5874897, 12, 31}, minato_codec:decode(1082, ~"5874897-12-31", text)),
        ?_assertEqual(86399999999, minato_codec:decode(1083, ~"23:59:59.999999", text, Micros)),
        ?_assertEqual(
            {{294276, 12, 31}, {23, 59, 59}},
            minato_codec:decode(1114, ~"294276-12-31 23:59:59", text)
        ),
        ?_assertEqual(
            minato_codec:decode(1184, ~"2024-01-15 00:00:00+00", text, Micros) - 57599000000,
            minato_codec:decode(1184, ~"2024-01-15 00:00:00.000000+15:59:59", text, Micros)
        )
    ].

a_date_or_a_time_longer_than_a_server_writes_is_not_read_test_() ->
    [
        {
            lists:flatten(
                io_lib:format("~p ~s", [Oid, binary:part(Text, 0, min(40, byte_size(Text)))])
            ),
            ?_assertError(
                {minato_codec, #{reason := malformed_text}}, minato_codec:decode(Oid, Text, text)
            )
        }
     || {Oid, Text} <- [
            {1082, ~"58748970-12-31"},
            {1082, ~"2024-001-15"},
            {1082, ~"2024-01-015"},
            {1082, <<(binary:copy(~"9", 100000))/binary, "-01-15">>},
            {1082, binary:copy(~"-", 100000)},
            {1083, ~"012:00:00"},
            {1083, ~"12:000:00"},
            {1083, ~"12:00:000"},
            {1083, <<(binary:copy(~"1", 100000))/binary, ":00:00">>},
            {1083, binary:copy(~":", 100000)},
            {1114, ~"2942760-12-31 23:59:59"},
            {1114, ~"2024-01-15 012:00:00"},
            {1114, <<"2024-01-15 ", (binary:copy(~"1", 100000))/binary, ":00:00">>},
            {1184, ~"2024-01-15 00:00:00+015"},
            {1184, ~"2024-01-15 00:00:00+15:059"},
            {1184, <<"2024-01-15 00:00:00+", (binary:copy(~"1", 100000))/binary>>},
            {1184, <<"2024-01-15 00:00:00+", (binary:copy(~":", 100000))/binary>>}
        ]
    ].

what_is_not_a_date_or_a_time_is_refused_by_name_test_() ->
    [
        ?_assertError({minato_codec, #{reason := not_a_date}}, enc(1082, ~"2024-01-15", text)),
        ?_assertError({minato_codec, #{reason := not_a_time}}, enc(1083, ~"12:00:00", binary)),
        ?_assertError({minato_codec, #{reason := not_a_time}}, enc(1083, {12, 0}, text))
    ].

a_date_read_as_text_is_checked_like_one_written_test_() ->
    Read = fun(Text) -> minato_codec:decode(1082, Text, text) end,
    [
        ?_assertError({minato_codec, #{reason := day_out_of_range}}, Read(~"2026-02-30")),
        ?_assertError({minato_codec, #{reason := month_out_of_range}}, Read(~"2026-13-01")),
        ?_assertError({minato_codec, #{reason := malformed_text}}, Read(~"2026-02")),
        ?_assertError({minato_codec, #{reason := malformed_text}}, Read(~"2026-02-03-04"))
    ].
