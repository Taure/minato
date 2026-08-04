-module(minato_protocol_frame_tests).
-moduledoc """
Tests for the framer and for what it depends on: a decoder that says
`incomplete` for every buffer stopping short of a whole message, rather than
failing.

The truncation tests cut every sample message at every byte and require
`incomplete` for all of them. That is stronger than cutting at the field
boundaries a reader would think of, because a buffer is cut where the network
happened to stop and knows nothing about fields.

Three things beyond framing are checked here because they are what makes the
framer safe to point at a socket. The bound on a declared length is tested at
the limit, one over it and before the payload arrives, since the point of it is
to refuse a header rather than accumulate against it. The retention decisions
are tested through `binary:referenced_byte_size/1`, which reports the binary a
sub-binary points into, so the copy the framer makes and the copies it declines
to make are observable. And totality is tested with random bytes, with random
bytes behind every backend type byte, and with every single byte corruption of a
known good stream.
""".

-include_lib("eunit/include/eunit.hrl").

%% eqWAlizer: this one test passes a `max_message_length` the type forbids, on
%% purpose, because what it checks is that the runtime refuses it too.
-eqwalizer({nowarn_function, a_limit_that_is_not_a_length_is_refused_test/0}).

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

a_negative_length_is_rejected_test() ->
    ?assertError(
        {minato_protocol, #{message := header, reason := length_below_minimum, data := {$D, -1}}},
        minato_protocol:decode(<<$D, 255, 255, 255, 255, 1, 2, 3>>)
    ).

a_one_byte_buffer_is_incomplete_test() ->
    ?assertEqual(incomplete, minato_protocol:decode(<<$C>>)),
    ?assertEqual({[], <<$C>>}, minato_protocol:frame(<<$C>>)).

%%----------------------------------------------------------------------
%% Bounds
%%
%% A declared length is the one number in the stream that decides how much the
%% reader will hold, so it is the one a corrupt or hostile server would choose.
%%----------------------------------------------------------------------

an_oversized_declared_length_is_rejected_test() ->
    ?assertError(
        {minato_protocol, #{message := header, reason := message_too_long}},
        minato_protocol:frame(<<$D, 1073741824:32, 1, 2, 3>>)
    ).

an_oversized_declared_length_is_rejected_before_its_payload_arrives_test() ->
    ?assertError(
        {minato_protocol, #{message := header, reason := message_too_long}},
        minato_protocol:frame(<<$D, 1000:32>>, #{max_message_length => 100})
    ).

a_length_at_the_limit_is_accepted_test() ->
    ?assertEqual(
        {[empty_query_response], ~""},
        minato_protocol:frame(<<$I, 4:32>>, #{max_message_length => 4})
    ).

a_length_one_over_the_limit_is_rejected_test() ->
    ?assertError(
        {minato_protocol, #{message := header, reason := message_too_long, data := {$C, 5, 4}}},
        minato_protocol:frame(<<$C, 5:32, 0>>, #{max_message_length => 4})
    ).

the_default_limit_is_reported_test() ->
    ?assertEqual(67108864, minato_protocol:max_message_length(#{})),
    ?assertEqual(99, minato_protocol:max_message_length(#{max_message_length => 99})).

a_limit_that_is_not_a_length_is_refused_test() ->
    ?assertError(
        {minato_protocol, #{message := frame_opts, reason := invalid_max_message_length}},
        minato_protocol:frame(~"", #{max_message_length => infinity})
    ),
    ?assertError(
        {minato_protocol, #{message := frame_opts, reason := invalid_max_message_length}},
        minato_protocol:frame(~"", #{max_message_length => 3})
    ).

a_message_under_the_limit_still_frames_test() ->
    Bytes = minato_backend_writer:write({parameter_status, ~"a", ~"b"}),
    ?assertEqual(
        {[{parameter_status, ~"a", ~"b"}], ~""},
        minato_protocol:frame(Bytes, #{max_message_length => byte_size(Bytes) - 1})
    ).

%%----------------------------------------------------------------------
%% Binary retention
%%
%% `binary:referenced_byte_size/1` reports the binary a sub-binary points into,
%% so the copy the framer makes, and the copies it declines to make, are
%% observable rather than a claim in a comment.
%%----------------------------------------------------------------------

a_small_remainder_does_not_retain_a_large_buffer_test() ->
    Buffer = <<(binary:copy(minato_backend_writer:write(parse_complete), 13107))/binary, 1, 2, 3>>,
    {Messages, Rest} = minato_protocol:frame(Buffer),
    ?assertEqual(13107, length(Messages)),
    ?assertEqual(<<1, 2, 3>>, Rest),
    ?assert(byte_size(Buffer) > 65536),
    ?assertEqual(byte_size(Rest), binary:referenced_byte_size(Rest)).

a_large_remainder_is_left_pointing_at_its_buffer_test() ->
    Partial = binary:copy(<<9>>, 60000),
    Buffer = <<
        (minato_backend_writer:write(parse_complete))/binary, $D, 900000:32, Partial/binary
    >>,
    {[parse_complete], Rest} = minato_protocol:frame(Buffer),
    ?assertEqual(60005, byte_size(Rest)),
    ?assertEqual(byte_size(Buffer), binary:referenced_byte_size(Rest)).

a_buffer_with_nothing_complete_comes_back_untouched_test() ->
    Buffer = <<$D, 900000:32, (binary:copy(<<9>>, 60000))/binary>>,
    ?assertEqual({[], Buffer}, minato_protocol:frame(Buffer)),
    {[], Rest} = minato_protocol:frame(Buffer),
    ?assertEqual(byte_size(Buffer), binary:referenced_byte_size(Rest)).

%%----------------------------------------------------------------------
%% Totality
%%
%% The bytes reaching the framer are whatever the far end sent. Any of them
%% either frame or raise minato's own exception; none of them raise something
%% the far end got to choose.
%%----------------------------------------------------------------------

random_bytes_never_crash_test_() ->
    {timeout, 120, fun() ->
        [total(rand_bytes(Size)) || Size <- lists:seq(0, 64), _ <- lists:seq(1, 40)]
    end}.

random_bytes_behind_a_plausible_header_never_crash_test_() ->
    {timeout, 120, fun() ->
        [
            total(<<Type, Length:32, (rand_bytes(24))/binary>>)
         || Type <- backend_type_bytes(), Length <- [0, 3, 4, 5, 12, 28, 29, 1 bsl 30]
        ]
    end}.

a_corrupted_stream_never_crashes_test_() ->
    {timeout, 120, fun() ->
        Bytes = minato_backend_writer:write_all(samples()),
        [
            total(corrupt(Bytes, At, Byte))
         || At <- lists:seq(0, byte_size(Bytes) - 1), Byte <- [0, 255]
        ]
    end}.

a_command_tag_that_is_not_utf8_is_a_protocol_error_test() ->
    ?assertError(
        {minato_protocol, #{message := command_complete, reason := tag_word_not_utf8}},
        minato_protocol:frame(<<$C, 7:32, 255, 255, 0>>)
    ).

a_command_tag_too_long_to_be_an_atom_is_a_protocol_error_test() ->
    Tag = binary:copy(~"A", 300),
    ?assertError(
        {minato_protocol, #{message := command_complete, reason := tag_word_too_long}},
        minato_protocol:frame(<<$C, (byte_size(Tag) + 5):32, Tag/binary, 0>>)
    ).

total(Bytes) ->
    try minato_protocol:frame(Bytes) of
        {Messages, Rest} when is_list(Messages), is_binary(Rest) -> ok
    catch
        error:{minato_protocol, #{message := _, reason := _, data := _}} -> ok;
        Class:Reason -> ?assert({Class, Reason, Bytes} =:= no_other_failure)
    end.

rand_bytes(Size) ->
    rand:bytes(Size).

corrupt(Bytes, At, Byte) ->
    <<Head:At/binary, _, Tail/binary>> = Bytes,
    <<Head/binary, Byte, Tail/binary>>.

backend_type_bytes() ->
    [$R, $K, $S, $Z, $T, $D, $C, $I, $E, $N, $1, $2, $3, $n, $t, $s, $A, $?].

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

a_buffer_ending_exactly_on_a_message_boundary_leaves_nothing_over_test() ->
    Messages = result_set(),
    {Decoded, Rest} = minato_protocol:frame(minato_backend_writer:write_all(Messages)),
    ?assertEqual(decoded(Messages), Decoded),
    ?assertEqual(~"", Rest).

every_split_of_a_result_set_frames_the_same_test() ->
    Messages = result_set(),
    Bytes = minato_backend_writer:write_all(Messages),
    Expected = {decoded(Messages), ~""},
    [?assertEqual(Expected, feed_two(Bytes, At)) || At <- lists:seq(0, byte_size(Bytes))].

feed_two(Bytes, At) ->
    <<Head:At/binary, Tail/binary>> = Bytes,
    {First, Carried} = minato_protocol:frame(Head),
    {Second, Rest} = minato_protocol:frame(<<Carried/binary, Tail/binary>>),
    {First ++ Second, Rest}.

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
