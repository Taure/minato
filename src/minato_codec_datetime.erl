-module(minato_codec_datetime).
-moduledoc """
Codecs for `date`, `time`, `timestamp` and `timestamptz`.

Internal to minato. The supported surface is `m:minato_codec`.

## Wire formats

PostgreSQL has compiled with 64 bit integer timestamps since version 10, and
the floating point build was removed, so the binary representations are:

- `date`: `int32` days relative to 2000-01-01.
- `time`: `int64` microseconds since midnight.
- `timestamp` and `timestamptz`: `int64` microseconds relative to
  2000-01-01T00:00:00. `timestamptz` is always UTC on the wire; the server
  converts to and from the session time zone at the text boundary only.

The reserved values `infinity` and `-infinity` are the maximum and minimum of
the signed integer for the type.

## Erlang representation

`date` decodes to `{Year, Month, Day}`, the shape of `t:calendar:date/0`.

`time`, `timestamp` and `timestamptz` decode according to the `datetime_format`
option:

- `datetime` (the default) gives `{Hour, Minute, Second}` for `time` and
  `{{Year, Month, Day}, {Hour, Minute, Second}}` for the two timestamp types.
  Second is an integer, so **sub-second precision is discarded**. It is
  discarded by flooring, never by truncating towards zero, so the mapping stays
  monotonic across the epoch: 1999-12-31T23:59:59.5 decodes to 23:59:59 and not
  to 1999-12-31T23:59:60 or 2000-01-01T00:00:00.
- `microseconds` is lossless. `time` gives an integer count of microseconds
  since midnight; `timestamp` and `timestamptz` give an integer count of
  microseconds since the **Unix** epoch, directly comparable with
  `os:system_time(microsecond)`.

Encoding accepts either shape whatever the option says, because the option only
governs what decoding produces. An integer passed to `timestamp` or
`timestamptz` is read as microseconds since the Unix epoch, and an integer
passed to `time` as microseconds since midnight.

`infinity` and `neg_infinity` are accepted and produced by `date`, `timestamp`
and `timestamptz` in both directions.

Years are astronomical: year 0 is 1 BC. The binary format handles them, but
PostgreSQL writes text dates before year 1 with a `BC` suffix in a different
numbering, so decoding such a text value raises rather than guess.
""".

-export([encode/4, decode/4, days_from_civil/3, civil_from_days/1]).

-define(DAYS_UNIX_TO_PG, 10957).
-define(MICROS_UNIX_TO_PG, 946684800000000).
-define(DAY_MICROS, 86400000000).
-define(INT32_MAX, 2147483647).
-define(INT32_MIN, -2147483648).
-define(INT64_MAX, 9223372036854775807).
-define(INT64_MIN, -9223372036854775808).

-doc "Encode a temporal value to `Format` wire bytes.".
-spec encode(
    date | time | timestamp | timestamptz, term(), minato_codec:format(), minato_codec:opts()
) ->
    iodata().
encode(date, infinity, binary, _Opts) ->
    <<?INT32_MAX:32/signed>>;
encode(date, neg_infinity, binary, _Opts) ->
    <<?INT32_MIN:32/signed>>;
encode(date, Value, binary, _Opts) ->
    <<(to_pg_days(Value)):32/signed>>;
encode(date, infinity, text, _Opts) ->
    ~"infinity";
encode(date, neg_infinity, text, _Opts) ->
    ~"-infinity";
encode(date, Value, text, _Opts) ->
    format_date(Value);
encode(time, Value, binary, _Opts) ->
    <<(to_day_micros(Value)):64/signed>>;
encode(time, Value, text, _Opts) ->
    format_time(to_day_micros(Value));
encode(Type, infinity, binary, _Opts) when Type =:= timestamp; Type =:= timestamptz ->
    <<?INT64_MAX:64/signed>>;
encode(Type, neg_infinity, binary, _Opts) when Type =:= timestamp; Type =:= timestamptz ->
    <<?INT64_MIN:64/signed>>;
encode(Type, Value, binary, _Opts) when Type =:= timestamp; Type =:= timestamptz ->
    <<(to_unix_micros(Type, Value) - ?MICROS_UNIX_TO_PG):64/signed>>;
encode(Type, infinity, text, _Opts) when Type =:= timestamp; Type =:= timestamptz ->
    ~"infinity";
encode(Type, neg_infinity, text, _Opts) when Type =:= timestamp; Type =:= timestamptz ->
    ~"-infinity";
encode(timestamp, Value, text, _Opts) ->
    format_timestamp(to_unix_micros(timestamp, Value));
encode(timestamptz, Value, text, _Opts) ->
    [format_timestamp(to_unix_micros(timestamptz, Value)), ~"+00"].

