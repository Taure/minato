-module(minato_protocol_frame_tests).
-moduledoc """
Tests for the framer and for what it depends on: a decoder that says
`incomplete` for every buffer stopping short of a whole message, rather than
failing.

The truncation tests cut every sample message at every byte and require
`incomplete` for all of them. That is stronger than cutting at the field
boundaries a reader would think of, because a buffer is cut where the network
happened to stop and knows nothing about fields.
""".

-include_lib("eunit/include/eunit.hrl").

%%----------------------------------------------------------------------
%% Truncation
%%----------------------------------------------------------------------

every_prefix_of_every_message_is_incomplete_test_() ->
    [
        {name(Message), fun() -> check_prefixes(minato_backend_writer:write(Message)) end}
     || Message <- samples()
    ].

check_prefixes(Bytes) ->
    [
        ?assertEqual(incomplete, minato_protocol:decode(binary:part(Bytes, 0, Size)))
     || Size <- lists:seq(0, byte_size(Bytes) - 1)
    ].

a_prefix_frames_to_nothing_and_keeps_its_bytes_test_() ->
    [
        {name(Message), fun() -> check_prefix_framing(minato_backend_writer:write(Message)) end}
     || Message <- samples()
    ].

check_prefix_framing(Bytes) ->
    [
        begin
            Prefix = binary:part(Bytes, 0, Size),
            ?assertEqual({[], Prefix}, minato_protocol:frame(Prefix))
        end
     || Size <- lists:seq(0, byte_size(Bytes) - 1)
    ].

an_empty_buffer_is_incomplete_test() ->
    ?assertEqual(incomplete, minato_protocol:decode(~"")).

a_header_on_its_own_is_incomplete_test() ->
    ?assertEqual(incomplete, minato_protocol:decode(<<$C, 0, 0, 0, 13>>)).

a_length_below_the_minimum_is_rejected_test() ->
    ?assertError(
        {minato_protocol, #{message := header, reason := length_below_minimum}},
        minato_protocol:decode(<<$C, 0, 0, 0, 3, 0, 0, 0, 0>>)
    ).

%%----------------------------------------------------------------------
%% Framing
%%----------------------------------------------------------------------

an_empty_buffer_frames_to_nothing_test() ->
    ?assertEqual({[], ~""}, minato_protocol:frame(~"")).

one_message_frames_on_its_own_test() ->
    ?assertEqual(
        {[bind_complete], ~""},
        minato_protocol:frame(minato_backend_writer:write(bind_complete))
    ).

a_whole_result_set_frames_in_one_call_test() ->
    Messages = result_set(),
    ?assertEqual(
        {decoded(Messages), ~""},
        minato_protocol:frame(minato_backend_writer:write_all(Messages))
    ).

a_partial_trailing_message_is_carried_over_test() ->
    Complete = minato_backend_writer:write_all([parse_complete, bind_complete]),
    Partial = binary:part(minato_backend_writer:write({parameter_status, ~"a", ~"b"}), 0, 6),
    {Messages, Rest} = minato_protocol:frame(<<Complete/binary, Partial/binary>>),
    ?assertEqual([parse_complete, bind_complete], Messages),
    ?assertEqual(Partial, Rest).

carrying_the_remainder_forward_reads_the_message_test() ->
    Whole = minato_backend_writer:write({parameter_status, ~"client_encoding", ~"UTF8"}),
    {Head, Tail} = split(Whole, 7),
    {[], Carried} = minato_protocol:frame(Head),
    ?assertEqual(
        {[{parameter_status, ~"client_encoding", ~"UTF8"}], ~""},
        minato_protocol:frame(<<Carried/binary, Tail/binary>>)
    ).

a_stream_fed_one_byte_at_a_time_arrives_whole_test() ->
    Messages = result_set(),
    ?assertEqual(decoded(Messages), drip(minato_backend_writer:write_all(Messages))).

drip(Bytes) ->
    drip(Bytes, ~"", []).

drip(~"", _Buffer, Acc) ->
    lists:reverse(Acc);
drip(<<Byte, Rest/binary>>, Buffer, Acc) ->
    {Messages, Carried} = minato_protocol:frame(<<Buffer/binary, Byte>>),
    drip(Rest, Carried, lists:reverse(Messages, Acc)).

split(Bytes, At) ->
    {binary:part(Bytes, 0, At), binary:part(Bytes, At, byte_size(Bytes) - At)}.

%%----------------------------------------------------------------------
%% SSLRequest is answered with one byte, not with a message
%%----------------------------------------------------------------------

ssl_response_test_() ->
    [
        ?_assertEqual({ok, accepted, ~""}, minato_protocol:ssl_response(~"S")),
        ?_assertEqual({ok, rejected, ~""}, minato_protocol:ssl_response(~"N")),
        ?_assertEqual({ok, accepted, ~"rest"}, minato_protocol:ssl_response(~"Srest")),
        ?_assertEqual(incomplete, minato_protocol:ssl_response(~""))
    ].

ssl_response_leaves_an_error_response_in_the_buffer_test() ->
    Bytes = minato_backend_writer:write({error_response, #{code => ~"0A000", message => ~"no"}}),
    ?assertEqual({ok, error_response, Bytes}, minato_protocol:ssl_response(Bytes)),
    ?assertEqual(
        {[{error_response, #{code => ~"0A000", message => ~"no"}}], ~""},
        minato_protocol:frame(Bytes)
    ).

ssl_response_rejects_anything_else_test() ->
    ?assertError(
        {minato_protocol, #{message := ssl_response}},
        minato_protocol:ssl_response(~"X")
    ).

%%----------------------------------------------------------------------
%% Samples
%%----------------------------------------------------------------------

name(Message) ->
    lists:flatten(io_lib:format("~p", [Message])).

result_set() ->
    [
        {row_description, [field(~"id", 23, binary), field(~"email", 25, text)]},
        {data_row, [<<0, 0, 0, 1>>, ~"a@b.c"]},
        {data_row, [<<0, 0, 0, 2>>, null]},
        {command_complete, ~"SELECT 2"},
        {ready_for_query, idle}
    ].

decoded(Messages) ->
    [decoded_message(Message) || Message <- Messages].

decoded_message({command_complete, ~"SELECT 2"}) -> {command_complete, {select, 2}};
decoded_message(Message) -> Message.

field(Name, Oid, Format) ->
    #{
        name => Name,
        table_oid => 16384,
        column => 1,
        type_oid => Oid,
        type_size => -1,
        type_modifier => -1,
        format => Format
    }.

samples() ->
    [
        authentication_ok,
        authentication_cleartext_password,
        {authentication_md5_password, <<1, 2, 3, 4>>},
        {authentication_sasl, [~"SCRAM-SHA-256"]},
        {authentication_sasl_continue, ~"r=abc,s=xyz,i=4096"},
        {authentication_sasl_final, ~"v=abc"},
        {backend_key_data, 12345, 67890},
        {parameter_status, ~"server_version", ~"17.2"},
        {ready_for_query, idle},
        {row_description, [field(~"id", 23, binary)]},
        {data_row, [<<0, 0, 0, 42>>, null]},
        {command_complete, ~"SELECT 5"},
        empty_query_response,
        {error_response, #{code => ~"23505", message => ~"duplicate key"}},
        {notice_response, #{code => ~"42P06", message => ~"already exists"}},
        parse_complete,
        bind_complete,
        close_complete,
        no_data,
        {parameter_description, [23, 25]},
        portal_suspended,
        {notification_response, 42, ~"chan", ~"hello"}
    ].
