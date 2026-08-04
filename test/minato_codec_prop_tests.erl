-module(minato_codec_prop_tests).
-moduledoc """
Round-trip properties: for every type, encode a generated value and decode it
back in both wire formats, and assert the term that comes out is the term that
went in.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% eqWAlizer: the PropEr macros expand to term(), so the functions that use them
%% cannot be given a useful type.
-eqwalizer({nowarn_function, prop_days_match_calendar/0}).
-eqwalizer({nowarn_function, prop_days_invert/0}).
-eqwalizer({nowarn_function, gen_float/0}).
-eqwalizer({nowarn_function, gen_digits/2}).

-define(NUMTESTS, 300).

property_test_() ->
    {timeout, 300, [
        {name(Name, Format), fun() -> check(prop_roundtrip(Name, Format)) end}
     || Name <- minato_oid:names(), Format <- [binary, text]
    ]}.

array_property_test_() ->
    {timeout, 300, [
        {"array of " ++ name(Name, Format), fun() -> check(prop_array_roundtrip(Name, Format)) end}
     || Name <- minato_oid:names(), Format <- [binary, text]
    ]}.

calendar_property_test_() ->
    {timeout, 120, [
        {"days_from_civil agrees with calendar", fun() -> check(prop_days_match_calendar()) end},
        {"civil_from_days inverts days_from_civil", fun() -> check(prop_days_invert()) end}
    ]}.

numeric_property_test_() ->
    {timeout, 120, [
        {"numeric keeps its display scale", fun() -> check(prop_numeric_keeps_scale()) end}
    ]}.

unknown_oid_property_test_() ->
    {timeout, 120, [
        {"an unknown OID passes text through", fun() ->
            check(prop_unknown_oid_text_passthrough())
        end}
    ]}.

name(Name, Format) ->
    atom_to_list(Name) ++ " " ++ atom_to_list(Format).

check(Prop) ->
    ?assert(proper:quickcheck(Prop, [?NUMTESTS, {to_file, user}])).

%%----------------------------------------------------------------------
%% Properties
%%----------------------------------------------------------------------

prop_roundtrip(Name, Format) ->
    Oid = minato_oid:oid(Name),
    Opts = opts(Name),
    ?FORALL(
        Value,
        gen_nullable(gen_for(Name)),
        Value =:= minato_codec:decode(Oid, wire(Oid, Value, Format, Opts), Format, Opts)
    ).

prop_array_roundtrip(Name, Format) ->
    Oid = minato_oid:oid({array, Name}),
    Opts = opts(Name),
    ?FORALL(
        Values,
        list(gen_nullable(gen_for(Name))),
        Values =:= minato_codec:decode(Oid, wire(Oid, Values, Format, Opts), Format, Opts)
    ).

prop_days_match_calendar() ->
    ?FORALL(
        {Y, M, D},
        gen_date(),
        calendar:date_to_gregorian_days({Y, M, D}) - 719528 =:=
            minato_codec_datetime:days_from_civil(Y, M, D)
    ).

prop_days_invert() ->
    ?FORALL(
        Days,
        integer(-3000000, 3000000),
        begin
            {Y, M, D} = minato_codec_datetime:civil_from_days(Days),
            Days =:= minato_codec_datetime:days_from_civil(Y, M, D)
        end
    ).

prop_numeric_keeps_scale() ->
    ?FORALL(
        Decimal,
        gen_decimal(),
        begin
            Wire = wire(1700, Decimal, binary, #{}),
            Decimal =:= minato_codec:decode(1700, Wire, binary)
        end
    ).

prop_unknown_oid_text_passthrough() ->
    ?FORALL(
        Bin,
        binary(),
        Bin =:= minato_codec:decode(600, wire(600, Bin, text, #{}), text)
    ).

%%----------------------------------------------------------------------
%% Generators
%%----------------------------------------------------------------------

gen_nullable(Gen) ->
    frequency([{1, null}, {9, Gen}]).

gen_for(bool) -> boolean();
gen_for(bytea) -> binary();
gen_for(int2) -> integer(-32768, 32767);
gen_for(int4) -> integer(-2147483648, 2147483647);
gen_for(int8) -> integer(-9223372036854775808, 9223372036854775807);
gen_for(float4) -> gen_float4();
gen_for(float8) -> gen_float();
gen_for(numeric) -> gen_decimal();
gen_for(text) -> binary();
gen_for(varchar) -> binary();
gen_for(json) -> binary();
gen_for(jsonb) -> binary();
gen_for(uuid) -> gen_uuid();
gen_for(date) -> gen_date();
gen_for(time) -> gen_time();
gen_for(timestamp) -> gen_datetime();
gen_for(timestamptz) -> gen_datetime().

opts(uuid) -> #{uuid_format => binary};
opts(_Name) -> #{}.

gen_uuid() ->
    binary(16).

gen_date() ->
    {integer(1, 9999), integer(1, 12), integer(1, 28)}.

gen_time() ->
    {integer(0, 23), integer(0, 59), integer(0, 59)}.

gen_datetime() ->
    {gen_date(), gen_time()}.

gen_float() ->
    frequency([
        {8, ?LET(I, integer(-1000000000, 1000000000), I / 1000.0)},
        {1, oneof([0.0, 1.0, -1.0])},
        {1, oneof([nan, infinity, neg_infinity])}
    ]).

gen_float4() ->
    ?LET(Value, gen_float(), narrow(Value)).

narrow(Value) when is_float(Value) ->
    <<Narrowed:32/float>> = <<Value:32/float>>,
    Narrowed;
narrow(Value) ->
    Value.

gen_decimal() ->
    ?LET(
        {Negative, Integral, Fractional},
        {boolean(), gen_digits(1, 20), gen_digits(0, 12)},
        canonical(Negative, Integral, Fractional)
    ).

gen_digits(Min, Max) ->
    ?LET(
        Digits,
        ?LET(Count, integer(Min, Max), vector(Count, integer($0, $9))),
        list_to_binary(Digits)
    ).

canonical(Negative, Integral, Fractional) ->
    Trimmed = strip_leading_zeros(Integral),
    Body = join_point(Trimmed, Fractional),
    case Negative andalso not is_zero(Trimmed, Fractional) of
        true -> <<$-, Body/binary>>;
        false -> Body
    end.

join_point(Integral, ~"") -> Integral;
join_point(Integral, Fractional) -> <<Integral/binary, $., Fractional/binary>>.

strip_leading_zeros(<<$0, Rest/binary>>) when Rest =/= ~"" -> strip_leading_zeros(Rest);
strip_leading_zeros(Bin) -> Bin.

is_zero(Integral, Fractional) ->
    Both = <<Integral/binary, Fractional/binary>>,
    binary:copy(~"0", byte_size(Both)) =:= Both.

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

wire(Oid, Value, Format, Opts) ->
    case minato_codec:encode(Oid, Value, Format, Opts) of
        null -> null;
        IoData -> iolist_to_binary(IoData)
    end.
