-module(minato_codec_array_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TEXT_ARRAY, 1009).
-define(INT8_ARRAY, 1016).
-define(INT4_ARRAY, 1007).

enc(Oid, Value, Format) ->
    wire(minato_codec:encode(Oid, Value, Format)).

roundtrip(Oid, Value, Format) ->
    minato_codec:decode(Oid, enc(Oid, Value, Format), Format).

%%----------------------------------------------------------------------
%% The documented binary header
%%----------------------------------------------------------------------

empty_array_has_no_dimension_header_test_() ->
    [
        ?_assertEqual(<<0:32/signed, 0:32, 20:32>>, enc(?INT8_ARRAY, [], binary)),
        ?_assertEqual(<<0:32/signed, 0:32, 25:32>>, enc(?TEXT_ARRAY, [], binary)),
        ?_assertEqual([], minato_codec:decode(?INT8_ARRAY, <<0:32/signed, 0:32, 20:32>>, binary)),
        ?_assertEqual([], roundtrip(?INT8_ARRAY, [], binary)),
        ?_assertEqual(~"{}", enc(?INT8_ARRAY, [], text)),
        ?_assertEqual([], roundtrip(?INT8_ARRAY, [], text))
    ].

one_dimensional_header_test() ->
    Expected = <<
        1:32/signed,
        0:32,
        23:32,
        3:32/signed,
        1:32/signed,
        4:32/signed,
        1:32/signed,
        4:32/signed,
        2:32/signed,
        4:32/signed,
        3:32/signed
    >>,
    ?assertEqual(Expected, enc(?INT4_ARRAY, [1, 2, 3], binary)).

has_null_flag_is_set_test_() ->
    <<_:32, WithNull:32, _/binary>> = enc(?INT4_ARRAY, [1, null], binary),
    <<_:32, WithoutNull:32, _/binary>> = enc(?INT4_ARRAY, [1, 2], binary),
    [
        ?_assertEqual(1, WithNull),
        ?_assertEqual(0, WithoutNull)
    ].

null_elements_use_a_length_of_minus_one_test_() ->
    Wire = enc(?INT4_ARRAY, [null], binary),
    [
        ?_assertEqual(<<1:32/signed, 1:32, 23:32, 1:32/signed, 1:32/signed, -1:32/signed>>, Wire),
        ?_assertEqual([null], minato_codec:decode(?INT4_ARRAY, Wire, binary))
    ].

%%----------------------------------------------------------------------
%% Round trips
%%----------------------------------------------------------------------

round_trips_test_() ->
    Cases = [
        {?INT8_ARRAY, []},
        {?INT8_ARRAY, [0]},
        {?INT8_ARRAY, [1, 2, 3]},
        {?INT8_ARRAY, [null]},
        {?INT8_ARRAY, [null, null]},
        {?INT8_ARRAY, [1, null, 3]},
        {?INT8_ARRAY, [-9223372036854775808, 9223372036854775807]},
        {?TEXT_ARRAY, [~"a", ~"b"]},
        {?TEXT_ARRAY, [~""]},
        {?TEXT_ARRAY, [~"", null, ~"x"]},
        {?TEXT_ARRAY, [~"NULL", ~"null", ~"Null"]},
        {?TEXT_ARRAY, [~"a,b", ~"{c}", ~"d\"e", ~"f\\g", ~"h i", ~"j\nk"]},
        {1000, [true, false, null]},
        {1001, [<<0, 255>>, ~""]},
        {1231, [~"1.50", nan, infinity, null]},
        {1185, [{{2024, 1, 15}, {13, 45, 30}}, infinity, null]},
        {1182, [{2024, 1, 15}, {1970, 1, 1}]},
        {2951, [~"0196f0a9-1c4f-7e21-9b3a-6d2c5e8f1a44", null]},
        {3807, [~"{\"a\":1}", ~"[]"]},
        {1022, [1.5, nan, infinity, neg_infinity, null]}
    ],
    [
        {
            lists:flatten(io_lib:format("~p ~p ~p", [Oid, Value, Format])),
            ?_assertEqual(Value, roundtrip(Oid, Value, Format))
        }
     || {Oid, Value} <- Cases, Format <- [binary, text]
    ].

%%----------------------------------------------------------------------
%% Text format specifics
%%----------------------------------------------------------------------