-doc "Decode `Format` wire bytes to a temporal value.".
-spec decode(
    date | time | timestamp | timestamptz, binary(), minato_codec:format(), minato_codec:opts()
) ->
    minato_codec:value().
decode(date, <<?INT32_MAX:32/signed>>, binary, _Opts) ->
    infinity;
decode(date, <<?INT32_MIN:32/signed>>, binary, _Opts) ->
    neg_infinity;
decode(date, <<Days:32/signed>>, binary, _Opts) ->
    civil_from_days(Days + ?DAYS_UNIX_TO_PG);
decode(date, ~"infinity", text, _Opts) ->
    infinity;
decode(date, ~"-infinity", text, _Opts) ->
    neg_infinity;
decode(date, Bin, text, _Opts) ->
    parse_date(Bin);
decode(time, <<Micros:64/signed>>, binary, Opts) ->
    day_micros_out(Micros, Opts);
decode(time, Bin, text, Opts) ->
    day_micros_out(parse_time(Bin), Opts);
decode(Type, <<?INT64_MAX:64/signed>>, binary, _Opts) when
    Type =:= timestamp; Type =:= timestamptz
->
    infinity;
decode(Type, <<?INT64_MIN:64/signed>>, binary, _Opts) when
    Type =:= timestamp; Type =:= timestamptz
->
    neg_infinity;
decode(Type, <<Micros:64/signed>>, binary, Opts) when Type =:= timestamp; Type =:= timestamptz ->
    unix_micros_out(Micros + ?MICROS_UNIX_TO_PG, Opts);
decode(Type, ~"infinity", text, _Opts) when Type =:= timestamp; Type =:= timestamptz ->
    infinity;
decode(Type, ~"-infinity", text, _Opts) when Type =:= timestamp; Type =:= timestamptz ->
    neg_infinity;
decode(Type, Bin, text, Opts) when Type =:= timestamp; Type =:= timestamptz ->
    unix_micros_out(parse_timestamp(Type, Bin), Opts);
decode(Type, Bin, Format, _Opts) ->
    minato_codec:bad(Type, {malformed, Format}, Bin).

-doc """
Days from 1970-01-01 for a proleptic Gregorian date, using astronomical year
numbering.

Exported because `m:minato_codec_datetime` owns the calendar arithmetic that
`date` and the timestamp types share.
""".
-spec days_from_civil(integer(), integer(), integer()) -> integer().
days_from_civil(Year, Month, Day) ->
    Y = Year - shift_year(Month),
    Era = era_of(Y),
    YearOfEra = Y - Era * 400,
    DayOfYear = (153 * (Month + month_offset(Month)) + 2) div 5 + Day - 1,
    DayOfEra = YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear,
    Era * 146097 + DayOfEra - 719468.

-doc "The proleptic Gregorian date that is the given number of days from 1970-01-01.".
-spec civil_from_days(integer()) -> {integer(), integer(), integer()}.
civil_from_days(Days) ->
    Z = Days + 719468,
    Era = era_of_days(Z),
    DayOfEra = Z - Era * 146097,
    YearOfEra =
        (DayOfEra - DayOfEra div 1460 + DayOfEra div 36524 - DayOfEra div 146096) div 365,
    DayOfYear = DayOfEra - (365 * YearOfEra + YearOfEra div 4 - YearOfEra div 100),
    Mp = (5 * DayOfYear + 2) div 153,
    Day = DayOfYear - (153 * Mp + 2) div 5 + 1,
    Month = Mp + month_from_mp(Mp),
    {YearOfEra + Era * 400 + shift_year(Month), Month, Day}.

-spec shift_year(integer()) -> 0 | 1.
shift_year(Month) when Month =< 2 -> 1;
shift_year(_) -> 0.

-spec month_offset(integer()) -> -3 | 9.
month_offset(Month) when Month > 2 -> -3;
month_offset(_) -> 9.

-spec month_from_mp(integer()) -> 3 | -9.
month_from_mp(Mp) when Mp < 10 -> 3;
month_from_mp(_) -> -9.

-spec era_of(integer()) -> integer().
era_of(Y) when Y >= 0 -> Y div 400;
era_of(Y) -> (Y - 399) div 400.

-spec era_of_days(integer()) -> integer().
era_of_days(Z) when Z >= 0 -> Z div 146097;
era_of_days(Z) -> (Z - 146096) div 146097.

-spec to_pg_days(term()) -> integer().
to_pg_days({Y, M, D}) when is_integer(Y), is_integer(M), is_integer(D) ->
    valid_date(Y, M, D),
    days_from_civil(Y, M, D) - ?DAYS_UNIX_TO_PG;
