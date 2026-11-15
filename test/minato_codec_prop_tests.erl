-module(minato_codec_prop_tests).
-moduledoc """
Round-trip properties: for every type, encode a generated value and decode it
back in both wire formats, and assert the term that comes out is the term that
went in.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

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
    forall(gen_nullable(gen_for(Name)), fun(Value) ->
        Value =:= minato_codec:decode(Oid, wire(Oid, Value, Format, Opts), Format, Opts)
    end).

prop_array_roundtrip(Name, Format) ->
    Oid = minato_oid:oid({array, Name}),
    Opts = opts(Name),
    forall(list(gen_nullable(gen_for(Name))), fun(Values) ->
        Values =:= minato_codec:decode(Oid, wire(Oid, Values, Format, Opts), Format, Opts)
    end).

prop_days_match_calendar() ->
    forall(gen_date(), fun({Y, M, D}) ->
        calendar:date_to_gregorian_days({Y, M, D}) - 719528 =:=
            minato_codec_datetime:days_from_civil(Y, M, D)
    end).

prop_days_invert() ->
    forall(integer(-3000000, 3000000), fun(Days) ->
        {Y, M, D} = minato_codec_datetime:civil_from_days(Days),
        Days =:= minato_codec_datetime:days_from_civil(Y, M, D)
    end).

prop_numeric_keeps_scale() ->
    forall(gen_decimal(), fun(Decimal) ->
        Wire = wire(1700, Decimal, binary, #{}),
        Decimal =:= minato_codec:decode(1700, Wire, binary)
    end).

prop_unknown_oid_text_passthrough() ->
    forall(binary(), fun(Bin) ->
        Bin =:= minato_codec:decode(600, wire(600, Bin, text, #{}), text)
    end).

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
        {8, from(integer(-1000000000, 1000000000), fun(I) -> I / 1000.0 end)},
        {1, oneof([0.0, 1.0, -1.0])},
        {1, oneof([nan, infinity, neg_infinity])}
    ]).

gen_float4() ->
    from(gen_float(), fun narrow/1).

narrow(Value) when is_float(Value) ->
    <<Narrowed:32/float>> = <<Value:32/float>>,
    Narrowed;
narrow(Value) ->
    Value.

gen_decimal() ->
    from({boolean(), gen_digits(1, 20), gen_digits(0, 12)}, fun({Negative, Integral, Fractional}) ->
        canonical(Negative, Integral, Fractional)
    end).

gen_digits(Min, Max) ->
    from(from(integer(Min, Max), fun(Count) -> vector(Count, integer($0, $9)) end), fun(Digits) ->
        list_to_binary(Digits)
    end).

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
