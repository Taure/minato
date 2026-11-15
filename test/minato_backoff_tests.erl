-module(minato_backoff_tests).

-include_lib("eunit/include/eunit.hrl").

%% Ten thousand draws from fifty one values miss one of them about once in
%% ten to the eighty sixth runs.
a_wait_is_anywhere_in_the_upper_half_and_nowhere_else_test_() ->
    [
        {integer_to_list(Longest), fun() ->
            Waits = [minato_backoff:spread(Longest) || _Each <- lists:seq(1, 10000)],
            ?assertEqual(lists:seq(Longest - Longest div 2, Longest), lists:usort(Waits))
        end}
     || Longest <- [100, 101]
    ].

the_shortest_wait_there_is_stays_what_it_was_test() ->
    ?assertEqual([1], lists:usort([minato_backoff:spread(1) || _Each <- lists:seq(1, 100)])).