to_pg_days(Value) ->
    minato_codec:bad(date, not_a_date, Value).

-spec valid_date(integer(), integer(), integer()) -> ok.
valid_date(Y, M, D) when M >= 1, M =< 12, D >= 1 ->
    case D =< days_in_month(Y, M) of
        true -> ok;
        false -> minato_codec:bad(date, day_out_of_range, {Y, M, D})
    end;
valid_date(Y, M, D) ->
    minato_codec:bad(date, month_out_of_range, {Y, M, D}).

-spec days_in_month(integer(), integer()) -> integer().
days_in_month(Y, 2) ->
    case leap_year(Y) of
        true -> 29;
        false -> 28
    end;
days_in_month(_, M) when M =:= 4; M =:= 6; M =:= 9; M =:= 11 -> 30;
days_in_month(_, _) ->
    31.

-spec leap_year(integer()) -> boolean().
leap_year(Y) ->
    Y rem 4 =:= 0 andalso (Y rem 100 =/= 0 orelse Y rem 400 =:= 0).

-spec to_day_micros(term()) -> integer().
to_day_micros(Micros) when is_integer(Micros) ->
    Micros;
to_day_micros({H, Mi, S}) when is_integer(H), is_integer(Mi), is_integer(S) ->
    valid_time(H, Mi, S),
    ((H * 3600 + Mi * 60 + S) * 1000000);
to_day_micros(Value) ->
    minato_codec:bad(time, not_a_time, Value).

-spec valid_time(integer(), integer(), integer()) -> ok.
valid_time(H, Mi, S) when H >= 0, H =< 24, Mi >= 0, Mi =< 59, S >= 0, S =< 60 ->
    ok;
valid_time(H, Mi, S) ->
    minato_codec:bad(time, time_out_of_range, {H, Mi, S}).

-spec to_unix_micros(timestamp | timestamptz, term()) -> integer().
to_unix_micros(_Type, Micros) when is_integer(Micros) ->
    Micros;
to_unix_micros(_Type, {{Y, M, D}, {H, Mi, S}}) when
    is_integer(Y), is_integer(M), is_integer(D), is_integer(H), is_integer(Mi), is_integer(S)
->
    valid_date(Y, M, D),
    valid_time(H, Mi, S),
    days_from_civil(Y, M, D) * ?DAY_MICROS + (H * 3600 + Mi * 60 + S) * 1000000;
to_unix_micros(Type, Value) ->
    minato_codec:bad(Type, not_a_timestamp, Value).

-spec day_micros_out(integer(), minato_codec:opts()) ->
    integer() | {integer(), integer(), integer()}.
