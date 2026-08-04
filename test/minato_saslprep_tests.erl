-module(minato_saslprep_tests).
-moduledoc """
SASLprep against the RFC 4013 examples, and against what is documented as not
covered.

RFC 4013 section 3 publishes seven examples with their expected output. All
seven are here, including the two that must be refused and the one this
implementation is documented as not catching, which is asserted to pass rather
than quietly left out. A gap that has a test saying what it is stays visible;
one that is simply absent from the file does not.
""".

-include_lib("eunit/include/eunit.hrl").

%%----------------------------------------------------------------------
%% RFC 4013 section 3
%%----------------------------------------------------------------------

rfc_4013_examples_test_() ->
    [
        {"1. SOFT HYPHEN mapped to nothing",
            ?_assertEqual({ok, ~"IX"}, normalise([$I, 16#00AD, $X]))},
        {"2. no transformation", ?_assertEqual({ok, ~"user"}, normalise("user"))},
        {"3. case preserved, and does not match example 2",
            ?_assertEqual({ok, ~"USER"}, normalise("USER"))},
        {"4. output is NFKC", ?_assertEqual({ok, ~"a"}, normalise([16#00AA]))},
        {"5. output is NFKC, and matches example 1",
            ?_assertEqual({ok, ~"IX"}, normalise([16#2168]))},
        {"6. prohibited character",
            ?_assertEqual({error, {prohibited, ascii_control, 7}}, normalise([16#0007]))}
    ].

rfc_4013_example_7_is_the_bidirectional_check_this_module_does_not_make_test() ->
    ?assertMatch({ok, _Prepared}, normalise([16#0627, 16#0031])).

%%----------------------------------------------------------------------
%% ASCII, which is what almost every password is
%%----------------------------------------------------------------------

every_printable_ascii_password_is_unchanged_test() ->
    Printable = lists:seq(16#20, 16#7E),
    Password = list_to_binary(Printable),
    ?assertEqual({ok, Password}, minato_saslprep:normalise(Password)),
    ?assertEqual(Password, minato_saslprep:prepare(Password)).

every_printable_ascii_character_alone_is_unchanged_test() ->
    Unchanged = [
        Character
     || Character <- lists:seq(16#20, 16#7E),
        minato_saslprep:normalise(<<Character>>) =:= {ok, <<Character>>}
    ],
    ?assertEqual(lists:seq(16#20, 16#7E), Unchanged).

every_ascii_control_character_is_prohibited_test() ->
    Rejected = [
        Character
     || Character <- lists:seq(0, 16#1F) ++ [16#7F],
        minato_saslprep:normalise(<<Character>>) =:=
            {error, {prohibited, ascii_control, Character}}
    ],
    ?assertEqual(lists:seq(0, 16#1F) ++ [16#7F], Rejected).

an_empty_password_prepares_to_an_empty_password_test() ->
    ?assertEqual({ok, ~""}, minato_saslprep:normalise(~"")).

%%----------------------------------------------------------------------
%% Mapping
%%----------------------------------------------------------------------

non_ascii_spaces_become_a_space_test_() ->
    [
        {"NO-BREAK SPACE", ?_assertEqual({ok, ~"a b"}, normalise([$a, 16#00A0, $b]))},
        {"OGHAM SPACE MARK", ?_assertEqual({ok, ~"a b"}, normalise([$a, 16#1680, $b]))},
        {"EN QUAD", ?_assertEqual({ok, ~"a b"}, normalise([$a, 16#2000, $b]))},
        {"NARROW NO-BREAK SPACE", ?_assertEqual({ok, ~"a b"}, normalise([$a, 16#202F, $b]))},
        {"MEDIUM MATHEMATICAL SPACE", ?_assertEqual({ok, ~"a b"}, normalise([$a, 16#205F, $b]))},
        {"IDEOGRAPHIC SPACE", ?_assertEqual({ok, ~"a b"}, normalise([$a, 16#3000, $b]))}
    ].

commonly_mapped_to_nothing_is_removed_test_() ->
    [
        {"SOFT HYPHEN", ?_assertEqual({ok, ~"ab"}, normalise([$a, 16#00AD, $b]))},
        {"COMBINING GRAPHEME JOINER", ?_assertEqual({ok, ~"ab"}, normalise([$a, 16#034F, $b]))},
        {"MONGOLIAN TODO SOFT HYPHEN", ?_assertEqual({ok, ~"ab"}, normalise([$a, 16#1806, $b]))},
        {"MONGOLIAN FREE VARIATION SELECTOR ONE",
            ?_assertEqual({ok, ~"ab"}, normalise([$a, 16#180B, $b]))},
        {"ZERO WIDTH SPACE", ?_assertEqual({ok, ~"ab"}, normalise([$a, 16#200B, $b]))},
        {"ZERO WIDTH NON-JOINER", ?_assertEqual({ok, ~"ab"}, normalise([$a, 16#200C, $b]))},
        {"WORD JOINER", ?_assertEqual({ok, ~"ab"}, normalise([$a, 16#2060, $b]))},
        {"VARIATION SELECTOR-1", ?_assertEqual({ok, ~"ab"}, normalise([$a, 16#FE00, $b]))},
        {"ZERO WIDTH NO-BREAK SPACE", ?_assertEqual({ok, ~"ab"}, normalise([$a, 16#FEFF, $b]))}
    ].

zero_width_space_is_removed_rather_than_spaced_test() ->
    ?assertEqual({ok, ~"ab"}, normalise([$a, 16#200B, $b])).

%%----------------------------------------------------------------------
%% Normalisation
%%----------------------------------------------------------------------

nfkc_is_applied_test_() ->
    [
        {"LATIN SMALL LIGATURE FI", ?_assertEqual({ok, ~"fi"}, normalise([16#FB01]))},
        {"FULLWIDTH LATIN SMALL LETTER A", ?_assertEqual({ok, ~"a"}, normalise([16#FF41]))},
        {"decomposed A with ring above",
            ?_assertEqual(normalise([16#00C5]), normalise([$A, 16#030A]))},
        {"SUPERSCRIPT TWO", ?_assertEqual({ok, ~"2"}, normalise([16#00B2]))}
    ].

%%----------------------------------------------------------------------
%% Prohibited output
%%----------------------------------------------------------------------

prohibited_characters_test_() ->
    [
        {"non-ASCII control",
            ?_assertEqual({error, {prohibited, non_ascii_control, 16#0085}}, normalise([16#0085]))},
        {"ARABIC END OF AYAH",
            ?_assertEqual({error, {prohibited, non_ascii_control, 16#06DD}}, normalise([16#06DD]))},
        {"LINE SEPARATOR",
            ?_assertEqual({error, {prohibited, non_ascii_control, 16#2028}}, normalise([16#2028]))},
        {"private use",
            ?_assertEqual({error, {prohibited, private_use, 16#E000}}, normalise([16#E000]))},
        {"supplementary private use",
            ?_assertEqual({error, {prohibited, private_use, 16#F0000}}, normalise([16#F0000]))},
        {"non-character in the arabic presentation forms block",
            ?_assertEqual({error, {prohibited, non_character, 16#FDD0}}, normalise([16#FDD0]))},
        {"non-character at the end of the basic plane",
            ?_assertEqual({error, {prohibited, non_character, 16#FFFE}}, normalise([16#FFFE]))},
        {"non-character at the end of the last plane",
            ?_assertEqual({error, {prohibited, non_character, 16#10FFFF}}, normalise([16#10FFFF]))},
        {"REPLACEMENT CHARACTER",
            ?_assertEqual(
                {error, {prohibited, inappropriate_for_plain_text, 16#FFFD}}, normalise([16#FFFD])
            )},
        {"ideographic description character",
            ?_assertEqual(
                {error, {prohibited, inappropriate_for_canonical_representation, 16#2FF0}},
                normalise([16#2FF0])
            )},
        {"LEFT-TO-RIGHT EMBEDDING",
            ?_assertEqual(
                {error, {prohibited, change_display_properties, 16#202A}}, normalise([16#202A])
            )},
        {"LANGUAGE TAG",
            ?_assertEqual({error, {prohibited, tagging, 16#E0001}}, normalise([16#E0001]))},
        {"TAG LATIN SMALL LETTER A",
            ?_assertEqual({error, {prohibited, tagging, 16#E0061}}, normalise([16#E0061]))}
    ].

every_prohibited_code_point_is_rejected_test() ->
    Accepted = [
        Codepoint
     || Codepoint <- prohibited(),
        element(1, normalise([Codepoint])) =/= error
    ],
    ?assertEqual([], Accepted).

every_prohibited_code_point_is_rejected_inside_a_password_test() ->
    Accepted = [
        Codepoint
     || Codepoint <- prohibited(),
        element(1, normalise("pen" ++ [Codepoint] ++ "cil")) =/= error
    ],
    ?assertEqual([], Accepted).

the_prohibited_tables_are_not_empty_test() ->
    ?assert(length(prohibited()) > 6000).

a_character_normalisation_removes_is_never_reached_by_the_prohibition_test() ->
    ?assertEqual(normalise([16#0300]), normalise([16#0340])),
    ?assertEqual(normalise([16#0301]), normalise([16#0341])).

a_prohibited_character_anywhere_rejects_the_whole_password_test() ->
    ?assertEqual(
        {error, {prohibited, private_use, 16#E000}}, normalise("a long password" ++ [16#E000])
    ).

%%----------------------------------------------------------------------
%% Falling back to the raw password
%%----------------------------------------------------------------------

invalid_utf8_is_reported_test() ->
    ?assertEqual({error, not_utf8}, minato_saslprep:normalise(<<16#FF, 16#FE>>)).

a_truncated_utf8_sequence_is_reported_test() ->
    ?assertEqual({error, not_utf8}, minato_saslprep:normalise(<<16#C3>>)).

prepare_falls_back_to_the_raw_bytes_for_invalid_utf8_test() ->
    Password = <<"secret", 16#FF, 16#FE>>,
    ?assertEqual(Password, minato_saslprep:prepare(Password)).

prepare_falls_back_to_the_raw_bytes_for_a_prohibited_character_test() ->
    Password = <<"secret", 7>>,
    ?assertEqual(Password, minato_saslprep:prepare(Password)).

prepare_never_raises_test() ->
    Passwords = [
        ~"",
        ~"pencil",
        <<16#FF>>,
        <<0>>,
        <<16#C3>>,
        <<"a", 16#C2, 16#A0, "b">>,
        list_to_binary(lists:seq(1, 127))
    ],
    ?assertEqual(
        length(Passwords), length([minato_saslprep:prepare(Password) || Password <- Passwords])
    ).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

%% RFC 3454 tables C.1.2 through C.9, less the code points RFC 4013 maps away
%% before the prohibition runs and the surrogates, which no valid UTF-8 password
%% can carry in the first place.
prohibited() ->
    lists:seq(16#0000, 16#001F) ++
        [16#007F] ++
        lists:seq(16#0080, 16#009F) ++
        [16#06DD, 16#070F, 16#180E] ++
        lists:seq(16#2028, 16#2029) ++
        lists:seq(16#2061, 16#2063) ++
        lists:seq(16#1D173, 16#1D17A) ++
        lists:seq(16#200E, 16#200F) ++
        lists:seq(16#202A, 16#202E) ++
        lists:seq(16#206A, 16#206F) ++
        lists:seq(16#E000, 16#F8FF) ++
        [16#F0000, 16#FFFFD, 16#100000, 16#10FFFD] ++
        lists:seq(16#FDD0, 16#FDEF) ++
        [16#FFFE, 16#FFFF, 16#1FFFE, 16#1FFFF, 16#10FFFE, 16#10FFFF] ++
        lists:seq(16#FFF9, 16#FFFD) ++
        lists:seq(16#2FF0, 16#2FFB) ++
        [16#E0001] ++
        lists:seq(16#E0020, 16#E007F).

normalise(Codepoints) ->
    minato_saslprep:normalise(utf8(Codepoints)).

utf8(Codepoints) ->
    case unicode:characters_to_binary(Codepoints, utf8, utf8) of
        Binary when is_binary(Binary) -> Binary
    end.
