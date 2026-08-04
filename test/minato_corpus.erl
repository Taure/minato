-module(minato_corpus).
-moduledoc """
The differential corpus: every type minato has a codec for, a fixed table of
awkward values per type, and a deterministic generator.

A corpus case is a map of three things:

- `value`, the term handed to `minato_codec:encode/4`
- `expected`, the term a decode of the server's own bytes must produce, which
  differs from `value` only where PostgreSQL normalises on input
- `opts`, the decode options the case is judged under, because `uuid` and the
  temporal types have two Erlang representations each

Generation is seeded and therefore reproducible: the same seed and count give
the same values on every run, so a failure can be replayed exactly.

Every generated value stays inside the range PostgreSQL itself accepts, because
the differential suite sends each one to a real server. Values PostgreSQL
rejects outright (a NUL byte in `text`, a year outside 1..9999) belong in the
pure codec tests, not here.
""".

-export([types/0, sql_name/1, fixed/1, generate/3, element_entry/1, encoded/4]).

-doc "One type under test: what to call it in SQL and which OID carries it.".
-type entry() :: #{
    name := minato_oid:name() | {array, minato_oid:name()},
    oid := minato_oid:oid(),
    sql := binary(),
    kind := scalar | array
}.

-doc "One corpus case. See the module documentation.".
-type value_case() :: #{
    value := term(),
    expected := term(),
    opts := minato_codec:opts()
}.

-export_type([entry/0, value_case/0]).

-define(SEED_SALT, 20260804).

-doc "Every type under test: the 17 scalars and the array of each of them.".
-spec types() -> [entry()].
types() ->
    [scalar_entry(Name) || Name <- minato_oid:names()] ++
        [array_entry(Name) || Name <- minato_oid:names()].

-doc """
Encode a corpus value to wire bytes.

A corpus value is never NULL, because NULL is a length of -1 rather than bytes
and belongs to the protocol layer, so there are always bytes to compare.
""".
-spec encoded(minato_oid:oid(), term(), minato_codec:format(), minato_codec:opts()) -> binary().
encoded(Oid, Value, Format, Opts) ->
    case minato_codec:encode(Oid, Value, Format, Opts) of
        null -> error({unexpected_null, Oid, Value});
        IoData -> iolist_to_binary(IoData)
    end.

-doc "The scalar entry an array entry carries elements of.".
-spec element_entry(entry()) -> entry().
element_entry(#{kind := array, name := {array, Name}}) ->
    scalar_entry(Name).

-spec scalar_entry(minato_oid:name()) -> entry().
scalar_entry(Name) ->
    #{name => Name, oid => minato_oid:oid(Name), sql => sql_name(Name), kind => scalar}.

-spec array_entry(minato_oid:name()) -> entry().
array_entry(Name) ->
    #{
        name => {array, Name},
        oid => minato_oid:oid({array, Name}),
        sql => <<(sql_name(Name))/binary, "[]">>,
        kind => array
    }.

-doc "The SQL name of a scalar type.".
-spec sql_name(minato_oid:name()) -> binary().
sql_name(bool) -> ~"bool";
sql_name(bytea) -> ~"bytea";
sql_name(int2) -> ~"int2";
sql_name(int4) -> ~"int4";
sql_name(int8) -> ~"int8";
sql_name(float4) -> ~"float4";
sql_name(float8) -> ~"float8";
sql_name(numeric) -> ~"numeric";
sql_name(text) -> ~"text";
sql_name(varchar) -> ~"varchar";
sql_name(json) -> ~"json";
sql_name(jsonb) -> ~"jsonb";
sql_name(uuid) -> ~"uuid";
sql_name(date) -> ~"date";
sql_name(time) -> ~"time";
sql_name(timestamp) -> ~"timestamp";
sql_name(timestamptz) -> ~"timestamptz".

%%----------------------------------------------------------------------
%% The fixed table
%%----------------------------------------------------------------------

