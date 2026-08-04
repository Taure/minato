-module(minato_protocol_backend_tests).
-moduledoc """
Table driven decode tests for every backend message.

Each case names the type byte and lays out the payload as the documented format
describes it. The length field is computed from the payload, because here the
length is input rather than output: the decoder is what is under test, and a
length the test got wrong would only ever hide a message from it.
""".

-include_lib("eunit/include/eunit.hrl").

message(Type, Payload) ->
    <<Type, (byte_size(Payload) + 4):32, Payload/binary>>.

dec(Type, Payload) ->
    {ok, Message, ~""} = minato_protocol:decode(message(Type, Payload)),
    Message.

%%----------------------------------------------------------------------
%% Authentication
%%----------------------------------------------------------------------

authentication_ok_test() ->
    ?assertEqual(authentication_ok, dec($R, <<0:32>>)).

authentication_cleartext_password_test() ->
    ?assertEqual(authentication_cleartext_password, dec($R, <<3:32>>)).

authentication_md5_password_test() ->
    ?assertEqual(
        {authentication_md5_password, <<1, 2, 3, 4>>},
        dec($R, <<5:32, 1, 2, 3, 4>>)
    ).

authentication_sasl_test() ->
    ?assertEqual(
        {authentication_sasl, [~"SCRAM-SHA-256"]},
        dec($R, <<10:32, "SCRAM-SHA-256", 0, 0>>)
    ).

authentication_sasl_lists_every_mechanism_test() ->
    ?assertEqual(
        {authentication_sasl, [~"SCRAM-SHA-256-PLUS", ~"SCRAM-SHA-256"]},
        dec($R, <<10:32, "SCRAM-SHA-256-PLUS", 0, "SCRAM-SHA-256", 0, 0>>)
    ).

authentication_sasl_continue_test() ->
    ?assertEqual(
        {authentication_sasl_continue, ~"r=abc,s=xyz,i=4096"},
        dec($R, <<11:32, "r=abc,s=xyz,i=4096">>)
    ).

authentication_sasl_final_test() ->
    ?assertEqual(
        {authentication_sasl_final, ~"v=rmF9pqV8S7suAoZWja4dJRkFsKQ="},
        dec($R, <<12:32, "v=rmF9pqV8S7suAoZWja4dJRkFsKQ=">>)
    ).

