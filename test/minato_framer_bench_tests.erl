-module(minato_framer_bench_tests).
-moduledoc """
Keeps the benchmark honest.

A benchmark that reads fewer messages than the design it is compared against
measures nothing, so the two readers in `minato_framer_bench` have to agree
on every message of the same result set before a timing figure from them means
anything. Wall clock is not asserted here; a shared build machine cannot promise
one.
""".

-include_lib("eunit/include/eunit.hrl").

both_readers_agree_on_the_result_set_test_() ->
    {timeout, 60, fun() ->
        {Bulk, Header} = minato_framer_bench:equivalent(200),
        ?assertEqual(Header, Bulk),
        ?assertMatch([{row_description, _} | _], Bulk),
        ?assertEqual({command_complete, {select, 200}}, lists:nth(202, Bulk)),
        ?assertEqual({ready_for_query, idle}, lists:last(Bulk)),
        ?assertEqual(203, length(Bulk))
    end}.

the_bulk_reader_takes_fewer_reads_test_() ->
    {timeout, 60, fun() ->
        {_Bulk, BulkReads} = minato_framer_bench:sockets(200, bulk),
        {_Header, HeaderReads} = minato_framer_bench:sockets(200, header),
        ?assertEqual(2 * 203, HeaderReads),
        ?assert(BulkReads < HeaderReads div 10)
    end}.

a_result_set_frames_to_what_it_was_built_from_test() ->
    Bytes = minato_framer_bench:result_set(3),
    {Messages, Rest} = minato_protocol:frame(Bytes),
    ?assertEqual(~"", Rest),
    ?assertEqual(6, length(Messages)),
    ?assertEqual({command_complete, {select, 3}}, lists:nth(5, Messages)).
