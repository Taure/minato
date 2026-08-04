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