authentication_rejects_a_method_minato_cannot_answer_test() ->
    ?assertError(
        {minato_protocol, #{reason := {unsupported_method, 9}}},
        dec($R, <<9:32>>)
    ).

authentication_rejects_a_malformed_payload_test() ->
    [
        ?assertError({minato_protocol, #{reason := malformed}}, dec($R, <<0, 0>>)),
        ?assertError({minato_protocol, #{reason := malformed}}, dec($R, <<5:32, 1, 2>>)),
        ?assertError({minato_protocol, #{reason := malformed}}, dec($R, <<0:32, 7>>))
    ].

%%----------------------------------------------------------------------
%% Session
%%----------------------------------------------------------------------

backend_key_data_is_kept_test() ->
    ?assertEqual(
        {backend_key_data, 12345, 67890},
        dec($K, <<12345:32, 67890:32>>)
    ).

backend_key_data_rejects_the_wrong_size_test() ->
    ?assertError(
        {minato_protocol, #{message := backend_key_data}},
        dec($K, <<12345:32>>)
    ).

parameter_status_test() ->
    ?assertEqual(
        {parameter_status, ~"server_version", ~"17.2"},
        dec($S, <<"server_version", 0, "17.2", 0>>)
    ).

parameter_status_carries_an_empty_value_test() ->
    ?assertEqual(
        {parameter_status, ~"search_path", ~""},
        dec($S, <<"search_path", 0, 0>>)
    ).

parameter_status_rejects_trailing_bytes_test() ->
    ?assertError(
        {minato_protocol, #{reason := trailing_bytes}},
        dec($S, <<"a", 0, "b", 0, "c">>)
    ).

ready_for_query_test_() ->
    [
        ?_assertEqual({ready_for_query, idle}, dec($Z, <<$I>>)),
        ?_assertEqual({ready_for_query, transaction}, dec($Z, <<$T>>)),
        ?_assertEqual({ready_for_query, failed}, dec($Z, <<$E>>))
    ].

ready_for_query_rejects_an_unknown_status_test() ->
    ?assertError({minato_protocol, #{message := ready_for_query}}, dec($Z, <<$X>>)).

notification_response_test() ->
    ?assertEqual(
        {notification_response, 42, ~"chan", ~"hello"},
        dec($A, <<42:32, "chan", 0, "hello", 0>>)
    ).

notification_response_carries_an_empty_payload_test() ->
    ?assertEqual(
        {notification_response, 42, ~"chan", ~""},
        dec($A, <<42:32, "chan", 0, 0>>)
    ).

%%----------------------------------------------------------------------
%% Messages with an empty payload
%%----------------------------------------------------------------------

empty_payload_messages_test_() ->
    [
        ?_assertEqual(empty_query_response, dec($I, ~"")),
        ?_assertEqual(parse_complete, dec($1, ~"")),
        ?_assertEqual(bind_complete, dec($2, ~"")),
        ?_assertEqual(close_complete, dec($3, ~"")),
        ?_assertEqual(no_data, dec($n, ~"")),
        ?_assertEqual(portal_suspended, dec($s, ~""))
    ].

empty_payload_messages_reject_a_payload_test() ->
    ?assertError(
        {minato_protocol, #{message := parse_complete, reason := unexpected_payload}},
        dec($1, <<0>>)
    ).

%%----------------------------------------------------------------------
%% RowDescription
%%----------------------------------------------------------------------

row_description_test() ->
    ?assertEqual(
        {row_description, [
            #{
                name => ~"id",
                table_oid => 16384,
                column => 1,
                type_oid => 23,
                type_size => 4,
                type_modifier => -1,
                format => binary
            }
        ]},
        dec($T, <<1:16, "id", 0, 16384:32, 1:16, 23:32, 4:16, -1:32/signed, 1:16>>)
    ).

row_description_with_zero_fields_test() ->
    ?assertEqual({row_description, []}, dec($T, <<0:16>>)).

row_description_with_several_fields_test() ->
    Payload = <<
        3:16,
        "id",
        0,
        16384:32,
        1:16,
        23:32,
        4:16,
        -1:32/signed,
        1:16,
        "email",
        0,
        16384:32,
        2:16,
        1043:32,
        -1:16/signed,
        259:32,
        1:16,
        "?column?",
        0,
        0:32,
        0:16,
        25:32,
        -1:16/signed,
        -1:32/signed,
        0:16
    >>,
    {row_description, Fields} = dec($T, Payload),
    ?assertEqual([~"id", ~"email", ~"?column?"], [Name || #{name := Name} <- Fields]),
    ?assertEqual([23, 1043, 25], [Oid || #{type_oid := Oid} <- Fields]),
    ?assertEqual([binary, binary, text], [Format || #{format := Format} <- Fields]),
    ?assertEqual([4, -1, -1], [Size || #{type_size := Size} <- Fields]),
    ?assertEqual([-1, 259, -1], [Modifier || #{type_modifier := Modifier} <- Fields]).

row_description_reads_a_system_column_number_test() ->
    {row_description, [#{column := Column}]} =
        dec($T, <<1:16, "ctid", 0, 16384:32, -1:16/signed, 27:32, 6:16, -1:32/signed, 1:16>>),
    ?assertEqual(-1, Column).

row_description_rejects_a_count_that_disagrees_test() ->
    ?assertError(
        {minato_protocol, #{message := row_description}},
        dec($T, <<2:16, "id", 0, 16384:32, 1:16, 23:32, 4:16, -1:32/signed, 1:16>>)
    ).

row_description_rejects_an_unknown_format_code_test() ->
    ?assertError(
        {minato_protocol, #{reason := {unknown_format_code, 2}}},
        dec($T, <<1:16, "id", 0, 16384:32, 1:16, 23:32, 4:16, -1:32/signed, 2:16>>)
    ).

%%----------------------------------------------------------------------
%% DataRow
%%----------------------------------------------------------------------

data_row_test() ->
    ?assertEqual(
        {data_row, [<<0, 0, 0, 42>>, ~"minato"]},
        dec($D, <<2:16, 4:32, 0, 0, 0, 42, 6:32, "minato">>)
    ).

data_row_with_nulls_test() ->
    ?assertEqual(
        {data_row, [null, <<0, 0, 0, 42>>, null]},
        dec($D, <<3:16, -1:32/signed, 4:32, 0, 0, 0, 42, -1:32/signed>>)
    ).

data_row_that_is_entirely_null_test() ->
    ?assertEqual(
        {data_row, [null, null]},
        dec($D, <<2:16, -1:32/signed, -1:32/signed>>)
    ).

empty_data_row_test() ->
    ?assertEqual({data_row, []}, dec($D, <<0:16>>)).

data_row_tells_an_empty_value_from_null_test() ->
    ?assertEqual(
        {data_row, [~"", null]},
        dec($D, <<2:16, 0:32, -1:32/signed>>)
    ).

data_row_rejects_a_count_that_disagrees_test() ->
    [
        ?assertError(
            {minato_protocol, #{message := data_row}},
            dec($D, <<3:16, 4:32, 0, 0, 0, 42>>)
        ),
        ?assertError(
            {minato_protocol, #{message := data_row}},
            dec($D, <<1:16, 4:32, 0, 0, 0, 42, 4:32, 0, 0, 0, 43>>)
        )
    ].

data_row_rejects_a_column_longer_than_the_message_test() ->
    ?assertError(
        {minato_protocol, #{message := data_row}},
        dec($D, <<1:16, 8:32, 0, 0, 0, 42>>)
    ).

data_row_rejects_a_negative_length_that_is_not_null_test() ->
    ?assertError(
        {minato_protocol, #{reason := {negative_column_length, -2}}},
        dec($D, <<1:16, -2:32/signed>>)
    ).

%%----------------------------------------------------------------------
%% ParameterDescription
%%----------------------------------------------------------------------

parameter_description_test() ->
    ?assertEqual({parameter_description, [23, 25]}, dec($t, <<2:16, 23:32, 25:32>>)).

parameter_description_with_no_parameters_test() ->
    ?assertEqual({parameter_description, []}, dec($t, <<0:16>>)).

parameter_description_rejects_a_count_that_disagrees_test() ->
    ?assertError(
        {minato_protocol, #{message := parameter_description}},
        dec($t, <<2:16, 23:32>>)
    ).

%%----------------------------------------------------------------------
%% CommandComplete
%%----------------------------------------------------------------------

command_complete_test_() ->
    Cases = [
        {~"INSERT 0 1", {insert, 1}},
        {~"INSERT 0 0", {insert, 0}},
        {~"INSERT 16384 3", {insert, 3}},
        {~"UPDATE 2", {update, 2}},
        {~"DELETE 7", {delete, 7}},
        {~"SELECT 0", {select, 0}},
        {~"SELECT 100", {select, 100}},
        {~"MERGE 4", {merge, 4}},
        {~"MOVE 3", {move, 3}},
        {~"FETCH 9", {fetch, 9}},
        {~"COPY 5", {copy, 5}},
        {~"BEGIN", {'begin', undefined}},
        {~"COMMIT", {commit, undefined}},
        {~"ROLLBACK", {rollback, undefined}},
        {~"SET", {set, undefined}},
        {~"SHOW", {show, undefined}},
        {~"LISTEN", {listen, undefined}},
        {~"CREATE TABLE", {create, table}},
        {~"DROP TABLE", {drop, table}},
        {~"ALTER TABLE", {alter, table}},
        {~"CREATE INDEX", {create, index}},
        {~"TRUNCATE TABLE", {truncate, table}},
        {~"DECLARE CURSOR", {declare, cursor}},
        {~"CREATE TABLE AS", {create, table_as}}
    ],
    [
        {
            binary_to_list(Tag),
            ?_assertEqual({command_complete, Expected}, dec($C, <<Tag/binary, 0>>))
        }
     || {Tag, Expected} <- Cases
    ].

command_complete_rejects_trailing_bytes_test() ->
    ?assertError(
        {minato_protocol, #{message := command_complete, reason := trailing_bytes}},
        dec($C, <<"SELECT 1", 0, "extra">>)
    ).

command_complete_rejects_a_tag_with_no_terminator_test() ->
    ?assertError(
        {minato_protocol, #{reason := missing_null_terminator}},
        dec($C, ~"SELECT 1")
    ).

%%----------------------------------------------------------------------
%% ErrorResponse and NoticeResponse
%%----------------------------------------------------------------------

error_response_with_only_the_required_fields_test() ->
    ?assertEqual(
        {error_response, #{
            severity => ~"ERROR",
            code => ~"42P01",
            message => ~"relation \"nope\" does not exist"
        }},
        dec($E, <<
            $S,
            "ERROR",
            0,
            $C,
            "42P01",
            0,
            $M,
            "relation \"nope\" does not exist",
            0,
            0
        >>)
    ).

error_response_with_every_field_test() ->
    Payload = <<
        $S,
        "ERROR",
        0,
        $V,
        "ERROR",
        0,
        $C,
        "23505",
        0,
        $M,
        "duplicate key value violates unique constraint",
        0,
        $D,
        "Key (email)=(a@b.c) already exists.",
        0,
        $H,
        "Use a different address.",
        0,
        $P,
        "17",
        0,
        $p,
        "23",
        0,
        $q,
        "INSERT INTO users VALUES ($1)",
        0,
        $W,
        "PL/pgSQL function f() line 3",
        0,
        $s,
        "public",
        0,
        $t,
        "users",
        0,
        $c,
        "email",
        0,
        $d,
        "text",
        0,
        $n,
        "users_email_key",
        0,
        $F,
        "nbtinsert.c",
        0,
        $L,
        "664",
        0,
        $R,
        "_bt_check_unique",
        0,
        0
    >>,
    ?assertEqual(
        {error_response, #{
            severity => ~"ERROR",
            severity_non_localised => ~"ERROR",
            code => ~"23505",
            message => ~"duplicate key value violates unique constraint",
            detail => ~"Key (email)=(a@b.c) already exists.",
            hint => ~"Use a different address.",
            position => ~"17",
            internal_position => ~"23",
            internal_query => ~"INSERT INTO users VALUES ($1)",
            where => ~"PL/pgSQL function f() line 3",
            schema => ~"public",
            table => ~"users",
            column => ~"email",
            data_type => ~"text",
            constraint => ~"users_email_key",
            file => ~"nbtinsert.c",
            line => ~"664",
            routine => ~"_bt_check_unique"
        }},
        dec($E, Payload)
    ).

error_response_discards_a_field_type_it_does_not_know_test() ->
    ?assertEqual(
        {error_response, #{code => ~"23505", message => ~"boom"}},
        dec($E, <<$C, "23505", 0, $Z, "from the future", 0, $M, "boom", 0, 0>>)
    ).

error_response_fills_in_code_and_message_when_a_server_omits_them_test() ->
    ?assertEqual(
        {error_response, #{severity => ~"FATAL", code => ~"", message => ~""}},
        dec($E, <<$S, "FATAL", 0, 0>>)
    ).

error_response_with_no_fields_at_all_test() ->
    ?assertEqual({error_response, #{code => ~"", message => ~""}}, dec($E, <<0>>)).

error_response_rejects_a_missing_terminator_test() ->
    ?assertError(
        {minato_protocol, #{reason := missing_terminator}},
        dec($E, <<$C, "23505", 0>>)
    ).

error_response_rejects_bytes_after_the_terminator_test() ->
    ?assertError(
        {minato_protocol, #{reason := trailing_bytes}},
        dec($E, <<$C, "23505", 0, 0, "junk">>)
    ).

notice_response_test() ->
    ?assertEqual(
        {notice_response, #{
            severity => ~"NOTICE",
            code => ~"42P06",
            message => ~"schema \"public\" already exists, skipping"
        }},
        dec($N, <<
            $S,
            "NOTICE",
            0,
            $C,
            "42P06",
            0,
            $M,
            "schema \"public\" already exists, skipping",
            0,
            0
        >>)
    ).

%%----------------------------------------------------------------------
%% Messages minato does not model
%%----------------------------------------------------------------------

an_unmodelled_message_keeps_its_bytes_test() ->
    ?assertEqual({unsupported, $v, <<0, 0, 0, 3, 0, 0, 0, 0>>}, dec($v, <<3:32, 0:32>>)).

an_unmodelled_message_does_not_lose_the_stream_test() ->
    Buffer = <<
        (minato_backend_writer:write({unsupported, $G, <<0, 1, 0, 0>>}))/binary,
        (minato_backend_writer:write(bind_complete))/binary
    >>,
    ?assertEqual(
        {[{unsupported, $G, <<0, 1, 0, 0>>}, bind_complete], ~""},
        minato_protocol:frame(Buffer)
    ).