day_micros_out(Micros, #{datetime_format := microseconds}) ->
    Micros;
day_micros_out(Micros, _Opts) ->
    Secs = floor_div(Micros, 1000000),
    {Secs div 3600, (Secs rem 3600) div 60, Secs rem 60}.

-spec unix_micros_out(integer(), minato_codec:opts()) ->
    integer() | {{integer(), integer(), integer()}, {integer(), integer(), integer()}}.
unix_micros_out(Micros, #{datetime_format := microseconds}) ->
    Micros;
unix_micros_out(Micros, _Opts) ->
    Days = floor_div(Micros, ?DAY_MICROS),
    Secs = floor_div(Micros - Days * ?DAY_MICROS, 1000000),
    {civil_from_days(Days), {Secs div 3600, (Secs rem 3600) div 60, Secs rem 60}}.

-spec floor_div(integer(), pos_integer()) -> integer().
floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).

-spec format_date(term()) -> iodata().
format_date({Y, M, D}) when is_integer(Y), is_integer(M), is_integer(D) ->
    valid_date(Y, M, D),
    [pad(Y, 4), $-, pad(M, 2), $-, pad(D, 2)];
format_date(Value) ->
    minato_codec:bad(date, not_a_date, Value).

-spec format_time(integer()) -> iodata().
format_time(Micros) ->
    Secs = floor_div(Micros, 1000000),
    Frac = Micros - Secs * 1000000,
    [
        pad(Secs div 3600, 2),
        $:,
        pad((Secs rem 3600) div 60, 2),
        $:,
        pad(Secs rem 60, 2),
        format_fraction(Frac)
    ].

-spec format_timestamp(integer()) -> iodata().
format_timestamp(Micros) ->
    Days = floor_div(Micros, ?DAY_MICROS),
    [format_date(civil_from_days(Days)), $\s, format_time(Micros - Days * ?DAY_MICROS)].

-spec format_fraction(integer()) -> iodata().
format_fraction(0) ->
    [];
format_fraction(Frac) ->
    [$., trim_zeros(pad(Frac, 6))].

-spec trim_zeros(binary()) -> binary().
trim_zeros(Bin) ->
    case binary:last(Bin) of
        $0 -> trim_zeros(binary_part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

-spec pad(integer(), pos_integer()) -> binary().
pad(N, Width) when N < 0 ->
    <<$-, (pad(-N, Width))/binary>>;
pad(N, Width) ->
    Bin = integer_to_binary(N),
    case Width - byte_size(Bin) of
        Missing when Missing > 0 -> <<(binary:copy(~"0", Missing))/binary, Bin/binary>>;
        _ -> Bin
    end.

-spec parse_date(binary()) -> {integer(), integer(), integer()}.
parse_date(Bin) ->
    reject_bc(date, Bin),
    case binary:split(Bin, ~"-", [global]) of
        [Y, M, D] ->
            {Year, Month, Day} = {to_integer(date, Y), to_integer(date, M), to_integer(date, D)},
            valid_date(Year, Month, Day),
            {Year, Month, Day};
        _ ->
            minato_codec:bad(date, malformed_text, Bin)
    end.

-spec parse_time(binary()) -> integer().
parse_time(Bin) ->
    case binary:split(Bin, ~":", [global]) of
        [H, Mi, S] ->
            {Sec, Frac} = split_seconds(time, S),
            to_integer(time, H) * 3600000000 + to_integer(time, Mi) * 60000000 + Sec * 1000000 +
                Frac;
        _ ->
            minato_codec:bad(time, malformed_text, Bin)
    end.

-spec parse_timestamp(timestamp | timestamptz, binary()) -> integer().
parse_timestamp(Type, Bin) ->
    reject_bc(Type, Bin),
    case binary:split(Bin, ~" ") of
        [DatePart, TimePart] ->
            {Y, M, D} = parse_date(DatePart),
            {Clock, OffsetSecs} = split_offset(Type, TimePart),
            days_from_civil(Y, M, D) * ?DAY_MICROS + parse_time(Clock) -
                OffsetSecs * 1000000;
        _ ->
            minato_codec:bad(Type, malformed_text, Bin)
    end.

-spec split_offset(timestamp | timestamptz, binary()) -> {binary(), integer()}.
split_offset(timestamp, TimePart) ->
    {TimePart, 0};
split_offset(timestamptz, TimePart) ->
    case binary:match(TimePart, [~"+", ~"-"]) of
        nomatch ->
            {TimePart, 0};
        {Pos, 1} ->
            Clock = binary_part(TimePart, 0, Pos),
            Offset = binary_part(TimePart, Pos, byte_size(TimePart) - Pos),
            {Clock, parse_offset(Offset)}
    end.

-spec parse_offset(binary()) -> integer().
parse_offset(<<Sign, Rest/binary>>) ->
    Fields = [to_integer(timestamptz, F) || F <- binary:split(Rest, ~":", [global])],
    Secs = offset_seconds(Fields, Rest),
    case Sign of
        $- -> -Secs;
        _ -> Secs
    end.

-spec offset_seconds([integer()], binary()) -> integer().
offset_seconds([H], _Raw) -> H * 3600;
offset_seconds([H, M], _Raw) -> H * 3600 + M * 60;
offset_seconds([H, M, S], _Raw) -> H * 3600 + M * 60 + S;
offset_seconds(_Fields, Raw) -> minato_codec:bad(timestamptz, malformed_offset, Raw).

-spec split_seconds(atom(), binary()) -> {integer(), integer()}.
split_seconds(Type, Bin) ->
    case binary:split(Bin, ~".") of
        [Sec] ->
            {to_integer(Type, Sec), 0};
        [Sec, Frac] when byte_size(Frac) =< 6, Frac =/= ~"" ->
            Scaled = to_integer(Type, Frac) * pow10(6 - byte_size(Frac)),
            {to_integer(Type, Sec), Scaled};
        _ ->
            minato_codec:bad(Type, malformed_text, Bin)
    end.

-spec pow10(non_neg_integer()) -> pos_integer().
pow10(0) -> 1;
pow10(N) -> 10 * pow10(N - 1).

-spec reject_bc(atom(), binary()) -> ok.
reject_bc(Type, Bin) ->
    case binary:match(Bin, ~" BC") of
        nomatch -> ok;
        _ -> minato_codec:bad(Type, bc_dates_unsupported, Bin)
    end.

-spec to_integer(atom(), binary()) -> integer().
to_integer(Type, Bin) ->
    try
        binary_to_integer(Bin)
    catch
        error:badarg -> minato_codec:bad(Type, malformed_text, Bin)
    end.
