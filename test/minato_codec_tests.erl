-module(minato_codec_tests).
-moduledoc """
What `m:minato_codec` itself decides: which codec a type goes to, resolved per
value and resolved once per column, and what it does for a type it has no
codec for. The codecs have test modules of their own.
""".

-include_lib("eunit/include/eunit.hrl").

-define(INT4, 23).
-define(POINT, 600).

%%----------------------------------------------------------------------
%% A decoder is the same decision made once
%%----------------------------------------------------------------------

a_decoder_decodes_what_decode_does_test_() ->
    [
        {
            lists:flatten(io_lib:format("~p ~p ~p", [Name, Format, Value])),
            fun() ->
                Wire = minato_corpus:encoded(Oid, Value, Format, Opts),
                Decoded = minato_codec:decode(Oid, Wire, Format, Opts),
                Decoder = minato_codec:decoder(Oid, Format, Opts),
                ?assertEqual(Decoded, minato_codec:decode(Decoder, Wire)),
                ?assertEqual(null, minato_codec:decode(Decoder, null))
            end
        }
     || #{name := Name, oid := Oid} = Entry <- minato_corpus:types(),
        #{value := Value, opts := Opts} <- minato_corpus:fixed(Entry),
        Format <- [binary, text]
    ].

a_decoder_for_an_unknown_type_passes_text_through_test_() ->
    [
        ?_assertEqual(
            ~"(1,2)", minato_codec:decode(minato_codec:decoder(?POINT, text, #{}), ~"(1,2)")
        ),
        ?_assertError(
            {minato_codec, #{type := ?POINT, reason := unsupported_oid}},
            minato_codec:decode(minato_codec:decoder(?POINT, binary, #{}), <<0:128>>)
        ),
        ?_assertEqual(null, minato_codec:decode(minato_codec:decoder(?POINT, text, #{}), null))
    ].

%%----------------------------------------------------------------------
%% A type with no codec
%%----------------------------------------------------------------------

an_unknown_type_is_text_in_both_directions_test_() ->
    [
        ?_assertEqual(~"(1,2)", minato_codec:decode(?POINT, ~"(1,2)", text)),
        ?_assertEqual(~"(1,2)", minato_codec:encode(?POINT, ~"(1,2)", text)),
        ?_assertEqual(~"(1,2)", minato_codec:encode(?POINT, ["(1,", ~"2)"], text)),
        ?_assertEqual(null, minato_codec:encode(?POINT, null, text)),
        ?_assertEqual(null, minato_codec:decode(?POINT, null, binary)),
        ?_assertError(
            {minato_codec, #{type := ?POINT, reason := unsupported_oid}},
            minato_codec:encode(?POINT, ~"(1,2)", binary)
        ),
        ?_assertError(
            {minato_codec, #{type := ?POINT, reason := unsupported_oid}},
            minato_codec:encode(?POINT, {1, 2}, text)
        ),
        ?_assertError(
            {minato_codec, #{type := ?POINT, reason := unsupported_oid}},
            minato_codec:decode(?POINT, <<0:128>>, binary)
        )
    ].

what_has_a_codec_is_asked_for_in_binary_test_() ->
    [
        ?_assert(minato_codec:supports(?INT4)),
        ?_assert(minato_codec:supports(1007)),
        ?_assertNot(minato_codec:supports(?POINT)),
        ?_assertNot(minato_codec:supports(0)),
        ?_assertEqual(binary, minato_codec:preferred_format(?INT4)),
        ?_assertEqual(binary, minato_codec:preferred_format(1007)),
        ?_assertEqual(text, minato_codec:preferred_format(?POINT))
    ].

%%----------------------------------------------------------------------
%% What a caller offers as iodata
%%----------------------------------------------------------------------

iodata_is_flattened_and_nothing_else_is_test_() ->
    Refused = fun(Value) ->
        ?_assertError(
            {minato_codec, #{type := text, reason := not_iodata}},
            minato_codec:to_binary(text, Value)
        )
    end,
    [
        ?_assertEqual(~"", minato_codec:to_binary(text, [])),
        ?_assertEqual(<<0, 255>>, minato_codec:to_binary(text, [0, 255])),
        ?_assertEqual(~"abcd", minato_codec:to_binary(text, [$a, ~"b", [$c, [~"d"]]])),
        ?_assertEqual(~"ab", minato_codec:to_binary(text, ending_in($a, ~"b"))),
        Refused([256]),
        Refused([-1]),
        Refused([$a, 1.5]),
        Refused(ending_in($a, b)),
        Refused([[$a, atom]]),
        Refused(atom),
        ?_assertError(
            {minato_codec, #{value := [300]}}, minato_codec:to_binary(text, [300])
        )
    ].

%% A list whose tail is not a list, which iodata may be when it is a binary.
ending_in(Head, Tail) ->
    [Head | Tail].

a_failure_names_the_type_the_reason_and_the_value_test() ->
    ?assertError(
        {minato_codec, #{type := a_type, reason := a_reason, value := a_value}},
        minato_codec:bad(a_type, a_reason, a_value)
    ).