text_quoting_test_() ->
    [
        ?_assertEqual(~"{1,2,3}", enc(?INT4_ARRAY, [1, 2, 3], text)),
        ?_assertEqual(~"{a,b}", enc(?TEXT_ARRAY, [~"a", ~"b"], text)),
        ?_assertEqual(~"{NULL}", enc(?TEXT_ARRAY, [null], text)),
        ?_assertEqual(~"{\"NULL\"}", enc(?TEXT_ARRAY, [~"NULL"], text)),
        ?_assertEqual(~"{\"null\"}", enc(?TEXT_ARRAY, [~"null"], text)),
        ?_assertEqual(~"{\"\"}", enc(?TEXT_ARRAY, [~""], text)),
        ?_assertEqual(~"{\"a,b\"}", enc(?TEXT_ARRAY, [~"a,b"], text)),
        ?_assertEqual(~"{\"a b\"}", enc(?TEXT_ARRAY, [~"a b"], text)),
        ?_assertEqual(~"{\"{}\"}", enc(?TEXT_ARRAY, [~"{}"], text)),
        ?_assertEqual(~"{\"a\\\"b\"}", enc(?TEXT_ARRAY, [~"a\"b"], text)),
        ?_assertEqual(~"{\"a\\\\b\"}", enc(?TEXT_ARRAY, [~"a\\b"], text))
    ].

unquoted_null_is_null_but_quoted_null_is_a_string_test_() ->
    [
        ?_assertEqual([null], minato_codec:decode(?TEXT_ARRAY, ~"{NULL}", text)),
        ?_assertEqual([null], minato_codec:decode(?TEXT_ARRAY, ~"{null}", text)),
        ?_assertEqual([~"NULL"], minato_codec:decode(?TEXT_ARRAY, ~"{\"NULL\"}", text))
    ].

dimension_prefix_is_skipped_test_() ->
    [
        ?_assertEqual([1, 2, 3], minato_codec:decode(?INT4_ARRAY, ~"[0:2]={1,2,3}", text)),
        ?_assertEqual(
            [[1, 2], [3, 4]], minato_codec:decode(?INT4_ARRAY, ~"[1:2][1:2]={{1,2},{3,4}}", text)
        )
    ].

