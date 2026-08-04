-module(minato_codec_scalar_tests).

-include_lib("eunit/include/eunit.hrl").

-define(UUID_STRING, ~"0196f0a9-1c4f-7e21-9b3a-6d2c5e8f1a44").
-define(UUID_RAW,
    <<16#01, 16#96, 16#f0, 16#a9, 16#1c, 16#4f, 16#7e, 16#21, 16#9b, 16#3a, 16#6d, 16#2c, 16#5e,
        16#8f, 16#1a, 16#44>>
).

enc(Oid, Value, Format) ->
    wire(minato_codec:encode(Oid, Value, Format)).

enc(Oid, Value, Format, Opts) ->
    wire(minato_codec:encode(Oid, Value, Format, Opts)).

%%----------------------------------------------------------------------
%% NULL
%%----------------------------------------------------------------------

null_is_the_sentinel_in_both_directions_test_() ->
    Oids = [16, 17, 20, 23, 25, 1043, 1184, 2950, 3802, 1009, 1016, 1700, 700],
    [
        {integer_to_list(Oid), [
            ?_assertEqual(null, minato_codec:encode(Oid, null, binary)),
            ?_assertEqual(null, minato_codec:encode(Oid, null, text)),
            ?_assertEqual(null, minato_codec:decode(Oid, null, binary)),
            ?_assertEqual(null, minato_codec:decode(Oid, null, text))
        ]}
     || Oid <- Oids
    ].

%%----------------------------------------------------------------------
%% bool
%%----------------------------------------------------------------------

bool_test_() ->
    [
        ?_assertEqual(<<1>>, enc(16, true, binary)),
        ?_assertEqual(<<0>>, enc(16, false, binary)),
        ?_assertEqual(~"t", enc(16, true, text)),
        ?_assertEqual(~"f", enc(16, false, text)),
        ?_assertEqual(true, minato_codec:decode(16, <<1>>, binary)),
        ?_assertEqual(false, minato_codec:decode(16, <<0>>, binary)),
        ?_assertEqual(true, minato_codec:decode(16, ~"t", text)),
        ?_assertEqual(false, minato_codec:decode(16, ~"f", text)),
        ?_assertEqual(true, minato_codec:decode(16, ~"true", text)),
        ?_assertEqual(false, minato_codec:decode(16, ~"false", text))
    ].

