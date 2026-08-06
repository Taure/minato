-module(minato_protocol_run_tests).
-moduledoc """
Tests for framing that decodes a run of `DataRow` messages as it goes.

With a decoder in the frame options a contiguous run of rows comes back as one
`{rows, Rows}` message instead of one `{data_row, Payload}` per row. The saving
is the point of it, so what is tested here is that nothing else changed: that a
run stops where it should, that a row cut by the end of the buffer waits for the
rest instead of being decoded from what arrived, and that the rows come back in
the order the server sent them.

The decoder is per statement, so the framer applying a stale one to the next
statement's rows would be wrong data rather than an error. That is tested
against a real server in `minato_query_SUITE`, since it is the query layer that
clears it.
""".

-include_lib("eunit/include/eunit.hrl").

%%----------------------------------------------------------------------
%% A run
%%----------------------------------------------------------------------

a_run_of_rows_is_framed_as_one_message_test() ->
    Buffer = stream([row(~"1"), row(~"2"), row(~"3")]),
    {Messages, Rest} = minato_protocol:frame(Buffer, opts()),
    ?assertEqual(~"", Rest),
    ?assertEqual([{rows, [{1}, {2}, {3}]}], Messages).

rows_keep_the_order_the_server_sent_test() ->
    Buffer = stream([row(~"7"), row(~"8"), row(~"9")]),
    {[{rows, Rows}], _Rest} = minato_protocol:frame(Buffer, opts()),
    ?assertEqual([{7}, {8}, {9}], Rows).

a_run_ends_at_the_next_message_test() ->
    Buffer = stream([row(~"1"), row(~"2"), {command_complete, ~"SELECT 2"}]),
    {Messages, _Rest} = minato_protocol:frame(Buffer, opts()),
    ?assertEqual([{rows, [{1}, {2}]}, {command_complete, {select, 2}}], Messages).

a_message_between_rows_splits_the_run_test() ->
    Notice = {notice_response, #{message => ~"take note"}},
    Buffer = stream([row(~"1"), Notice, row(~"2")]),
    {Messages, _Rest} = minato_protocol:frame(Buffer, opts()),
    ?assertMatch([{rows, [{1}]}, {notice_response, _}, {rows, [{2}]}], Messages).

%%----------------------------------------------------------------------
%% Buffers that stop mid row
%%----------------------------------------------------------------------

a_row_cut_short_waits_for_the_rest_test() ->
    Whole = stream([row(~"1"), row(~"2")]),
    Cut = binary:part(Whole, 0, byte_size(Whole) - 3),
    {Messages, Rest} = minato_protocol:frame(Cut, opts()),
    ?assertEqual([{rows, [{1}]}], Messages),
    ?assertEqual(byte_size(Cut) - framed_size(row(~"1")), byte_size(Rest)).

a_run_cut_at_every_byte_never_decodes_a_partial_row_test() ->
    Whole = stream([row(~"1"), row(~"2"), row(~"3")]),
    [cut_holds(Whole, At) || At <- lists:seq(0, byte_size(Whole))].

cut_holds(Whole, At) ->
    Cut = binary:part(Whole, 0, At),
    {Messages, Rest} = minato_protocol:frame(Cut, opts()),
    Decoded = [Row || {rows, Rows} <- Messages, Row <- Rows],
    Expected = lists:sublist([{1}, {2}, {3}], length(Decoded)),
    ?assertEqual(Expected, Decoded),
    ?assert(byte_size(Rest) =< byte_size(Cut)).

%%----------------------------------------------------------------------
%% Without a decoder
%%----------------------------------------------------------------------

without_a_decoder_rows_are_left_undecoded_test() ->
    Buffer = stream([row(~"1"), row(~"2")]),
    {Messages, _Rest} = minato_protocol:frame(Buffer, #{}),
    ?assertMatch([{data_row, _}, {data_row, _}], Messages).

a_refused_length_is_still_refused_inside_a_run_test() ->
    Buffer = <<$D, 16#7FFFFFFF:32, 0:16>>,
    ?assertError({minato_protocol, _}, minato_protocol:frame(Buffer, opts())).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

opts() ->
    #{decoder => minato_protocol:decoder([field()], #{})}.

field() ->
    #{
        name => ~"i",
        table_oid => 0,
        column => 0,
        type_oid => 23,
        type_size => -1,
        type_modifier => -1,
        format => text
    }.

row(Value) ->
    {data_row, [Value]}.

stream(Messages) ->
    minato_backend_writer:write_all(Messages).

framed_size(Message) ->
    byte_size(minato_backend_writer:write(Message)).