text_rejects_test_() ->
    [
        ?_assertError(
            {minato_codec, #{reason := malformed_text}},
            minato_codec:decode(?INT4_ARRAY, ~"1,2,3", text)
        ),
        ?_assertError(
            {minato_codec, #{reason := malformed_text}},
            minato_codec:decode(?INT4_ARRAY, ~"{1,2", text)
        ),
        ?_assertError(
            {minato_codec, #{reason := unterminated_quote}},
            minato_codec:decode(?TEXT_ARRAY, ~"{\"abc}", text)
        ),
        ?_assertError(
            {minato_codec, #{reason := trailing_bytes}},
            minato_codec:decode(?INT4_ARRAY, ~"{1}x", text)
        )
    ].

%%----------------------------------------------------------------------
%% Multi dimensional decoding
%%----------------------------------------------------------------------

multi_dimensional_decodes_to_nested_lists_test_() ->
    TwoByTwo = <<
        2:32/signed,
        0:32,
        23:32,
        2:32/signed,
        1:32/signed,
        2:32/signed,
        1:32/signed,
        4:32/signed,
        1:32/signed,
        4:32/signed,
        2:32/signed,
        4:32/signed,
        3:32/signed,
        4:32/signed,
        4:32/signed
    >>,
    [
        ?_assertEqual([[1, 2], [3, 4]], minato_codec:decode(?INT4_ARRAY, TwoByTwo, binary)),
        ?_assertEqual([[1, 2], [3, 4]], minato_codec:decode(?INT4_ARRAY, ~"{{1,2},{3,4}}", text)),
        ?_assertEqual(
            [[[1], [2]], [[3], [4]]],
            minato_codec:decode(?INT4_ARRAY, ~"{{{1},{2}},{{3},{4}}}", text)
        )
    ].

%%----------------------------------------------------------------------
%% Multi dimensional encoding
%%----------------------------------------------------------------------

a_list_in_a_list_is_a_row_where_an_element_cannot_be_a_list_test_() ->
    TwoByTwo = <<
        (header(2, [2, 2], ~""))/binary,
        4:32/signed,
        1:32/signed,
        4:32/signed,
        2:32/signed,
        4:32/signed,
        3:32/signed,
        4:32/signed,
        4:32/signed
    >>,
    [
        ?_assertEqual(TwoByTwo, enc(?INT4_ARRAY, [[1, 2], [3, 4]], binary)),
        ?_assertEqual(~"{{1,2},{3,4}}", enc(?INT4_ARRAY, [[1, 2], [3, 4]], text)),
        ?_assertEqual(~"{{{1},{2}},{{3},{4}}}", enc(?INT4_ARRAY, [[[1], [2]], [[3], [4]]], text)),
        ?_assertEqual(
            header(3, [1, 2, 1], <<4:32/signed, 1:32/signed, 4:32/signed, 2:32/signed>>),
            enc(?INT4_ARRAY, [[[1], [2]]], binary)
        )
    ].

a_list_in_a_list_is_one_string_where_an_element_can_be_a_list_test_() ->
    [
        ?_assertEqual([~"ab"], roundtrip(?TEXT_ARRAY, [[$a, $b]], Format))
     || Format <- [binary, text]
    ] ++
        [
            ?_assertEqual([~"ab", ~"c"], roundtrip(?TEXT_ARRAY, [[~"a", ~"b"], [~"c"]], Format))
         || Format <- [binary, text]
        ] ++
        [
            ?_assertEqual([~"ab", ~"cd"], roundtrip(?TEXT_ARRAY, ["ab", "cd"], binary)),
            ?_assertEqual([<<1, 2>>, <<3>>], roundtrip(1001, [[1, 2], [<<3>>]], binary)),
            ?_assertEqual(~"{ab,cd}", enc(?TEXT_ARRAY, [[~"a", ~"b"], [~"c", ~"d"]], text))
        ].

a_string_in_an_array_of_numbers_is_a_row_of_its_characters_test_() ->
    [
        ?_assertEqual([[$1, $2], [$3, $4]], roundtrip(?INT4_ARRAY, ["12", "34"], binary)),
        ?_assertEqual(~"{{49,50}}", enc(?INT4_ARRAY, ["12"], text)),
        ?_assertError(
            {minato_codec, #{reason := ragged_array, value := "2"}},
            enc(?INT4_ARRAY, [1, "2"], binary)
        ),
        ?_assertError(
            {minato_codec, #{type := uuid, reason := not_a_uuid}},
            enc(2951, ["0196f0a9-1c4f-7e21-9b3a-6d2c5e8f1a44"], binary)
        )
    ].

a_list_is_a_string_exactly_where_the_element_codec_takes_one_test_() ->
    [
        {atom_to_list(Name), fun() ->
            Element = minato_oid:oid(Name),
            Array = minato_oid:oid({array, Name}),
            TakesAList =
                try minato_codec:encode(Element, [], binary) of
                    _Encoded -> true
                catch
                    error:{minato_codec, _Report} -> false
                end,
            <<Dimensions:32/signed, _/binary>> = enc(Array, [[]], binary),
            ?assertEqual(TakesAList, Dimensions =:= 1)
        end}
     || Name <- minato_oid:names()
    ].

marked_as_an_array_every_list_is_a_dimension_test_() ->
    Rows = [[~"a", ~"b"], [~"c", ~"d"]],
    [
        ?_assertEqual(~"{{a,b},{c,d}}", enc(?TEXT_ARRAY, {array, Rows}, text)),
        ?_assertEqual(Rows, roundtrip(?TEXT_ARRAY, {array, Rows}, binary)),
        ?_assertEqual(Rows, roundtrip(?TEXT_ARRAY, {array, Rows}, text)),
        ?_assertEqual([~"a", ~"b"], roundtrip(?TEXT_ARRAY, {array, [~"a", ~"b"]}, binary)),
        ?_assertEqual([], roundtrip(?TEXT_ARRAY, {array, []}, binary)),
        ?_assertEqual(
            enc(?INT4_ARRAY, [[1, 2], [3, 4]], binary),
            enc(?INT4_ARRAY, {array, [[1, 2], [3, 4]]}, binary)
        ),
        ?_assertEqual(
            enc(?INT4_ARRAY, [1, 2], text),
            enc(?INT4_ARRAY, {array, [1, 2]}, text)
        ),
        ?_assertError(
            {minato_codec, #{type := {array, ?TEXT_ARRAY}, reason := not_a_list}},
            enc(?TEXT_ARRAY, {array, ~"a"}, binary)
        ),
        ?_assertError(
            {minato_codec, #{type := {array, ?TEXT_ARRAY}, reason := ragged_array}},
            enc(?TEXT_ARRAY, {array, ["ab", "c"]}, binary)
        )
    ].

every_element_type_round_trips_in_every_shape_test_() ->
    [
        {
            lists:flatten(io_lib:format("~p ~p ~p", [Name, Expected, Format])),
            ?_assertEqual(Expected, roundtrip(Oid, Value, Format))
        }
     || #{kind := array, name := Name, oid := Oid} = Entry <- minato_corpus:types(),
        #{value := Value, expected := Expected} <- minato_corpus:nested(Entry),
        Format <- [binary, text]
    ].

a_null_anywhere_sets_the_flag_test_() ->
    Flags = fun(Value) ->
        <<_:32, Flag:32, _/binary>> = enc(?INT4_ARRAY, Value, binary),
        Flag
    end,
    [
        ?_assertEqual(0, Flags([[1, 2], [3, 4]])),
        ?_assertEqual(1, Flags([[1, 2], [3, null]])),
        ?_assertEqual(1, Flags([[null, 2], [3, 4]])),
        ?_assertEqual(~"{{1,NULL},{NULL,4}}", enc(?INT4_ARRAY, [[1, null], [null, 4]], text)),
        ?_assertEqual(
            ~"{{a,NULL},{\"NULL\",\"\"}}",
            enc(?TEXT_ARRAY, {array, [[~"a", null], [~"NULL", ~""]]}, text)
        )
    ].

a_ragged_list_is_refused_test_() ->
    Ragged = [
        {[[1, 2], [3]], [3]},
        {[[1], [2, 3]], [2, 3]},
        {[[1, 2], 3], 3},
        {[[1, 2], null], null},
        {[1, [2]], [2]},
        {[[1, [2]], [3, 4]], [2]},
        {[[[1], [2]], [[3]]], [[3]]},
        {[[[1]], [2]], 2},
        {[[], [1]], [1]}
    ],
    [
        {
            lists:flatten(io_lib:format("~p ~p", [List, Format])),
            ?_assertError(
                {minato_codec, #{
                    type := {array, ?INT4_ARRAY}, reason := ragged_array, value := Culprit
                }},
                enc(?INT4_ARRAY, List, Format)
            )
        }
     || {List, Culprit} <- Ragged, Format <- [binary, text]
    ].

an_array_with_no_elements_has_no_dimensions_test_() ->
    Empty = enc(?INT4_ARRAY, [], binary),
    [
        ?_assertEqual(Empty, enc(?INT4_ARRAY, [[]], binary)),
        ?_assertEqual(Empty, enc(?INT4_ARRAY, [[], []], binary)),
        ?_assertEqual(Empty, enc(?INT4_ARRAY, [[[]], [[]]], binary)),
        ?_assertEqual(~"{}", enc(?INT4_ARRAY, [[], []], text)),
        ?_assertEqual(~"{}", enc(?INT4_ARRAY, [[[]]], text)),
        ?_assertEqual(enc(?TEXT_ARRAY, [], binary), enc(?TEXT_ARRAY, {array, [[], []]}, binary)),
        ?_assertEqual([], roundtrip(?INT4_ARRAY, [[], []], binary)),
        ?_assertEqual([], roundtrip(?INT4_ARRAY, [[], []], text))
    ].

seven_dimensions_are_not_written_test_() ->
    Six = [[[[[[7, 8]]]]]],
    [
        ?_assertEqual(Six, roundtrip(?INT4_ARRAY, Six, binary)),
        ?_assertEqual(~"{{{{{{7,8}}}}}}", enc(?INT4_ARRAY, Six, text)),
        ?_assertError(
            {minato_codec, #{type := {array, ?INT4_ARRAY}, reason := dimensions_out_of_range}},
            enc(?INT4_ARRAY, [Six], binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := dimensions_out_of_range}},
            enc(?INT4_ARRAY, [Six], text)
        ),
        ?_assertError(
            {minato_codec, #{reason := dimensions_out_of_range}},
            enc(?TEXT_ARRAY, {array, [[[[[[[~"a"]]]]]]]}, binary)
        )
    ].

lower_bounds_of_every_dimension_are_passed_over_test_() ->
    Elements = <<
        4:32/signed,
        1:32/signed,
        4:32/signed,
        2:32/signed,
        4:32/signed,
        3:32/signed,
        4:32/signed,
        4:32/signed
    >>,
    Wire =
        <<2:32/signed, 0:32, 23:32, 2:32/signed, 0:32/signed, 2:32/signed, -5:32/signed,
            Elements/binary>>,
    [
        ?_assertEqual([[1, 2], [3, 4]], minato_codec:decode(?INT4_ARRAY, Wire, binary)),
        ?_assertEqual(
            [[1, 2], [3, 4]],
            minato_codec:decode(?INT4_ARRAY, ~"[0:1][-5:-4]={{1,2},{3,4}}", text)
        ),
        ?_assertEqual(
            [[~"a=b"]], minato_codec:decode(?TEXT_ARRAY, ~"[7:7][0:0]={{a=b}}", text)
        )
    ].

lower_bounds_are_not_represented_test() ->
    Wire =
        <<1:32/signed, 0:32, 23:32, 2:32/signed, 7:32/signed, 4:32/signed, 1:32/signed, 4:32/signed,
            2:32/signed>>,
    ?assertEqual([1, 2], minato_codec:decode(?INT4_ARRAY, Wire, binary)).

%%----------------------------------------------------------------------
%% Rejections
%%----------------------------------------------------------------------

binary_rejects_test_() ->
    [
        ?_assertError({minato_codec, #{reason := not_a_list}}, enc(?INT4_ARRAY, ~"nope", binary)),
        ?_assertError(
            {minato_codec, #{reason := truncated_elements}},
            minato_codec:decode(
                ?INT4_ARRAY, <<1:32/signed, 0:32, 23:32, 2:32/signed, 1:32/signed>>, binary
            )
        ),
        ?_assertError(
            {minato_codec, #{reason := trailing_bytes}},
            minato_codec:decode(
                ?INT4_ARRAY,
                <<1:32/signed, 0:32, 23:32, 1:32/signed, 1:32/signed, 4:32/signed, 1:32/signed, 0>>,
                binary
            )
        ),
        ?_assertError(
            {minato_codec, #{reason := truncated_dimensions}},
            minato_codec:decode(
                ?INT4_ARRAY, <<2:32/signed, 0:32, 23:32, 1:32/signed, 1:32/signed>>, binary
            )
        )
    ].

%%----------------------------------------------------------------------
%% Bounds
%%----------------------------------------------------------------------

six_dimensions_is_the_most_there_is_test_() ->
    Six = header(6, [1, 1, 1, 1, 1, 1], <<4:32/signed, 7:32/signed>>),
    Seven = header(7, [1, 1, 1, 1, 1, 1, 1], <<4:32/signed, 7:32/signed>>),
    [
        ?_assertEqual([[[[[[7]]]]]], minato_codec:decode(?INT4_ARRAY, Six, binary)),
        ?_assertEqual([[[[[[7]]]]]], minato_codec:decode(?INT4_ARRAY, ~"{{{{{{7}}}}}}", text)),
        ?_assertError(
            {minato_codec, #{reason := dimensions_out_of_range, value := 7}},
            minato_codec:decode(?INT4_ARRAY, Seven, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := dimensions_out_of_range}},
            minato_codec:decode(?INT4_ARRAY, ~"{{{{{{{7}}}}}}}", text)
        ),
        ?_assertError(
            {minato_codec, #{reason := dimensions_out_of_range, value := 16#7FFFFFFF}},
            minato_codec:decode(?INT4_ARRAY, <<16#7FFFFFFF:32/signed, 0:32, 23:32>>, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := dimensions_out_of_range, value := -1}},
            minato_codec:decode(?INT4_ARRAY, <<-1:32/signed, 0:32, 23:32>>, binary)
        )
    ].

deep_text_nesting_is_refused_at_the_seventh_brace_test() ->
    Deep = binary:copy(~"{", 1000000),
    ?assertError(
        {minato_codec, #{reason := dimensions_out_of_range}},
        minato_codec:decode(?INT4_ARRAY, Deep, text)
    ).

a_dimension_cannot_be_negative_test() ->
    ?assertError(
        {minato_codec, #{reason := negative_dimension, value := -2}},
        minato_codec:decode(?INT4_ARRAY, header(1, [-2], ~""), binary)
    ).

more_elements_than_the_bytes_could_hold_are_not_read_test_() ->
    Wide = header(2, [16#7FFFFFFF, 16#7FFFFFFF], <<4:32/signed, 1:32/signed>>),
    [
        ?_assertError(
            {minato_codec, #{reason := truncated_elements}},
            minato_codec:decode(?INT4_ARRAY, Wide, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := truncated_elements}},
            minato_codec:decode(?INT4_ARRAY, header(1, [2], <<-1:32/signed>>), binary)
        ),
        ?_assertEqual(
            [null, null],
            minato_codec:decode(
                ?INT4_ARRAY, header(1, [2], <<-1:32/signed, -1:32/signed>>), binary
            )
        ),
        ?_assertEqual([], minato_codec:decode(?INT4_ARRAY, header(1, [0], ~""), binary))
    ].

header(NDim, Sizes, Elements) ->
    <<NDim:32/signed, 0:32, 23:32, <<<<Size:32/signed, 1:32/signed>> || Size <- Sizes>>/binary,
        Elements/binary>>.

wire(null) -> null;
wire(IoData) -> iolist_to_binary(IoData).

%%----------------------------------------------------------------------
%% Edges the cases above leave between them
%%----------------------------------------------------------------------

a_header_cut_short_is_not_an_empty_array_test_() ->
    [
        ?_assertError(
            {minato_codec, #{reason := {malformed, binary}}},
            minato_codec:decode(?INT4_ARRAY, <<0:32/signed, 0:32>>, binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := {malformed, binary}}},
            minato_codec:decode(?INT4_ARRAY, <<7:32/signed, 0:32>>, binary)
        )
    ].

a_dimension_of_minus_one_is_refused_test_() ->
    [
        ?_assertError(
            {minato_codec, #{reason := negative_dimension, value := -1}},
            minato_codec:decode(?INT4_ARRAY, header(1, [-1], ~""), binary)
        ),
        ?_assertError(
            {minato_codec, #{reason := truncated_dimensions}},
            minato_codec:decode(?INT4_ARRAY, <<1:32/signed, 0:32, 23:32, -1:32/signed>>, binary)
        )
    ].

elements_are_counted_against_the_bytes_before_any_is_read_test_() ->
    Refused = fun(Elements) ->
        ?_assertError(
            {minato_codec, #{reason := truncated_elements, value := Elements}},
            minato_codec:decode(?INT4_ARRAY, header(1, [3], Elements), binary)
        )
    end,
    [
        Refused(<<-1:32/signed, -1:32/signed>>),
        Refused(<<-1:32/signed, -1:32/signed, 0, 0, 0>>)
    ].

an_element_longer_than_what_is_left_is_refused_test() ->
    ?assertError(
        {minato_codec, #{reason := truncated_elements}},
        minato_codec:decode(?INT4_ARRAY, header(1, [1], <<8:32/signed, 1, 2>>), binary)
    ).

an_array_of_a_type_that_has_no_elements_is_refused_test() ->
    ?assertError(
        {minato_codec, #{reason := not_an_array_type}},
        minato_codec_array:decode(23, header(1, [1], <<4:32/signed, 1:32/signed>>), binary, #{})
    ).

rows_of_one_keep_their_shape_test_() ->
    Two = <<4:32/signed, 1:32/signed, 4:32/signed, 2:32/signed>>,
    [
        ?_assertEqual(
            [[1], [2]], minato_codec:decode(?INT4_ARRAY, header(2, [2, 1], Two), binary)
        ),
        ?_assertEqual(
            [[[1]], [[2]]], minato_codec:decode(?INT4_ARRAY, header(3, [2, 1, 1], Two), binary)
        )
    ].

only_the_whole_word_is_null_test() ->
    ?assertEqual(
        [~"nulx", ~"nuxx", ~"nxxx", ~"xull", ~"nxll"],
        minato_codec:decode(?TEXT_ARRAY, ~"{nulx,nuxx,nxxx,xull,nxll}", text)
    ).