bool_rejects_test_() ->
    [
        ?_assertError({minato_codec, #{reason := not_a_boolean}}, enc(16, 1, binary)),
        ?_assertError(
            {minato_codec, #{reason := {malformed, binary}}}, minato_codec:decode(16, <<2>>, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := {malformed, text}}}, minato_codec:decode(16, ~"maybe", text)
        )
    ].

%%----------------------------------------------------------------------
%% bytea
%%----------------------------------------------------------------------

bytea_test_() ->
    [
        ?_assertEqual(~"", enc(17, ~"", binary)),
        ?_assertEqual(<<0, 255, 128>>, enc(17, <<0, 255, 128>>, binary)),
        ?_assertEqual(~"\\x00ff80", enc(17, <<0, 255, 128>>, text)),
        ?_assertEqual(~"\\x", enc(17, ~"", text)),
        ?_assertEqual(<<0, 255, 128>>, minato_codec:decode(17, ~"\\x00ff80", text)),
        ?_assertEqual(<<0, 255, 128>>, minato_codec:decode(17, ~"\\x00FF80", text)),
        ?_assertEqual(~"", minato_codec:decode(17, ~"\\x", text)),
        ?_assertEqual(~"", minato_codec:decode(17, ~"", binary))
    ].

bytea_carries_bytes_that_are_not_utf8_test_() ->
    Invalid = <<16#ff, 16#fe, 16#c3, 16#28, 16#a0, 16#a1>>,
    ?assertNot(is_binary(unicode:characters_to_binary(Invalid, utf8))),
    [
        ?_assertEqual(Invalid, minato_codec:decode(17, enc(17, Invalid, binary), binary)),
        ?_assertEqual(Invalid, minato_codec:decode(17, enc(17, Invalid, text), text))
    ].

bytea_escape_format_is_accepted_test_() ->
    [
        ?_assertEqual(<<$a, $\\, $b>>, minato_codec:decode(17, <<$a, $\\, $\\, $b>>, text)),
        ?_assertEqual(<<0, $a>>, minato_codec:decode(17, <<$\\, $0, $0, $0, $a>>, text)),
        ?_assertEqual(<<1>>, minato_codec:decode(17, <<$\\, $0, $0, $1>>, text)),
        ?_assertEqual(~"plain", minato_codec:decode(17, ~"plain", text))
    ].

bytea_accepts_iodata_test_() ->
    ?_assertEqual(~"abc", enc(17, [$a, [~"b"], "c"], binary)).

%%----------------------------------------------------------------------
%% integers
%%----------------------------------------------------------------------

integer_boundaries_test_() ->
    Cases = [
        {21, -32768, <<16#80, 16#00>>},
        {21, 32767, <<16#7f, 16#ff>>},
        {23, -2147483648, <<16#80, 0, 0, 0>>},
        {23, 2147483647, <<16#7f, 16#ff, 16#ff, 16#ff>>},
        {20, -9223372036854775808, <<16#80, 0, 0, 0, 0, 0, 0, 0>>},
        {20, 9223372036854775807, <<16#7f, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff>>}
    ],
    [
        {lists:flatten(io_lib:format("~p ~p", [Oid, Value])), [
            ?_assertEqual(Wire, enc(Oid, Value, binary)),
            ?_assertEqual(Value, minato_codec:decode(Oid, Wire, binary)),
            ?_assertEqual(integer_to_binary(Value), enc(Oid, Value, text)),
            ?_assertEqual(Value, minato_codec:decode(Oid, integer_to_binary(Value), text))
        ]}
     || {Oid, Value, Wire} <- Cases
    ].

integer_out_of_range_test_() ->
    [
        ?_assertError({minato_codec, #{reason := out_of_range}}, enc(21, 32768, binary)),
        ?_assertError({minato_codec, #{reason := out_of_range}}, enc(21, -32769, binary)),
        ?_assertError({minato_codec, #{reason := out_of_range}}, enc(23, 2147483648, binary)),
        ?_assertError(
            {minato_codec, #{reason := out_of_range}}, enc(20, 9223372036854775808, binary)
        ),
        ?_assertError({minato_codec, #{reason := out_of_range}}, enc(21, 32768, text)),
        ?_assertError({minato_codec, #{reason := not_an_integer}}, enc(23, 1.0, binary)),
        ?_assertError(
            {minato_codec, #{reason := malformed_text}}, minato_codec:decode(23, ~"x", text)
        )
    ].

%%----------------------------------------------------------------------
%% floats
%%----------------------------------------------------------------------

float_test_() ->
    [
        ?_assertEqual(1.5, minato_codec:decode(701, enc(701, 1.5, binary), binary)),
        ?_assertEqual(1.5, minato_codec:decode(700, enc(700, 1.5, binary), binary)),
        ?_assertEqual(1.5, minato_codec:decode(701, enc(701, 1.5, text), text)),
        ?_assertEqual(0.0, minato_codec:decode(701, enc(701, 0.0, binary), binary)),
        ?_assertEqual(2.0, minato_codec:decode(701, enc(701, 2, binary), binary)),
        ?_assertEqual(1.0, minato_codec:decode(701, ~"1", text)),
        ?_assertEqual(-1.0, minato_codec:decode(701, ~"-1", text))
    ].

float_specials_test_() ->
    [
        {
            atom_to_list(Special) ++ " " ++ integer_to_list(Oid) ++ " " ++ atom_to_list(Format),
            ?_assertEqual(
                Special, minato_codec:decode(Oid, enc(Oid, Special, Format), Format)
            )
        }
     || Special <- [nan, infinity, neg_infinity],
        Oid <- [700, 701],
        Format <- [binary, text]
    ].

float_special_text_spellings_test_() ->
    [
        ?_assertEqual(~"NaN", enc(701, nan, text)),
        ?_assertEqual(~"Infinity", enc(701, infinity, text)),
        ?_assertEqual(~"-Infinity", enc(701, neg_infinity, text)),
        ?_assertEqual(infinity, minato_codec:decode(701, ~"inf", text)),
        ?_assertEqual(neg_infinity, minato_codec:decode(701, ~"-inf", text))
    ].

float_nan_is_quiet_test_() ->
    [
        ?_assertEqual(<<16#7FC00000:32>>, enc(700, nan, binary)),
        ?_assertEqual(<<16#7FF8000000000000:64>>, enc(701, nan, binary)),
        ?_assertEqual(nan, minato_codec:decode(700, <<16#7FC00000:32>>, binary)),
        ?_assertEqual(nan, minato_codec:decode(701, <<16#7FF8000000000000:64>>, binary))
    ].

float_text_without_a_decimal_point_test_() ->
    [
        ?_assertEqual(0.0, minato_codec:decode(701, ~"0", text)),
        ?_assertEqual(1.0e30, minato_codec:decode(701, ~"1e+30", text)),
        ?_assertEqual(-1.0e30, minato_codec:decode(701, ~"-1e+30", text)),
        ?_assertEqual(1.0e-30, minato_codec:decode(701, ~"1e-30", text)),
        ?_assertEqual(123.0, minato_codec:decode(701, ~"123", text)),
        ?_assertEqual(1.5, minato_codec:decode(701, ~"1.5", text)),
        ?_assertError(
            {minato_codec, #{reason := malformed_text}}, minato_codec:decode(701, ~"nope", text)
        )
    ].

float4_text_narrows_to_float4_test_() ->
    Max = 3.4028234663852886e38,
    AsDouble = binary_to_float(~"3.4028235e+38"),
    [
        ?_assertEqual(Max, minato_codec:decode(700, ~"3.4028235e+38", text)),
        ?_assert(AsDouble =/= Max),
        ?_assertEqual(
            minato_codec:decode(700, enc(700, 1.1, binary), binary),
            minato_codec:decode(700, enc(700, 1.1, text), text)
        ),
        ?_assertEqual(0.0, minato_codec:decode(700, ~"0", text)),
        ?_assertError(
            {minato_codec, #{reason := out_of_range}}, minato_codec:decode(700, ~"1e+300", text)
        )
    ].

float4_never_silently_saturates_test_() ->
    [
        ?_assertError({minato_codec, #{reason := out_of_range}}, enc(700, 1.0e300, binary)),
        ?_assertError({minato_codec, #{reason := out_of_range}}, enc(700, -1.0e300, binary)),
        ?_assertError({minato_codec, #{reason := out_of_range}}, enc(700, 1.0e-300, binary)),
        ?_assertEqual(<<0, 0, 0, 0>>, enc(700, 0.0, binary)),
        ?_assertEqual(<<0, 0, 0, 0>>, enc(700, 0, binary)),
        ?_assertError({minato_codec, #{reason := out_of_range}}, enc(701, 1 bsl 2000, binary)),
        ?_assertError({minato_codec, #{reason := not_a_float}}, enc(701, ~"1.5", binary))
    ].

%%----------------------------------------------------------------------
%% text, varchar, json
%%----------------------------------------------------------------------

text_test_() ->
    [
        {integer_to_list(Oid) ++ " " ++ atom_to_list(Format), [
            ?_assertEqual(~"", minato_codec:decode(Oid, enc(Oid, ~"", Format), Format)),
            ?_assertEqual(
                ~"hej på dig", minato_codec:decode(Oid, enc(Oid, ~"hej på dig", Format), Format)
            ),
            ?_assertEqual(~"abc", enc(Oid, [$a, ~"b", "c"], Format))
        ]}
     || Oid <- [25, 1043, 114],
        Format <- [binary, text]
    ].

text_rejects_non_iodata_test_() ->
    ?_assertError({minato_codec, #{reason := not_iodata}}, enc(25, an_atom, binary)).

%%----------------------------------------------------------------------
%% jsonb
%%----------------------------------------------------------------------

jsonb_carries_the_version_byte_test_() ->
    Json = ~"{\"a\":[1,2,3]}",
    [
        ?_assertEqual(<<1, Json/binary>>, enc(3802, Json, binary)),
        ?_assertEqual(Json, enc(3802, Json, text)),
        ?_assertEqual(Json, minato_codec:decode(3802, <<1, Json/binary>>, binary)),
        ?_assertEqual(Json, minato_codec:decode(3802, Json, text))
    ].

jsonb_is_not_parsed_test_() ->
    Whitespace = ~"{ \"a\" :  1 }",
    [
        ?_assertEqual(Whitespace, minato_codec:decode(3802, enc(3802, Whitespace, binary), binary)),
        ?_assertEqual(
            ~"not json at all",
            minato_codec:decode(3802, enc(3802, ~"not json at all", binary), binary)
        )
    ].

jsonb_encodes_from_iodata_test_() ->
    Encoded = json:encode(#{a => 1}),
    ?_assertEqual(
        iolist_to_binary(Encoded), minato_codec:decode(3802, enc(3802, Encoded, binary), binary)
    ).

jsonb_rejects_a_missing_version_byte_test_() ->
    ?_assertError(
        {minato_codec, #{reason := {malformed, binary}}}, minato_codec:decode(3802, ~"", binary)
    ).

%%----------------------------------------------------------------------
%% uuid
%%----------------------------------------------------------------------

uuid_accepts_all_three_input_forms_test_() ->
    Forms = [
        ?UUID_STRING,
        string:uppercase(?UUID_STRING),
        ~"0196f0a91c4f7e219b3a6d2c5e8f1a44",
        ~"0196F0A91C4F7E219B3A6D2C5E8F1A44",
        ?UUID_RAW
    ],
    [?_assertEqual(?UUID_RAW, enc(2950, Form, binary)) || Form <- Forms].

uuid_format_option_test_() ->
    [
        ?_assertEqual(?UUID_STRING, minato_codec:decode(2950, ?UUID_RAW, binary)),
        ?_assertEqual(
            ?UUID_STRING, minato_codec:decode(2950, ?UUID_RAW, binary, #{uuid_format => string})
        ),
        ?_assertEqual(
            ?UUID_RAW, minato_codec:decode(2950, ?UUID_RAW, binary, #{uuid_format => binary})
        ),
        ?_assertEqual(?UUID_STRING, minato_codec:decode(2950, ?UUID_STRING, text)),
        ?_assertEqual(
            ?UUID_RAW, minato_codec:decode(2950, ?UUID_STRING, text, #{uuid_format => binary})
        ),
        ?_assertEqual(?UUID_STRING, enc(2950, ?UUID_RAW, text)),
        ?_assertEqual(?UUID_STRING, enc(2950, ?UUID_STRING, text, #{uuid_format => binary}))
    ].

uuid_rejects_test_() ->
    [
        ?_assertError({minato_codec, #{reason := not_a_uuid}}, enc(2950, ~"nope", binary)),
        ?_assertError(
            {minato_codec, #{reason := malformed_hex}},
            enc(2950, ~"zzzzzzzz-1c4f-7e21-9b3a-6d2c5e8f1a44", binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := {malformed, binary}}},
            minato_codec:decode(2950, <<1, 2, 3>>, binary)
        )
    ].

%%----------------------------------------------------------------------
%% unknown OIDs
%%----------------------------------------------------------------------

unknown_oid_falls_back_to_text_test_() ->
    [
        ?_assertEqual(~"(1,2)", minato_codec:decode(600, ~"(1,2)", text)),
        ?_assertEqual(~"(1,2)", enc(600, ~"(1,2)", text)),
        ?_assertEqual(~"ab", enc(600, [$a, ~"b"], text)),
        ?_assertEqual(null, minato_codec:decode(600, null, text)),
        ?_assertError(
            {minato_codec, #{reason := unsupported_oid}}, minato_codec:decode(600, ~"x", binary)
        ),
        ?_assertError({minato_codec, #{reason := unsupported_oid}}, enc(600, ~"x", binary)),
        ?_assertError({minato_codec, #{reason := unsupported_oid}}, enc(600, 1, text))
    ].

wire(null) -> null;
wire(IoData) -> iolist_to_binary(IoData).