-doc """
The hand written awkward cases for a type.

These are the values that break codecs: the integer boundaries, negative and
fractional timestamps, `numeric` specials and large scales, `bytea` that is not
valid UTF-8, arrays holding NULL, and both Erlang representations of `uuid` and
of every temporal type.
""".
-spec fixed(entry()) -> [value_case()].
fixed(#{kind := scalar, name := Name}) when is_atom(Name) ->
    [as_case(Case) || Case <- scalar_cases(Name)];
fixed(#{kind := array, name := {array, Name}} = Entry) ->
    [as_case(Case) || Case <- array_cases(Name, Entry)].

-spec as_case(term()) -> value_case().
as_case(#{value := Value, expected := Expected, opts := Opts}) ->
    #{value => Value, expected => Expected, opts => as_opts(Opts)};
as_case({expect, Value, Expected}) ->
    #{value => Value, expected => Expected, opts => #{}};
as_case(Value) ->
    #{value => Value, expected => Value, opts => #{}}.

-spec as_opts(term()) -> minato_codec:opts().
as_opts(#{uuid_format := binary}) -> #{uuid_format => binary};
as_opts(#{datetime_format := microseconds}) -> #{datetime_format => microseconds};
as_opts(_Other) -> #{}.

-spec scalar_cases(minato_oid:name()) -> [term()].
scalar_cases(bool) ->
    [true, false];
scalar_cases(bytea) ->
    [
        ~"",
        <<0>>,
        <<0, 0, 0, 0>>,
        <<255, 254, 253>>,
        <<192, 128>>,
        <<"a", 0, "b">>,
        <<"\\x not hex">>,
        binary:copy(<<0, 255>>, 512)
    ];
scalar_cases(int2) ->
    [-32768, -1, 0, 1, 32767];
scalar_cases(int4) ->
    [-2147483648, -1, 0, 1, 2147483647];
scalar_cases(int8) ->
    [-9223372036854775808, -1, 0, 1, 9223372036854775807];
scalar_cases(float4) ->
    [0.0, 1.5, -1.5, 3.4028234663852886e38, -3.4028234663852886e38, nan, infinity, neg_infinity];
scalar_cases(float8) ->
    [
        0.0,
        1.5,
        -1.5,
        1.7976931348623157e308,
        -1.7976931348623157e308,
        2.2250738585072014e-308,
        nan,
        infinity,
        neg_infinity
    ];
scalar_cases(numeric) ->
    [
        ~"0",
        {expect, ~"-0", ~"0"},
        {expect, ~"000123", ~"123"},
        ~"0.0",
        ~"123.4500",
        ~"-123.4500",
        {expect, ~"1e5", ~"100000"},
        {expect, ~"1.5e-4", ~"0.00015"},
        {expect, 123, ~"123"},
        {expect, -1, ~"-1"},
        ~"12345678901234567890.12345678901234567890",
        ~"-12345678901234567890.12345678901234567890",
        ~"0.00000000000000000001",
        nan,
        infinity,
        neg_infinity
    ];
scalar_cases(Name) when Name =:= text; Name =:= varchar ->
    [
        ~"",
        ~"hello",
        ~"日本語 🎌",
        ~"quote\" back\\slash",
        ~"NULL",
        ~"{brace},comma",
        ~" leading and trailing ",
        ~"line\nfeed\ttab"
    ];
scalar_cases(json) ->
    [~"null", ~"{}", ~"[]", ~"{\"a\":1}", ~"{\"u\":\"日本語 🎌\"}", ~"[1,{\"b\":[true,null]}]"];
scalar_cases(jsonb) ->
    [
        ~"null",
        ~"{}",
        ~"[]",
        {expect, ~"{\"a\":1}", ~"{\"a\": 1}"},
        {expect, ~"{\"b\":2,\"a\":1}", ~"{\"a\": 1, \"b\": 2}"},
        {expect, ~"{\"u\":\"日本語 🎌\"}", ~"{\"u\": \"日本語 🎌\"}"},
        {expect, ~"{\"a\":{\"b\":[1,null,true]}}", ~"{\"a\": {\"b\": [1, null, true]}}"},
        {expect, ~"{\"n\":1.50}", ~"{\"n\": 1.50}"}
    ];
scalar_cases(uuid) ->
    [
        ~"00000000-0000-0000-0000-000000000000",
        ~"ffffffff-ffff-ffff-ffff-ffffffffffff",
        ~"0196f0a9-1c4f-7e21-9b3a-6d2c5e8f1a44",
        {expect, ~"0196F0A9-1C4F-7E21-9B3A-6D2C5E8F1A44", ~"0196f0a9-1c4f-7e21-9b3a-6d2c5e8f1a44"},
        {expect, ~"0196f0a91c4f7e219b3a6d2c5e8f1a44", ~"0196f0a9-1c4f-7e21-9b3a-6d2c5e8f1a44"},
        #{
            value => <<1, 150, 240, 169, 28, 79, 126, 33, 155, 58, 109, 44, 94, 143, 26, 68>>,
            expected => <<1, 150, 240, 169, 28, 79, 126, 33, 155, 58, 109, 44, 94, 143, 26, 68>>,
            opts => #{uuid_format => binary}
        }
    ];
scalar_cases(date) ->
    [
        {2000, 1, 1},
        {1970, 1, 1},
        {1900, 1, 1},
        {1, 1, 1},
        {9999, 12, 31},
        {2000, 2, 29},
        {1999, 12, 31},
        infinity,
        neg_infinity
    ];
scalar_cases(time) ->
    [
        {0, 0, 0},
        {12, 0, 0},
        {23, 59, 59},
        {24, 0, 0},
        micros(0),
        micros(1),
        micros(3723000004),
        micros(86399999999)
    ];
scalar_cases(Name) when Name =:= timestamp; Name =:= timestamptz ->
    [
        {{2000, 1, 1}, {0, 0, 0}},
        {{1999, 12, 31}, {23, 59, 59}},
        {{1970, 1, 1}, {0, 0, 0}},
        {{1900, 5, 6}, {7, 8, 9}},
        {{2038, 1, 19}, {3, 14, 7}},
        {{9999, 12, 31}, {23, 59, 59}},
        {{1, 1, 1}, {0, 0, 0}},
        micros(-500000),
        micros(0),
        micros(946684799500000),
        micros(1),
        infinity,
        neg_infinity
    ].

-spec micros(integer()) -> value_case().
micros(Micros) ->
    #{value => Micros, expected => Micros, opts => #{datetime_format => microseconds}}.

-spec array_cases(minato_oid:name(), entry()) -> [term()].
array_cases(Name, Entry) ->
    Scalars = [as_case(Case) || Case <- scalar_cases(Name)],
    Comparable = [Case || Case <- Scalars, maps:get(opts, Case) =:= #{}],
    Values = [maps:get(value, Case) || Case <- Comparable],
    Expected = [maps:get(expected, Case) || Case <- Comparable],
    Head = hd(Values),
    HeadExpected = hd(Expected),
    [
        #{value => [], expected => [], opts => #{}},
        #{value => [null], expected => [null], opts => #{}},
        #{value => [null, null, null], expected => [null, null, null], opts => #{}},
        #{value => [Head], expected => [HeadExpected], opts => #{}},
        #{value => [Head, null], expected => [HeadExpected, null], opts => #{}},
        #{value => [null, Head], expected => [null, HeadExpected], opts => #{}},
        #{value => Values, expected => Expected, opts => #{}}
        | element_representation_cases(Name, Entry)
    ].

-spec element_representation_cases(minato_oid:name(), entry()) -> [value_case()].
element_representation_cases(uuid, _Entry) ->
    Raw = <<1, 150, 240, 169, 28, 79, 126, 33, 155, 58, 109, 44, 94, 143, 26, 68>>,
    [#{value => [Raw, null], expected => [Raw, null], opts => #{uuid_format => binary}}];
element_representation_cases(Name, _Entry) when
    Name =:= time; Name =:= timestamp; Name =:= timestamptz
->
    [
        #{
            value => [0, 1, null],
            expected => [0, 1, null],
            opts => #{datetime_format => microseconds}
        }
    ];
element_representation_cases(_Name, _Entry) ->
    [].

%%----------------------------------------------------------------------
%% Generation
%%----------------------------------------------------------------------

-doc """
`Count` deterministic cases for a type.

The same `Seed` and `Count` give the same values every run. Seeding is per type
as well as per run, so adding a type does not shift the values of any other.
""".
-spec generate(entry(), non_neg_integer(), integer()) -> [value_case()].
generate(Entry, Count, Seed) ->
    #{name := Name} = Entry,
    State = rand:seed_s(exsss, {Seed, erlang:phash2(Name), ?SEED_SALT}),
    build(Count, Entry, State, []).

-spec build(non_neg_integer(), entry(), rand:state(), [value_case()]) -> [value_case()].
build(0, _Entry, _State, Acc) ->
    Acc;
build(N, Entry, State, Acc) ->
    {Value, Next} = gen_entry(Entry, State),
    build(N - 1, Entry, Next, [#{value => Value, expected => Value, opts => #{}} | Acc]).

-spec gen_entry(entry(), rand:state()) -> {term(), rand:state()}.
gen_entry(#{kind := scalar, name := Name}, State) when is_atom(Name) ->
    gen(Name, State);
gen_entry(#{kind := array, name := {array, Name}}, State) ->
    {Length, S1} = pick(9, State),
    gen_elements(Length - 1, Name, S1, []).

-spec gen_elements(non_neg_integer(), minato_oid:name(), rand:state(), [term()]) ->
    {[term()], rand:state()}.
gen_elements(0, _Name, State, Acc) ->
    {Acc, State};
gen_elements(N, Name, State, Acc) ->
    {Roll, S1} = pick(8, State),
    case Roll of
        1 ->
            gen_elements(N - 1, Name, S1, [null | Acc]);
        _ ->
            {Value, S2} = gen(Name, S1),
            gen_elements(N - 1, Name, S2, [Value | Acc])
    end.

-spec gen(minato_oid:name(), rand:state()) -> {term(), rand:state()}.
gen(bool, State) ->
    {Roll, S1} = pick(2, State),
    {Roll =:= 1, S1};
gen(int2, State) ->
    gen_integer(-32768, 32767, State);
gen(int4, State) ->
    gen_integer(-2147483648, 2147483647, State);
gen(int8, State) ->
    gen_integer(-9223372036854775808, 9223372036854775807, State);
gen(bytea, State) ->
    {Length, S1} = pick(33, State),
    gen_bytes(Length - 1, S1, ~"");
gen(float4, State) ->
    {Value, S1} = gen_float(State),
    {narrow_to_float4(Value), S1};
gen(float8, State) ->
    gen_float(State);
gen(numeric, State) ->
    gen_numeric(State);
gen(Name, State) when Name =:= text; Name =:= varchar ->
    {Length, S1} = pick(21, State),
    gen_string(Length - 1, S1, ~"");
gen(Name, State) when Name =:= json; Name =:= jsonb ->
    gen_json(2, State);
gen(uuid, State) ->
    {Raw, S1} = gen_bytes(16, State, ~""),
    {uuid_string(Raw), S1};
gen(date, State) ->
    {Days, S1} = gen_integer(-719162, 2932896, State),
    {minato_codec_datetime:civil_from_days(Days), S1};
gen(time, State) ->
    {Seconds, S1} = gen_integer(0, 86399, State),
    {{Seconds div 3600, (Seconds rem 3600) div 60, Seconds rem 60}, S1};
gen(Name, State) when Name =:= timestamp; Name =:= timestamptz ->
    {Days, S1} = gen_integer(-719162, 2932896, State),
    {Seconds, S2} = gen_integer(0, 86399, S1),
    Date = minato_codec_datetime:civil_from_days(Days),
    {{Date, {Seconds div 3600, (Seconds rem 3600) div 60, Seconds rem 60}}, S2}.

-spec gen_integer(integer(), integer(), rand:state()) -> {integer(), rand:state()}.
gen_integer(Min, Max, State) ->
    {Roll, S1} = pick(10, State),
    case boundary(Roll, Min, Max) of
        Value when is_integer(Value), Value >= Min, Value =< Max -> {Value, S1};
        _ -> uniform_between(Min, Max, S1)
    end.

-spec boundary(pos_integer(), integer(), integer()) -> integer() | none.
boundary(1, Min, _Max) -> Min;
boundary(2, _Min, Max) -> Max;
boundary(3, _Min, _Max) -> 0;
boundary(4, _Min, _Max) -> -1;
boundary(5, _Min, _Max) -> 1;
boundary(_Roll, _Min, _Max) -> none.

-spec uniform_between(integer(), integer(), rand:state()) -> {integer(), rand:state()}.
uniform_between(Min, Max, State) ->
    {Offset, S1} = pick(Max - Min + 1, State),
    {Min + Offset - 1, S1}.

-spec gen_bytes(non_neg_integer(), rand:state(), binary()) -> {binary(), rand:state()}.
gen_bytes(0, State, Acc) ->
    {Acc, State};
gen_bytes(N, State, Acc) ->
    {Byte, S1} = pick(256, State),
    gen_bytes(N - 1, S1, <<Acc/binary, (Byte - 1)>>).

-spec uuid_string(binary()) -> binary().
uuid_string(<<A:4/binary, B:2/binary, C:2/binary, D:2/binary, E:6/binary>>) ->
    Hex = fun(Part) -> binary:encode_hex(Part, lowercase) end,
    <<
        (Hex(A))/binary,
        $-,
        (Hex(B))/binary,
        $-,
        (Hex(C))/binary,
        $-,
        (Hex(D))/binary,
        $-,
        (Hex(E))/binary
    >>.

-spec gen_string(non_neg_integer(), rand:state(), binary()) -> {binary(), rand:state()}.
gen_string(0, State, Acc) ->
    {Acc, State};
gen_string(N, State, Acc) ->
    Alphabet = alphabet(),
    {Index, S1} = pick(count(Alphabet), State),
    Code = at(Alphabet, Index),
    gen_string(N - 1, S1, <<Acc/binary, Code/utf8>>).

-spec count([term(), ...]) -> pos_integer().
count([_Head | Rest]) -> 1 + length(Rest).

-spec at([T, ...], pos_integer()) -> T.
at([Head | _Rest], 1) -> Head;
at([_Head | Rest], Index) -> at(Rest, Index - 1).

-spec alphabet() -> [char(), ...].
alphabet() ->
    lists:seq($\s, $~) ++
        [$\t, $\n, $\r] ++
        lists:seq(16#00A1, 16#00BF) ++
        lists:seq(16#3042, 16#3053) ++
        lists:seq(16#4E00, 16#4E0F) ++
        lists:seq(16#1F600, 16#1F60F).

-spec gen_float(rand:state()) -> {float() | nan | infinity | neg_infinity, rand:state()}.
gen_float(State) ->
    {Roll, S1} = pick(20, State),
    case Roll of
        1 -> {nan, S1};
        2 -> {infinity, S1};
        3 -> {neg_infinity, S1};
        4 -> {0.0, S1};
        _ -> gen_finite_float(S1)
    end.

-spec gen_finite_float(rand:state()) -> {float(), rand:state()}.
gen_finite_float(State) ->
    {Mantissa, S1} = uniform_between(-1000000, 1000000, State),
    {Exponent, S2} = uniform_between(-20, 20, S1),
    {Mantissa * math:pow(10, Exponent), S2}.

-spec narrow_to_float4(float() | nan | infinity | neg_infinity) ->
    float() | nan | infinity | neg_infinity.
narrow_to_float4(Value) when is_float(Value) ->
    case <<Value:32/float>> of
        <<Narrowed:32/float>> -> Narrowed
    end;
narrow_to_float4(Value) ->
    Value.

-spec gen_numeric(rand:state()) -> {binary() | nan | infinity | neg_infinity, rand:state()}.
gen_numeric(State) ->
    {Roll, S1} = pick(25, State),
    case Roll of
        1 -> {nan, S1};
        2 -> {infinity, S1};
        3 -> {neg_infinity, S1};
        _ -> gen_decimal(S1)
    end.

-spec gen_decimal(rand:state()) -> {binary(), rand:state()}.
gen_decimal(State) ->
    {IntLength, S1} = pick(30, State),
    {FracLength, S2} = pick(21, S1),
    {IntPart, S3} = gen_leading_digits(IntLength, S2),
    {FracPart, S4} = gen_digits(FracLength - 1, S3, ~""),
    {Sign, S5} = pick(2, S4),
    {decimal(Sign =:= 1, IntPart, FracPart), S5}.

-spec decimal(boolean(), binary(), binary()) -> binary().
decimal(Negative, IntPart, FracPart) ->
    Body = decimal_body(IntPart, FracPart),
    case Negative andalso not is_zero(Body) of
        true -> <<$-, Body/binary>>;
        false -> Body
    end.

-spec decimal_body(binary(), binary()) -> binary().
decimal_body(IntPart, ~"") -> IntPart;
decimal_body(IntPart, FracPart) -> <<IntPart/binary, $., FracPart/binary>>.

-spec is_zero(binary()) -> boolean().
is_zero(Bin) ->
    Stripped = binary:replace(binary:replace(Bin, ~".", ~"", [global]), ~"0", ~"", [global]),
    Stripped =:= ~"".

-spec gen_leading_digits(pos_integer(), rand:state()) -> {binary(), rand:state()}.
gen_leading_digits(1, State) ->
    gen_digits(1, State, ~"");
gen_leading_digits(Length, State) ->
    {First, S1} = pick(9, State),
    gen_digits(Length - 1, S1, <<($0 + First)>>).

-spec gen_digits(non_neg_integer(), rand:state(), binary()) -> {binary(), rand:state()}.
gen_digits(0, State, Acc) ->
    {Acc, State};
gen_digits(N, State, Acc) ->
    {Digit, S1} = pick(10, State),
    gen_digits(N - 1, S1, <<Acc/binary, ($0 + Digit - 1)>>).

-spec gen_json(non_neg_integer(), rand:state()) -> {binary(), rand:state()}.
gen_json(0, State) ->
    gen_json_scalar(State);
gen_json(Depth, State) ->
    {Roll, S1} = pick(6, State),
    case Roll of
        1 -> gen_json_array(Depth, S1);
        2 -> gen_json_object(Depth, S1);
        _ -> gen_json_scalar(S1)
    end.

-spec gen_json_array(non_neg_integer(), rand:state()) -> {binary(), rand:state()}.
gen_json_array(Depth, State) ->
    {Length, S1} = pick(4, State),
    {Items, S2} = gen_json_items(Length - 1, Depth - 1, S1, []),
    {<<$[, (join(Items, ~", "))/binary, $]>>, S2}.

-spec gen_json_object(non_neg_integer(), rand:state()) -> {binary(), rand:state()}.
gen_json_object(Depth, State) ->
    {Value, S1} = gen_json(Depth - 1, State),
    {Key, S2} = pick(3, S1),
    Name = at([~"a", ~"b", ~"c"], Key),
    {<<"{\"", Name/binary, "\": ", Value/binary, "}">>, S2}.

-spec gen_json_items(non_neg_integer(), non_neg_integer(), rand:state(), [binary()]) ->
    {[binary()], rand:state()}.
gen_json_items(0, _Depth, State, Acc) ->
    {Acc, State};
gen_json_items(N, Depth, State, Acc) ->
    {Item, S1} = gen_json(Depth, State),
    gen_json_items(N - 1, Depth, S1, [Item | Acc]).

-spec gen_json_scalar(rand:state()) -> {binary(), rand:state()}.
gen_json_scalar(State) ->
    {Roll, S1} = pick(6, State),
    case Roll of
        1 ->
            {~"null", S1};
        2 ->
            {~"true", S1};
        3 ->
            {~"false", S1};
        4 ->
            {Number, S2} = uniform_between(-999, 999, S1),
            {integer_to_binary(Number), S2};
        5 ->
            {Number, S2} = uniform_between(0, 9999, S1),
            {<<(integer_to_binary(Number))/binary, ".50">>, S2};
        _ ->
            {Index, S2} = pick(4, S1),
            {at([~"\"x\"", ~"\"日本語\"", ~"\"🎌\"", ~"\"a b\""], Index), S2}
    end.

-spec join([binary()], binary()) -> binary().
join([], _Separator) -> ~"";
join([Only], _Separator) -> Only;
join([Head | Rest], Separator) -> <<Head/binary, Separator/binary, (join(Rest, Separator))/binary>>.

-spec pick(pos_integer(), rand:state()) -> {pos_integer(), rand:state()}.
pick(N, State) ->
    rand:uniform_s(N, State).
