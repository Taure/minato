-module(minato_oid_tests).

-include_lib("eunit/include/eunit.hrl").

tier_one_oids_test_() ->
    [
        ?_assertEqual(bool, minato_oid:name(16)),
        ?_assertEqual(bytea, minato_oid:name(17)),
        ?_assertEqual(int8, minato_oid:name(20)),
        ?_assertEqual(int4, minato_oid:name(23)),
        ?_assertEqual(text, minato_oid:name(25)),
        ?_assertEqual(varchar, minato_oid:name(1043)),
        ?_assertEqual(timestamptz, minato_oid:name(1184)),
        ?_assertEqual(uuid, minato_oid:name(2950)),
        ?_assertEqual(jsonb, minato_oid:name(3802)),
        ?_assertEqual({array, text}, minato_oid:name(1009)),
        ?_assertEqual({array, int8}, minato_oid:name(1016))
    ].

tier_two_oids_test_() ->
    [
        ?_assertEqual(int2, minato_oid:name(21)),
        ?_assertEqual(float4, minato_oid:name(700)),
        ?_assertEqual(float8, minato_oid:name(701)),
        ?_assertEqual(numeric, minato_oid:name(1700)),
        ?_assertEqual(date, minato_oid:name(1082)),
        ?_assertEqual(time, minato_oid:name(1083)),
        ?_assertEqual(timestamp, minato_oid:name(1114)),
        ?_assertEqual(json, minato_oid:name(114))
    ].

unknown_oid_test_() ->
    [
        ?_assertEqual(undefined, minato_oid:name(0)),
        ?_assertEqual(undefined, minato_oid:name(2249)),
        ?_assertEqual(undefined, minato_oid:element_oid(23)),
        ?_assertEqual(undefined, minato_oid:array_oid(1009))
    ].

every_name_round_trips_test_() ->
    [
        {atom_to_list(Name), ?_assertEqual(Name, minato_oid:name(minato_oid:oid(Name)))}
     || Name <- minato_oid:names()
    ].

every_name_has_an_array_test_() ->
    [
        {atom_to_list(Name), [
            ?_assertEqual({array, Name}, minato_oid:name(minato_oid:oid({array, Name}))),
            ?_assertEqual(
                minato_oid:oid(Name), minato_oid:element_oid(minato_oid:oid({array, Name}))
            ),
            ?_assert(minato_oid:is_array(minato_oid:oid({array, Name}))),
            ?_assertNot(minato_oid:is_array(minato_oid:oid(Name)))
        ]}
     || Name <- minato_oid:names()
    ].

array_oids_are_the_documented_ones_test_() ->
    Expected = [
        {16, 1000},
        {17, 1001},
        {20, 1016},
        {21, 1005},
        {23, 1007},
        {25, 1009},
        {114, 199},
        {700, 1021},
        {701, 1022},
        {1043, 1015},
        {1082, 1182},
        {1083, 1183},
        {1114, 1115},
        {1184, 1185},
        {1700, 1231},
        {2950, 2951},
        {3802, 3807}
    ],
    [?_assertEqual(ArrayOid, minato_oid:array_oid(Oid)) || {Oid, ArrayOid} <- Expected].

supports_and_preferred_format_test_() ->
    [
        ?_assert(minato_codec:supports(23)),
        ?_assert(minato_codec:supports(1009)),
        ?_assertNot(minato_codec:supports(600)),
        ?_assertEqual(binary, minato_codec:preferred_format(23)),
        ?_assertEqual(binary, minato_codec:preferred_format(1009)),
        ?_assertEqual(text, minato_codec:preferred_format(600))
    ].
