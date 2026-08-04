-module(minato_corpus_tests).
-moduledoc """
Tests for the differential corpus itself.

The corpus is the input to `minato_differential_SUITE`, which needs a database.
These run without one, so a corpus that has stopped generating what it claims to
generate is caught by the ordinary test run rather than only by the harness.
""".

-include_lib("eunit/include/eunit.hrl").

every_type_is_covered_test() ->
    Types = minato_corpus:types(),
    ?assertEqual(34, length(Types)),
    ?assertEqual(17, length([Entry || #{kind := scalar} = Entry <- Types])),
    ?assertEqual(17, length([Entry || #{kind := array} = Entry <- Types])),
    ?assertEqual(
        lists:sort(minato_oid:names()),
        lists:sort([Name || #{kind := scalar, name := Name} <- Types])
    ).

every_type_has_fixed_cases_test_() ->
    [
        {name(Entry), ?_assert(length(minato_corpus:fixed(Entry)) >= 2)}
     || Entry <- minato_corpus:types()
    ].

generation_is_deterministic_test_() ->
    [
        {
            name(Entry),
            ?_assertEqual(
                minato_corpus:generate(Entry, 25, 7), minato_corpus:generate(Entry, 25, 7)
            )
        }
     || Entry <- minato_corpus:types()
    ].

a_different_seed_generates_different_values_test() ->
    Entry = entry(int8),
    ?assertNotEqual(minato_corpus:generate(Entry, 50, 1), minato_corpus:generate(Entry, 50, 2)).

generation_yields_the_requested_count_test_() ->
    [
        {name(Entry), ?_assertEqual(13, length(minato_corpus:generate(Entry, 13, 3)))}
     || Entry <- minato_corpus:types()
    ].

every_case_round_trips_without_a_server_test_() ->
    {timeout, 300, [
        {name(Entry), fun() -> round_trip(Entry) end}
     || Entry <- minato_corpus:types()
    ]}.

round_trip(#{oid := Oid} = Entry) ->
    Cases = minato_corpus:fixed(Entry) ++ minato_corpus:generate(Entry, 50, 11),
    _ = [
        begin
            Binary = minato_corpus:encoded(Oid, Value, binary, Opts),
            Text = minato_corpus:encoded(Oid, Value, text, Opts),
            ?assertEqual(Decoded(Binary, binary), Decoded(Text, text))
        end
     || #{value := Value, opts := Opts} <- Cases,
        Decoded <- [fun(Bytes, Format) -> minato_codec:decode(Oid, Bytes, Format, Opts) end]
    ],
    ok.

element_entry_is_the_scalar_test() ->
    ?assertEqual(entry(int8), minato_corpus:element_entry(entry({array, int8}))).

sql_names_are_the_postgresql_names_test() ->
    ?assertEqual(~"timestamptz", minato_corpus:sql_name(timestamptz)),
    ?assertEqual(~"varchar", minato_corpus:sql_name(varchar)),
    ?assertEqual(~"int8[]", maps:get(sql, entry({array, int8}))).

name(#{name := Name}) ->
    lists:flatten(io_lib:format("~p", [Name])).

entry(Name) ->
    hd([Entry || #{name := Found} = Entry <- minato_corpus:types(), Found =:= Name]).
