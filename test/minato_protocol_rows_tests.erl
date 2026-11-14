-module(minato_protocol_rows_tests).
-moduledoc """
Tests for the part of decoding that a `DataRow` cannot do on its own: turning
raw column bytes into values, which needs the type OIDs and format codes from
the `RowDescription` that came before it.
""".

-include_lib("eunit/include/eunit.hrl").

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

description() ->
    [field(~"id", 23, binary), field(~"email", 25, binary), field(~"active", 16, binary)].

columns() ->
    [<<0, 0, 0, 42>>, ~"a@b.c", <<1>>].

%%----------------------------------------------------------------------
%% Tuples
%%----------------------------------------------------------------------

a_row_is_a_tuple_by_default_test() ->
    ?assertEqual(
        {42, ~"a@b.c", true},
        minato_protocol:row(description(), columns(), #{})
    ).

a_null_column_decodes_to_null_test() ->
    ?assertEqual(
        {42, null, null},
        minato_protocol:row(description(), [<<0, 0, 0, 42>>, null, null], #{})
    ).

an_empty_description_gives_an_empty_row_test() ->
    ?assertEqual({}, minato_protocol:row([], [], #{})).

a_text_column_is_decoded_as_text_test() ->
    ?assertEqual(
        {42},
        minato_protocol:row([field(~"id", 23, text)], [~"42"], #{})
    ).

a_row_honours_the_codec_options_test() ->
    Raw =
        <<16#01, 16#96, 16#f0, 16#a9, 16#1c, 16#4f, 16#7e, 16#21, 16#9b, 16#3a, 16#6d, 16#2c, 16#5e,
            16#8f, 16#1a, 16#44>>,
    Description = [field(~"id", 2950, binary)],
    ?assertEqual(
        {~"0196f0a9-1c4f-7e21-9b3a-6d2c5e8f1a44"},
        minato_protocol:row(Description, [Raw], #{})
    ),
    ?assertEqual(
        {Raw},
        minato_protocol:row(Description, [Raw], #{uuid_format => binary})
    ).

%%----------------------------------------------------------------------
%% Maps
%%----------------------------------------------------------------------

a_row_is_a_map_when_asked_test() ->
    ?assertEqual(
        #{~"id" => 42, ~"email" => ~"a@b.c", ~"active" => true},
        minato_protocol:row(description(), columns(), #{return_rows_as_maps => true})
    ).

map_keys_become_atoms_when_asked_test() ->
    ?assertEqual(
        #{id => 42, email => ~"a@b.c", active => true},
        minato_protocol:row(description(), columns(), #{
            return_rows_as_maps => true, column_name_as_atom => true
        })
    ).

atom_keys_do_nothing_to_a_tuple_row_test() ->
    ?assertEqual(
        {42, ~"a@b.c", true},
        minato_protocol:row(description(), columns(), #{column_name_as_atom => true})
    ).

an_empty_description_gives_an_empty_map_test() ->
    ?assertEqual(#{}, minato_protocol:row([], [], #{return_rows_as_maps => true})).

%%----------------------------------------------------------------------
%% Mismatches
%%----------------------------------------------------------------------

a_row_shorter_than_its_description_is_rejected_test() ->
    ?assertError(
        {minato_protocol, #{reason := column_count_mismatch}},
        minato_protocol:row(description(), [<<0, 0, 0, 42>>], #{})
    ).

a_row_longer_than_its_description_is_rejected_test() ->
    ?assertError(
        {minato_protocol, #{reason := column_count_mismatch}},
        minato_protocol:row([field(~"id", 23, binary)], columns(), #{})
    ).

a_mismatch_is_rejected_for_maps_too_test() ->
    ?assertError(
        {minato_protocol, #{reason := column_count_mismatch}},
        minato_protocol:row(description(), [null], #{return_rows_as_maps => true})
    ).

bytes_that_do_not_fit_the_announced_type_raise_a_codec_error_test() ->
    ?assertError(
        {minato_codec, _},
        minato_protocol:row([field(~"id", 23, binary)], [<<1, 2>>], #{})
    ).

%%----------------------------------------------------------------------
%% Whole result sets
%%----------------------------------------------------------------------

rows_decodes_every_row_test() ->
    Description = [field(~"id", 23, binary)],
    ?assertEqual(
        [{1}, {2}, {null}],
        minato_protocol:rows(Description, [[<<0, 0, 0, 1>>], [<<0, 0, 0, 2>>], [null]], #{})
    ).

rows_of_nothing_is_nothing_test() ->
    ?assertEqual([], minato_protocol:rows(description(), [], #{})).

result_test() ->
    ?assertEqual(
        #{command => select, rows => [{1}, {2}], num_rows => 2},
        minato_protocol:result({select, 2}, [{1}, {2}])
    ).

result_reports_the_rows_the_command_touched_not_the_rows_it_returned_test() ->
    ?assertEqual(
        #{command => update, rows => [], num_rows => 7},
        minato_protocol:result({update, 7}, [])
    ).

result_keeps_an_atom_count_test_() ->
    [
        ?_assertEqual(
            #{command => 'begin', rows => [], num_rows => undefined},
            minato_protocol:result({'begin', undefined}, [])
        ),
        ?_assertEqual(
            #{command => create, rows => [], num_rows => table},
            minato_protocol:result({create, table}, [])
        )
    ].

%%----------------------------------------------------------------------
%% Server errors are data
%%----------------------------------------------------------------------

server_error_wraps_the_fields_test() ->
    Fields = #{
        code => ~"23505",
        message => ~"duplicate key value violates unique constraint",
        constraint => ~"users_email_key",
        column => ~"email"
    },
    ?assertEqual({error, {pgsql_error, Fields}}, minato_protocol:server_error(Fields)).

a_decoded_error_response_carries_the_sqlstate_as_code_test() ->
    Bytes = minato_backend_writer:write(
        {error_response, #{
            severity => ~"ERROR",
            code => ~"23503",
            message => ~"insert or update on table violates foreign key constraint",
            constraint => ~"orders_user_id_fkey",
            table => ~"orders"
        }}
    ),
    {[{error_response, Fields}], ~""} = minato_protocol:frame(Bytes),
    ?assertMatch(
        {error, {pgsql_error, #{code := ~"23503", constraint := ~"orders_user_id_fkey"}}},
        minato_protocol:server_error(Fields)
    ).

every_field_key_is_an_atom_and_every_value_a_binary_test() ->
    Bytes = minato_backend_writer:write(
        {error_response, #{
            severity => ~"ERROR",
            code => ~"23514",
            message => ~"check constraint violated",
            position => ~"17",
            line => ~"664"
        }}
    ),
    {[{error_response, Fields}], ~""} = minato_protocol:frame(Bytes),
    ?assert(lists:all(fun is_atom/1, maps:keys(Fields))),
    ?assert(lists:all(fun is_binary/1, maps:values(Fields))).

every_codec_option_reaches_the_codec_test() ->
    Uuid = <<1:128>>,
    Fields = [
        described(~"id", 2950, binary),
        described(~"amount", 1700, binary),
        described(~"at", 1114, binary)
    ],
    Columns = [Uuid, encoded(1700, ~"3.5"), encoded(1114, {{2026, 8, 5}, {12, 0, 0}})],
    Opts = #{
        uuid_format => binary,
        numeric_format => float,
        datetime_format => microseconds
    },
    {Id, Amount, At} = minato_protocol:row(Fields, Columns, Opts),
    ?assertEqual(Uuid, Id),
    ?assertEqual(3.5, Amount),
    ?assert(is_integer(At)).

encoded(Oid, Value) ->
    case minato_codec:encode(Oid, Value, binary) of
        null -> error({unexpected_null, Oid});
        Bytes -> iolist_to_binary(Bytes)
    end.

described(Name, Oid, Format) ->
    #{
        name => Name,
        table_oid => 0,
        column => 0,
        type_oid => Oid,
        type_size => -1,
        type_modifier => -1,
        format => Format
    }.

%%----------------------------------------------------------------------
%% A row straight from the bytes of its message
%%----------------------------------------------------------------------

payload(Columns) ->
    <<(length(Columns)):16, <<<<(sized(Column))/binary>> || Column <- Columns>>/binary>>.

sized(null) -> <<-1:32/signed>>;
sized(Bytes) -> <<(byte_size(Bytes)):32/signed, Bytes/binary>>.

tuples() -> minato_protocol:decoder(description(), #{}).

maps() -> minato_protocol:decoder(description(), #{return_rows_as_maps => true}).

a_payload_decodes_to_a_tuple_test_() ->
    [
        ?_assertEqual(
            {42, ~"a@b.c", true}, minato_protocol:decode_row(tuples(), payload(columns()))
        ),
        ?_assertEqual(
            {null, ~"", null},
            minato_protocol:decode_row(tuples(), payload([null, ~"", null]))
        ),
        ?_assertEqual({}, minato_protocol:decode_row(minato_protocol:decoder([], #{}), <<0:16>>))
    ].

a_payload_decodes_to_a_map_test_() ->
    Atoms = minato_protocol:decoder(description(), #{
        return_rows_as_maps => true, column_name_as_atom => true
    }),
    [
        ?_assertEqual(
            #{~"id" => 42, ~"email" => ~"a@b.c", ~"active" => true},
            minato_protocol:decode_row(maps(), payload(columns()))
        ),
        ?_assertEqual(
            #{~"id" => null, ~"email" => ~"", ~"active" => null},
            minato_protocol:decode_row(maps(), payload([null, ~"", null]))
        ),
        ?_assertEqual(
            #{id => 42, email => ~"a@b.c", active => true},
            minato_protocol:decode_row(Atoms, payload(columns()))
        )
    ].

a_payload_that_does_not_fit_its_columns_is_refused_test_() ->
    Short = payload([<<0, 0, 0, 42>>, ~"a@b.c"]),
    Long = payload(columns() ++ [~"extra"]),
    Trailing = <<(payload(columns()))/binary, 0>>,
    Negative = <<3:16, 4:32, 0, 0, 0, 42, -2:32/signed>>,
    Overrun = <<3:16, 4:32, 0, 0, 0, 42, 9:32, "abc">>,
    [
        {Label, [
            ?_assertError(
                {minato_protocol, #{message := data_row, reason := Reason, data := Data}},
                minato_protocol:decode_row(Decoder, Payload)
            )
         || Decoder <- [tuples(), maps()]
        ]}
     || {Label, Payload, Reason, Data} <- [
            {"fewer columns than described", Short, column_count_mismatch, {1, 0}},
            {"more columns than described", Long, column_count_mismatch, {0, 1}},
            {"bytes after the last column", Trailing, column_count_mismatch, {0, 0}},
            {"a length below minus one", Negative, {negative_column_length, -2}, -2},
            {"a column longer than what is left", Overrun, column_longer_than_the_message, {9, 3}},
            {"no room for a count", <<0>>, malformed, <<0>>},
            {"an empty column the description does not have", payload(columns() ++ [~""]),
                column_count_mismatch, {0, 1}},
            {"a null column the description does not have", payload(columns() ++ [null]),
                column_count_mismatch, {0, 1}},
            {"two null columns the description does not have", payload(columns() ++ [null, null]),
                column_count_mismatch, {0, 2}},
            {"a null column after the count ran out", <<0:16, -1:32/signed>>, column_count_mismatch,
                {3, 0}},
            {"a column after the count ran out", <<0:16, 1:32, "x">>, column_count_mismatch,
                {3, 0}},
            {"a long column after the count ran out", <<0:16, 9:32, "abc">>, column_count_mismatch,
                {3, 0}},
            {"a length below minus one after the count ran out", <<0:16, -2:32/signed>>,
                column_count_mismatch, {3, 0}}
        ]
    ].

the_last_column_is_checked_like_the_others_test_() ->
    One = minato_protocol:decoder([field(~"id", 23, binary)], #{}),
    Map = minato_protocol:decoder([field(~"id", 23, binary)], #{return_rows_as_maps => true}),
    [
        [
            ?_assertError(
                {minato_protocol, #{reason := {negative_column_length, -2}}},
                minato_protocol:decode_row(Decoder, <<1:16, -2:32/signed>>)
            ),
            ?_assertError(
                {minato_protocol, #{reason := column_longer_than_the_message, data := {9, 3}}},
                minato_protocol:decode_row(Decoder, <<1:16, 9:32, "abc">>)
            )
        ]
     || Decoder <- [One, Map]
    ].

a_mismatch_says_how_many_of_each_were_left_test_() ->
    [
        ?_assertError(
            {minato_protocol, #{reason := column_count_mismatch, data := {2, 0}}},
            minato_protocol:row(description(), [<<0, 0, 0, 42>>], Opts)
        )
     || Opts <- [#{}, #{return_rows_as_maps => true}]
    ] ++
        [
            ?_assertError(
                {minato_protocol, #{reason := column_count_mismatch, data := {0, 2}}},
                minato_protocol:row([field(~"id", 23, binary)], columns(), Opts)
            )
         || Opts <- [#{}, #{return_rows_as_maps => true}]
        ].

a_payload_splits_into_its_columns_test_() ->
    [
        ?_assertEqual(columns(), minato_protocol:columns(payload(columns()))),
        ?_assertEqual([null, ~"", null], minato_protocol:columns(payload([null, ~"", null]))),
        ?_assertEqual([], minato_protocol:columns(<<0:16>>)),
        ?_assertError(
            {minato_protocol, #{reason := column_longer_than_the_message, data := {9, 3}}},
            minato_protocol:columns(<<1:16, 9:32, "abc">>)
        ),
        ?_assertError(
            {minato_protocol, #{reason := malformed, data := <<0>>}},
            minato_protocol:columns(<<0>>)
        ),
        ?_assertError(
            {minato_protocol, #{reason := malformed, data := <<0>>}},
            minato_protocol:columns(<<0:16, 0>>)
        ),
        ?_assertError(
            {minato_protocol, #{reason := malformed, data := <<-1:32/signed>>}},
            minato_protocol:columns(<<0:16, -1:32/signed>>)
        ),
        ?_assertError(
            {minato_protocol, #{reason := malformed, data := <<1:32, "x">>}},
            minato_protocol:columns(<<0:16, 1:32, "x">>)
        ),
        ?_assertError(
            {minato_protocol, #{reason := malformed, data := <<-1:32/signed>>}},
            minato_protocol:columns(<<1:16, 1:32, "x", -1:32/signed>>)
        ),
        ?_assertError(
            {minato_protocol, #{reason := {negative_column_length, -2}, data := -2}},
            minato_protocol:columns(<<1:16, -2:32/signed>>)
        ),
        ?_assertError(
            {minato_protocol, #{reason := malformed, data := <<-2:32/signed>>}},
            minato_protocol:columns(<<0:16, -2:32/signed>>)
        )
    ].
