-module(minato_query_tests).
-moduledoc """
`m:minato_query` against a server that says exactly what each case needs.

`minato_query_SUITE` and `minato_cache_SUITE` ask a real PostgreSQL for the
answers. What is asked here is what goes over the wire to get them: which
messages each path sends, how many times it stops to wait for the server, and
what it makes of every answer a server can give, including the ones a real
server only gives after a table changed under a statement it had parsed.

A round trip is a write the client waits on, and the client waits only behind
`Flush`, `Sync` and a simple `Query`, so counting those in what the server read
counts the round trips.
""".

-include_lib("eunit/include/eunit.hrl").

-export([event/4]).

-define(INT4, 23).
-define(INT8, 20).
-define(TEXT, 25).

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).
-define(IDLE, [{ready_for_query, idle}]).
-define(FAILED, [{ready_for_query, failed}]).
-define(SQL, ~"SELECT a FROM t WHERE a = $1").

%%----------------------------------------------------------------------
%% Round trips
%%----------------------------------------------------------------------

a_simple_query_is_one_round_trip_test() ->
    {Server, Conn} = connected([selected([~"1"])]),
    {ok, [Result], _Read} = minato_query:simple(Conn, ~"SELECT 1"),
    ?assertMatch(#{command := select, rows := [{~"1"}]}, Result),
    ?assertEqual([{query, ~"SELECT 1"}], asked(Server)).

an_unnamed_statement_is_two_round_trips_test() ->
    {Server, Conn} = connected(parsed([?INT4], [?INT4]) ++ ran([<<7:32>>])),
    {ok, Result, _Read} = minato_query:query(Conn, ?SQL, [7]),
    ?assertMatch(#{rows := [{7}]}, Result),
    Asked = asked(Server),
    ?assertEqual([parse, describe, flush, bind, execute, sync], kinds(Asked)),
    ?assertMatch([{parse, ~"", ?SQL, []}, {describe, statement, ~""} | _Rest], Asked),
    ?assertEqual(2, round_trips(Asked)).

a_statement_kept_for_the_first_time_is_two_round_trips_test() ->
    {Server, Conn} = connected(parsed([?INT4], [?INT4]) ++ ran([<<7:32>>])),
    {ok, Result, Kept} = minato_query:cached(Conn, ?SQL, [7]),
    ?assertMatch(#{rows := [{7}]}, Result),
    ?assertEqual({1, 64}, minato_conn:statements(Kept)),
    Asked = asked(Server),
    ?assertEqual([parse, describe, flush, bind, execute, sync], kinds(Asked)),
    [{parse, Name, ?SQL, []}, {describe, statement, Name}, flush, Bind | _Rest] = Asked,
    ?assertEqual(~"minato_", binary:part(Name, 0, 7)),
    ?assertEqual({bind, ~"", Name, [binary], [<<7:32>>], [binary]}, Bind),
    ?assertEqual(2, round_trips(Asked)).

a_kept_statement_is_one_round_trip_test() ->
    Script = parsed([?INT4], [?INT4]) ++ ran([<<7:32>>]) ++ ran([<<8:32>>]),
    {Server, Conn} = connected(Script),
    {ok, _First, Kept} = minato_query:cached(Conn, ?SQL, [7]),
    [{parse, Name, _Sql, _Oids} | _Others] = asked(Server),
    {ok, Result, _Read} = minato_query:cached(Kept, ?SQL, [8]),
    ?assertMatch(#{rows := [{8}]}, Result),
    ?assertEqual(
        [{bind, ~"", Name, [binary], [<<8:32>>], [binary]}, {execute, ~"", 0}, sync],
        asked(Server)
    ).

preparing_is_one_round_trip_and_executing_another_test() ->
    Script = prepared([?INT4], [?INT4]) ++ ran([<<7:32>>]),
    {Server, Conn} = connected(Script),
    {ok, Statement, Ready} = minato_query:prepare(Conn, ~"mine", ?SQL),
    ?assertEqual(
        [{parse, ~"mine", ?SQL, []}, {describe, statement, ~"mine"}, sync], asked(Server)
    ),
    {ok, Result, _Read} = minato_query:execute(Ready, Statement, [7]),
    ?assertMatch(#{rows := [{7}]}, Result),
    ?assertEqual([bind, execute, sync], kinds(asked(Server))).

a_statement_that_returns_nothing_is_prepared_test() ->
    Script = [[parse_complete], [{parameter_description, []}, no_data], ?IDLE],
    {_Server, Conn} = connected(
        Script ++ [[bind_complete], [{command_complete, ~"UPDATE 3"}], ?IDLE]
    ),
    {ok, Statement, Ready} = minato_query:prepare(Conn, ~"mine", ~"UPDATE t SET a = 1"),
    {ok, Result, _Read} = minato_query:execute(Ready, Statement, []),
    ?assertMatch(#{command := update, num_rows := 3, rows := []}, Result).

closing_is_one_round_trip_test() ->
    Script = prepared([], [?INT4]) ++ [[close_complete], ?IDLE],
    {Server, Conn} = connected(Script),
    {ok, Statement, Ready} = minato_query:prepare(Conn, ~"mine", ~"SELECT 1"),
    _ = asked(Server),
    ?assertMatch({ok, _Closed}, minato_query:close(Ready, Statement)),
    ?assertEqual([{close, statement, ~"mine"}, sync], asked(Server)).

%%----------------------------------------------------------------------
%% A statement the server will not parse
%%----------------------------------------------------------------------

a_refused_parse_leaves_the_connection_in_step_test_() ->
    [
        {atom_to_list(Status), fun() ->
            Script = [[refused(~"42601")], [], [], [{ready_for_query, Status}], selected([~"1"])],
            {Server, Conn} = connected(Script),
            {error, {pgsql_error, #{code := Code}}, Read} = minato_query:cached(Conn, ?SQL, [7]),
            ?assertEqual(~"42601", Code),
            ?assertEqual(Status, minato_conn:transaction_status(Read)),
            ?assertEqual({0, 64}, minato_conn:statements(Read)),
            ?assertEqual([parse, describe, flush, sync], kinds(asked(Server))),
            ?assertMatch({ok, [#{rows := [{~"1"}]}], _Next}, minato_query:simple(Read, ~"SELECT 1"))
        end}
     || Status <- [idle, failed]
    ].

an_unnamed_statement_the_server_will_not_parse_is_ended_with_one_sync_test() ->
    Script = [[refused(~"42601")], [], [], ?IDLE],
    {Server, Conn} = connected(Script),
    ?assertMatch({error, {pgsql_error, _Fields}, _Read}, minato_query:query(Conn, ?SQL, [7])),
    ?assertEqual([parse, describe, flush, sync], kinds(asked(Server))).

a_refused_prepare_is_read_to_its_end_without_another_sync_test_() ->
    [
        {atom_to_list(Status), fun() ->
            Script = [[refused(~"42601")], [], [{ready_for_query, Status}], selected([~"1"])],
            {Server, Conn} = connected(Script),
            {error, {pgsql_error, #{code := Code}}, Read} =
                minato_query:prepare(Conn, ~"mine", ?SQL),
            ?assertEqual(~"42601", Code),
            ?assertEqual(Status, minato_conn:transaction_status(Read)),
            ?assertEqual([parse, describe, sync], kinds(asked(Server))),
            ?assertMatch({ok, [#{rows := [{~"1"}]}], _Next}, minato_query:simple(Read, ~"SELECT 1"))
        end}
     || Status <- [idle, failed]
    ].

a_notice_while_preparing_is_passed_over_test() ->
    Noticed = [{notice_response, #{severity => ~"NOTICE", code => ~"00000", message => ~"hm"}}],
    Script = [Noticed ++ [parse_complete], [{parameter_description, []}, no_data], ?IDLE],
    {_Server, Conn} = connected(Script),
    ?assertMatch({ok, _Statement, _Ready}, minato_query:prepare(Conn, ~"mine", ~"SELECT")).

%% Both can arrive at any time: a `NOTIFY` for a channel the session listens
%% on, and a setting the server reloaded.
what_the_server_says_unasked_while_preparing_is_passed_over_test_() ->
    [
        {atom_to_list(element(1, Unasked)), fun() ->
            Script = [[Unasked, parse_complete], [{parameter_description, []}, no_data], ?IDLE],
            {_Server, Conn} = connected(Script),
            ?assertMatch({ok, _Statement, _Ready}, minato_query:prepare(Conn, ~"mine", ~"SELECT"))
        end}
     || Unasked <- [
            {notification_response, 77, ~"channel", ~"payload"},
            {parameter_status, ~"TimeZone", ~"Europe/Stockholm"}
        ]
    ].

an_answer_that_does_not_belong_to_a_describe_is_raised_test() ->
    {_Server, Conn} = connected([[bind_complete]]),
    ?assertError(
        {minato_query, #{message := describe, reason := unexpected_message, data := bind_complete}},
        minato_query:prepare(Conn, ~"mine", ~"SELECT")
    ).

%%----------------------------------------------------------------------
%% A statement kept for the first time that does not run
%%----------------------------------------------------------------------

a_first_use_the_server_refuses_to_run_keeps_the_statement_test() ->
    Refused = [[], [], [refused(~"22012")] ++ ?IDLE],
    Script = parsed([?INT4], [?INT4]) ++ Refused ++ ran([<<8:32>>]),
    {Server, Conn} = connected(Script),
    {error, {pgsql_error, #{code := Code}}, Kept} = minato_query:cached(Conn, ?SQL, [7]),
    ?assertEqual(~"22012", Code),
    ?assertEqual({1, 64}, minato_conn:statements(Kept)),
    _ = asked(Server),
    ?assertMatch({ok, #{rows := [{8}]}, _Read}, minato_query:cached(Kept, ?SQL, [8])),
    ?assertEqual([bind, execute, sync], kinds(asked(Server))).

a_first_use_with_a_value_that_does_not_fit_closes_what_it_parsed_test() ->
    Script = parsed([?INT4], [?INT4]) ++ [?IDLE, [close_complete], ?IDLE, selected([~"1"])],
    {Server, Conn} = connected(Script),
    ?assertError(
        {minato_codec, #{reason := not_an_integer}}, minato_query:cached(Conn, ?SQL, [~"seven"])
    ),
    Asked = asked(Server),
    ?assertEqual([parse, describe, flush, sync, close, sync], kinds(Asked)),
    [{parse, Name, _Sql, _Oids} | _Rest] = Asked,
    ?assert(lists:member({close, statement, Name}, Asked)),
    ?assertMatch({ok, [#{rows := [{~"1"}]}], _Next}, minato_query:simple(Conn, ~"SELECT 1")).

a_first_use_with_the_wrong_number_of_values_closes_what_it_parsed_test() ->
    Script = parsed([?INT4], [?INT4]) ++ [?IDLE, [close_complete], ?IDLE],
    {Server, Conn} = connected(Script),
    ?assertError(
        {minato_query, #{message := bind, reason := parameter_count_mismatch, data := {1, 2}}},
        minato_query:cached(Conn, ?SQL, [7, 8])
    ),
    ?assertEqual([parse, describe, flush, sync, close, sync], kinds(asked(Server))).

an_unnamed_statement_with_a_value_that_does_not_fit_is_ended_with_a_sync_test() ->
    Script = parsed([?INT4], [?INT4]) ++ [?IDLE, selected([~"1"])],
    {Server, Conn} = connected(Script),
    ?assertError({minato_codec, _Report}, minato_query:query(Conn, ?SQL, [~"seven"])),
    ?assertEqual([parse, describe, flush, sync], kinds(asked(Server))),
    ?assertMatch({ok, [#{rows := [{~"1"}]}], _Next}, minato_query:simple(Conn, ~"SELECT 1")).

a_sync_that_is_never_answered_closes_the_connection_under_the_raise_test() ->
    {Server, Conn} = connected(parsed([?INT4], [?INT4]), #{timeout => 100}),
    ?assertError({minato_codec, _Report}, minato_query:query(Conn, ?SQL, [~"seven"])),
    ?assert(lists:member(terminate, kinds(asked(Server, 500)))).

a_value_that_does_not_fit_is_raised_on_a_connection_already_closed_test() ->
    {_Server, Conn} = connected(prepared([?INT4], [?INT4])),
    {ok, Statement, Ready} = minato_query:prepare(Conn, ~"mine", ?SQL),
    ok = minato_conn:close(Ready),
    ?assertError(
        {minato_codec, #{reason := not_an_integer}},
        minato_query:execute(Ready, Statement, [~"seven"])
    ).

%%----------------------------------------------------------------------
%% A kept statement the server stops accepting
%%----------------------------------------------------------------------

a_plan_that_changed_is_parsed_again_and_run_once_more_test() ->
    Script =
        kept() ++ stale(~"0A000", idle) ++ [[close_complete], ?IDLE] ++
            parsed([?INT4], [?INT8]) ++ ran([<<9:64>>]),
    {Server, Conn} = connected(Script),
    {Name, Kept} = keep(Server, Conn),
    {ok, Result, Renewed} = minato_query:cached(Kept, ?SQL, [7]),
    ?assertMatch(#{rows := [{9}]}, Result),
    ?assertEqual({1, 64}, minato_conn:statements(Renewed)),
    Asked = asked(Server),
    ?assertEqual(
        [bind, execute, sync, close, sync, parse, describe, flush, bind, execute, sync],
        kinds(Asked)
    ),
    ?assert(lists:member({close, statement, Name}, Asked)),
    [Again] = [Parsed || {parse, Parsed, _Sql, _Oids} <- Asked],
    ?assertNotEqual(Name, Again).

a_plan_that_changed_twice_is_returned_and_not_run_a_third_time_test() ->
    Script =
        kept() ++ stale(~"0A000", idle) ++ [[close_complete], ?IDLE] ++
            parsed([?INT4], [?INT4]) ++ stale(~"0A000", idle) ++ ran([<<9:32>>]),
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    ?assertMatch(
        {error, {pgsql_error, #{code := ~"0A000"}}, _Read}, minato_query:cached(Kept, ?SQL, [7])
    ),
    ?assertEqual(
        [bind, execute, sync, close, sync, parse, describe, flush, bind, execute, sync],
        kinds(asked(Server))
    ).

%% A pooler that follows named statements parses one again on a backend that
%% has not seen it. After a column was added that is another statement than
%% the one described here, and `Bind` is refused over the count.
a_statement_bound_with_the_wrong_number_of_columns_is_parsed_again_test() ->
    Script =
        kept() ++ stale(~"08P01", idle) ++ [[close_complete], ?IDLE] ++
            parsed([?INT4], [?INT4, ?INT4]) ++ ran([<<9:32>>, null]),
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    ?assertMatch({ok, #{rows := [{9, null}]}, _Read}, minato_query:cached(Kept, ?SQL, [7])),
    ?assertEqual(
        [bind, execute, sync, close, sync, parse, describe, flush, bind, execute, sync],
        kinds(asked(Server))
    ).

a_plan_that_changed_inside_a_transaction_is_not_run_again_test() ->
    Script = kept() ++ stale(~"0A000", failed) ++ [[close_complete], ?FAILED],
    {Server, Conn} = connected(Script),
    {Name, Kept} = keep(Server, Conn),
    {error, {pgsql_error, #{code := Code}}, Aborted} = minato_query:cached(Kept, ?SQL, [7]),
    ?assertEqual(~"0A000", Code),
    ?assertEqual(failed, minato_conn:transaction_status(Aborted)),
    ?assertEqual({0, 64}, minato_conn:statements(Aborted)),
    ?assertEqual(
        [bind, execute, sync, {close, statement, Name}, sync],
        [named(Message) || Message <- asked(Server)]
    ).

%% A statement that has been bound has started, and one that does something
%% outside its transaction before it fails has done it. `nextval` is the plain
%% case. Whatever the code, such a failure is the statement's own.
a_statement_that_failed_once_it_was_running_is_not_run_again_test_() ->
    Counting = ~"SELECT nextval('issued') FROM t WHERE a = $1",
    [
        {binary_to_list(Code), fun() ->
            Script = kept() ++ [[bind_complete], [refused(Code)], ?IDLE] ++ ran([<<9:32>>]),
            {Server, Conn} = connected(Script),
            {ok, _First, Kept} = minato_query:cached(Conn, Counting, [1]),
            _ = asked(Server),
            {error, {pgsql_error, #{code := Returned}}, Read} =
                minato_query:cached(Kept, Counting, [7]),
            ?assertEqual(Code, Returned),
            ?assertEqual([bind, execute, sync], kinds(at_rest(Server))),
            ?assertEqual({1, 64}, minato_conn:statements(Read)),
            ?assertEqual(idle, minato_conn:transaction_status(Read))
        end}
     || Code <- [~"0A000", ~"08P01", ~"26000", ~"42883"]
    ].

%% A statement that ran says so with BindComplete first. An answer without it
%% is not one to this statement, whatever it goes on to claim was done. The
%% raise names what arrived and does not quote it, since it can be a row.
an_answer_that_was_never_bound_is_not_a_result_test_() ->
    [
        {atom_to_list(Kind), fun() ->
            {_Server, Conn} = connected(kept() ++ [Unbound ++ ?IDLE]),
            {ok, _First, Kept} = minato_query:cached(Conn, ?SQL, [1]),
            ?assertError(
                {minato_query, #{message := execute, reason := unexpected_message, data := Kind}},
                minato_query:cached(Kept, ?SQL, [7])
            )
        end}
     || {Kind, Unbound} <- [
            {ready_for_query, []},
            {command_complete, [{command_complete, ~"INSERT 0 1"}]},
            {rows, [{data_row, [<<9:32>>]}, {command_complete, ~"SELECT 1"}]},
            {row_description, [{row_description, []}]},
            {empty_query_response, [empty_query_response]}
        ]
    ].

what_the_server_says_unasked_before_the_bind_is_answered_is_passed_over_test_() ->
    [
        {atom_to_list(element(1, Unasked)), fun() ->
            Answered = [{data_row, [<<9:32>>]}, {command_complete, ~"SELECT 1"}],
            Script = kept() ++ [[Unasked, bind_complete], Answered, ?IDLE],
            {_Server, Conn} = connected(Script),
            {ok, _First, Kept} = minato_query:cached(Conn, ?SQL, [1]),
            ?assertMatch({ok, #{rows := [{9}]}, _Read}, minato_query:cached(Kept, ?SQL, [7]))
        end}
     || Unasked <- [
            {notice_response, #{severity => ~"NOTICE", code => ~"00000", message => ~"hm"}},
            {notification_response, 77, ~"channel", ~"payload"},
            {parameter_status, ~"TimeZone", ~"Europe/Stockholm"}
        ]
    ].

an_answer_that_belongs_to_a_parse_is_raised_where_the_bind_was_awaited_test_() ->
    [
        {atom_to_list(kind(Misplaced)), fun() ->
            {_Server, Conn} = connected(kept() ++ [[Misplaced]]),
            {ok, _First, Kept} = minato_query:cached(Conn, ?SQL, [1]),
            ?assertError(
                {minato_query, #{message := execute, reason := unexpected_message}},
                minato_query:cached(Kept, ?SQL, [7])
            )
        end}
     || Misplaced <- [parse_complete, no_data, {parameter_description, [?INT4]}]
    ].

a_bind_that_is_never_answered_is_an_error_test() ->
    {_Server, Conn} = connected(kept(), #{timeout => 100}),
    {ok, _First, Kept} = minato_query:cached(Conn, ?SQL, [1]),
    ?assertMatch({error, _Reason}, minato_query:cached(Kept, ?SQL, [7])).

a_refusal_that_is_never_followed_by_ready_is_an_error_test() ->
    {_Server, Conn} = connected(kept() ++ [[refused(~"0A000")]], #{timeout => 100}),
    {ok, _First, Kept} = minato_query:cached(Conn, ?SQL, [1]),
    ?assertMatch({error, _Reason}, minato_query:cached(Kept, ?SQL, [7])).

a_statement_the_server_no_longer_has_is_parsed_again_test() ->
    Script = kept() ++ stale(~"26000", idle) ++ parsed([?INT4], [?INT4]) ++ ran([<<9:32>>]),
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    ?assertMatch({ok, #{rows := [{9}]}, _Read}, minato_query:cached(Kept, ?SQL, [7])),
    ?assertEqual(
        [bind, execute, sync, parse, describe, flush, bind, execute, sync],
        kinds(asked(Server))
    ).

a_statement_gone_inside_a_transaction_is_returned_test() ->
    Script = kept() ++ stale(~"26000", failed),
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    {error, {pgsql_error, #{code := Code}}, Aborted} = minato_query:cached(Kept, ?SQL, [7]),
    ?assertEqual(~"26000", Code),
    ?assertEqual({0, 64}, minato_conn:statements(Aborted)),
    ?assertEqual([bind, execute, sync], kinds(asked(Server))).

an_error_that_is_about_the_data_is_returned_as_it_is_test() ->
    Script = kept() ++ stale(~"23505", idle),
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    {error, {pgsql_error, #{code := Code}}, Read} = minato_query:cached(Kept, ?SQL, [7]),
    ?assertEqual(~"23505", Code),
    ?assertEqual({1, 64}, minato_conn:statements(Read)),
    ?assertEqual([bind, execute, sync], kinds(asked(Server))).

%%----------------------------------------------------------------------
%% A kept statement whose parameters the server would now describe otherwise
%%----------------------------------------------------------------------

%% The column the parameter is compared with was an integer when the statement
%% was parsed and is text now. The value is right for what the table is.
a_value_for_what_the_table_has_become_is_not_refused_test() ->
    Script =
        kept() ++ prepared([?TEXT], [?TEXT]) ++ [[close_complete], ?IDLE] ++
            parsed([?TEXT], [?TEXT]) ++ ran([~"seven"]),
    {Server, Conn} = connected(Script),
    {Name, Kept} = keep(Server, Conn),
    {ok, Result, Renewed} = minato_query:cached(Kept, ?SQL, [~"seven"]),
    ?assertMatch(#{rows := [{~"seven"}]}, Result),
    ?assertEqual({1, 64}, minato_conn:statements(Renewed)),
    Asked = asked(Server),
    ?assertEqual(
        [parse, describe, sync, close, sync, parse, describe, flush, bind, execute, sync],
        kinds(Asked)
    ),
    ?assertMatch([{parse, ~"", ?SQL, []}, {describe, statement, ~""}, sync | _Rest], Asked),
    ?assert(lists:member({close, statement, Name}, Asked)),
    ?assertMatch({bind, ~"", _New, [binary], [~"seven"], [binary]}, lists:keyfind(bind, 1, Asked)).

a_value_that_fits_neither_is_raised_once_the_server_has_been_asked_test() ->
    Script = kept() ++ prepared([?INT4], [?INT4]) ++ ran([<<8:32>>]),
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    ?assertError(
        {minato_codec, #{reason := not_an_integer}}, minato_query:cached(Kept, ?SQL, [~"seven"])
    ),
    ?assertEqual([parse, describe, sync], kinds(asked(Server))),
    ?assertMatch({ok, #{rows := [{8}]}, _Read}, minato_query:cached(Kept, ?SQL, [8])),
    ?assertEqual([bind, execute, sync], kinds(asked(Server))).

a_value_that_does_not_fit_in_a_failed_transaction_asks_nothing_test() ->
    Script = kept() ++ stale(~"22012", failed),
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    {error, _Divided, Aborted} = minato_query:cached(Kept, ?SQL, [7]),
    _ = asked(Server),
    ?assertError({minato_codec, _Report}, minato_query:cached(Aborted, ?SQL, [~"seven"])),
    ?assertEqual([], at_rest(Server)).

%% Asking the server what it makes of the statement now is a `Parse` inside
%% the caller's transaction, and one the server refuses aborts it.
a_value_that_does_not_fit_in_an_open_transaction_asks_nothing_test() ->
    Open = [
        [bind_complete],
        [{data_row, [<<1:32>>]}, {command_complete, ~"SELECT 1"}],
        [{ready_for_query, transaction}]
    ],
    {Server, Conn} = connected(parsed([?INT4], [?INT4]) ++ Open),
    {_Name, Kept} = keep(Server, Conn),
    ?assertEqual(transaction, minato_conn:transaction_status(Kept)),
    ?assertError(
        {minato_codec, #{reason := not_an_integer}}, minato_query:cached(Kept, ?SQL, [~"seven"])
    ),
    ?assertEqual([], at_rest(Server)).

a_statement_that_no_longer_parses_is_returned_as_the_server_put_it_test() ->
    Script = kept() ++ [[refused(~"42P01")], [], ?IDLE],
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    ?assertMatch(
        {error, {pgsql_error, #{code := ~"42P01"}}, _Read},
        minato_query:cached(Kept, ?SQL, [~"seven"])
    ),
    ?assertEqual([parse, describe, sync], kinds(asked(Server))).

the_wrong_number_of_values_for_a_kept_statement_asks_nothing_test() ->
    {Server, Conn} = connected(kept() ++ ran([<<8:32>>])),
    {_Name, Kept} = keep(Server, Conn),
    ?assertError(
        {minato_query, #{reason := parameter_count_mismatch, data := {1, 0}}},
        minato_query:cached(Kept, ?SQL, [])
    ),
    ?assertEqual([], at_rest(Server)),
    ?assertMatch({ok, #{rows := [{8}]}, _Read}, minato_query:cached(Kept, ?SQL, [8])).

%% The server refuses the statement it kept, over the types it was parsed
%% with: the operator it was planned around no longer exists for them.
a_refusal_over_types_that_have_changed_is_parsed_again_test() ->
    Script =
        kept() ++ stale(~"42883", idle) ++ prepared([?INT8], [?INT8]) ++
            [[close_complete], ?IDLE] ++ parsed([?INT8], [?INT8]) ++ ran([<<7:64>>]),
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    ?assertMatch({ok, #{rows := [{7}]}, _Read}, minato_query:cached(Kept, ?SQL, [7])),
    ?assertEqual(
        [
            bind,
            execute,
            sync,
            parse,
            describe,
            sync,
            close,
            sync,
            parse,
            describe,
            flush,
            bind,
            execute,
            sync
        ],
        kinds(asked(Server))
    ).

a_refusal_over_types_that_have_not_changed_is_returned_test() ->
    Script = kept() ++ stale(~"42883", idle) ++ prepared([?INT4], [?INT4]) ++ ran([<<8:32>>]),
    {Server, Conn} = connected(Script),
    {_Name, Kept} = keep(Server, Conn),
    {error, {pgsql_error, #{code := Code}}, Read} = minato_query:cached(Kept, ?SQL, [7]),
    ?assertEqual(~"42883", Code),
    ?assertEqual({1, 64}, minato_conn:statements(Read)),
    ?assertEqual([bind, execute, sync, parse, describe, sync], kinds(asked(Server))),
    ?assertMatch({ok, #{rows := [{8}]}, _Next}, minato_query:cached(Read, ?SQL, [8])),
    ?assertEqual([bind, execute, sync], kinds(asked(Server))).

a_refusal_over_types_inside_a_transaction_drops_the_statement_test() ->
    Script = kept() ++ stale(~"42883", failed) ++ [[close_complete], ?FAILED],
    {Server, Conn} = connected(Script),
    {Name, Kept} = keep(Server, Conn),
    {error, {pgsql_error, #{code := Code}}, Aborted} = minato_query:cached(Kept, ?SQL, [7]),
    ?assertEqual(~"42883", Code),
    ?assertEqual({0, 64}, minato_conn:statements(Aborted)),
    ?assertEqual(
        [bind, execute, sync, {close, statement, Name}, sync],
        [named(Message) || Message <- asked(Server)]
    ).

a_refused_statement_without_parameters_is_not_asked_about_test() ->
    Sql = ~"SELECT f()",
    Script = parsed([], [?INT4]) ++ ran([<<7:32>>]) ++ stale(~"42883", idle),
    {Server, Conn} = connected(Script),
    {ok, _First, Kept} = minato_query:cached(Conn, Sql, []),
    _ = asked(Server),
    ?assertMatch(
        {error, {pgsql_error, #{code := ~"42883"}}, _Read}, minato_query:cached(Kept, Sql, [])
    ),
    ?assertEqual([bind, execute, sync], kinds(asked(Server))).

%%----------------------------------------------------------------------
%% Room that a statement no longer kept gives back
%%----------------------------------------------------------------------

a_parse_the_server_refused_takes_no_room_test() ->
    Script = [[refused(~"42P01")], [], [], ?IDLE] ++ parsed([?INT4], [?INT4]) ++ ran([<<7:32>>]),
    {Server, Conn} = connected(Script, #{prepared_statements => 1}),
    {error, {pgsql_error, #{code := ~"42P01"}}, Read} = minato_query:cached(Conn, ?SQL, [7]),
    [{parse, Refused, _Sql, _Oids} | _Rest] = asked(Server),
    {ok, _Result, Kept} = minato_query:cached(Read, ?SQL, [7]),
    [{parse, Name, _Again, _Types} | _Run] = asked(Server),
    ?assertNotEqual(~"", Name),
    ?assertNotEqual(Refused, Name),
    ?assertEqual({1, 1}, minato_conn:statements(Kept)).

a_statement_parsed_again_is_kept_again_test() ->
    Script =
        kept() ++ stale(~"0A000", idle) ++ [[close_complete], ?IDLE] ++
            parsed([?INT4], [?INT4]) ++ ran([<<9:32>>]) ++ ran([<<9:32>>]),
    {Server, Conn} = connected(Script, #{prepared_statements => 1}),
    {Name, Kept} = keep(Server, Conn),
    {ok, _Result, Renewed} = minato_query:cached(Kept, ?SQL, [7]),
    ?assertEqual({1, 1}, minato_conn:statements(Renewed)),
    [Again] = [Parsed || {parse, Parsed, _Sql, _Oids} <- asked(Server)],
    ?assertNotEqual(~"", Again),
    ?assertNotEqual(Name, Again),
    ?assertMatch({ok, #{rows := [{9}]}, _Read}, minato_query:cached(Renewed, ?SQL, [7])),
    ?assertEqual([bind, execute, sync], kinds(asked(Server))).

a_statement_dropped_in_a_failed_transaction_gives_its_room_back_test() ->
    Other = ~"SELECT b FROM t WHERE b = $1",
    Script =
        kept() ++ stale(~"42883", failed) ++ [[close_complete], ?FAILED] ++
            parsed([?INT4], [?INT4]) ++ ran([<<5:32>>]),
    {Server, Conn} = connected(Script, #{prepared_statements => 1}),
    {_Name, Kept} = keep(Server, Conn),
    {error, {pgsql_error, #{code := ~"42883"}}, Aborted} = minato_query:cached(Kept, ?SQL, [7]),
    _ = asked(Server),
    {ok, _Result, Read} = minato_query:cached(Aborted, Other, [5]),
    [{parse, Name, _Sql, _Oids} | _Run] = asked(Server),
    ?assertNotEqual(~"", Name),
    ?assertEqual({1, 1}, minato_conn:statements(Read)).

a_name_is_never_handed_out_twice_test() ->
    {_Server, Conn} = connected([], #{prepared_statements => 2}),
    {First, Claimed} = minato_conn:claim(Conn),
    Kept = minato_conn:remember(Claimed, ~"a", kept),
    {Second, Again} = minato_conn:claim(minato_conn:forget(Kept, ~"a")),
    {Third, Full} = minato_conn:claim(minato_conn:remember(Again, ~"b", kept)),
    ?assert(lists:all(fun is_binary/1, [First, Second, Third])),
    ?assertEqual(3, length(lists:usort([First, Second, Third]))),
    ?assertEqual(
        {undefined, minato_conn:remember(Full, ~"c", kept)},
        minato_conn:claim(minato_conn:remember(Full, ~"c", kept))
    ).

%%----------------------------------------------------------------------
%% A connection with no room to keep a statement
%%----------------------------------------------------------------------

a_connection_that_keeps_nothing_runs_unnamed_test() ->
    Script = parsed([?INT4], [?INT4]) ++ ran([<<7:32>>]),
    {Server, Conn} = connected(Script, #{prepared_statements => 0}),
    {ok, Result, Read} = minato_query:cached(Conn, ?SQL, [7]),
    ?assertMatch(#{rows := [{7}]}, Result),
    ?assertEqual({0, 0}, minato_conn:statements(Read)),
    ?assertMatch([{parse, ~"", ?SQL, []} | _Rest], asked(Server)).

%% A statement past its deadline is cancelled on a second connection, which is
%% how the deadline shows here.
a_statement_run_unnamed_for_want_of_room_keeps_its_deadline_test() ->
    Slow = {then, [], 400, [{ready_for_query, idle}]},
    Script = parsed([], [?INT4]) ++ [[bind_complete], [], Slow],
    {Server, Conn} = connected(Script, #{prepared_statements => 0, timeout => 5000}),
    _ = minato_query:cached(Conn, ~"SELECT pg_sleep(9)", [], #{timeout => 100}),
    ?assert(lists:member({cancel_request, 4242, 777}, at_rest(Server))).

%%----------------------------------------------------------------------
%% How long a statement may run
%%----------------------------------------------------------------------

%% Text out of the environment was a `badarith`, a fraction a read that raised
%% in the middle of the answer, and a negative number a statement cancelled as
%% soon as it was sent.
a_time_that_is_not_one_is_refused_before_anything_is_sent_test_() ->
    [
        {lists:flatten(io_lib:format("~p given ~p", [Path, Timeout])), fun() ->
            {Server, Conn} = connected(prepared([], [?TEXT]) ++ [selected([~"1"])]),
            {ok, Statement, Ready} = minato_query:prepare(Conn, ~"mine", ~"SELECT 1"),
            _ = asked(Server),
            ?assertError(
                {minato_query, #{
                    message := options, reason := {invalid_option, timeout}, data := timeout
                }},
                timed(Path, Ready, Statement, Timeout)
            ),
            ?assertMatch({ok, [#{rows := [{~"1"}]}], _Read}, minato_query:simple(Ready, ~"s")),
            ?assertEqual([{query, ~"s"}], asked(Server))
        end}
     || Path <- [simple, query, cached, execute],
        Timeout <- ["5000", ~"5000", -1, 1.5, never]
    ].

%% Options the type forbids, because what is checked is that they are refused
%% at run time too.
-spec timed(atom(), minato_conn:conn(), minato_query:statement(), term()) -> dynamic().
timed(Path, Conn, Statement, Timeout) ->
    Opts = lasting(Timeout),
    case Path of
        simple -> minato_query:simple(Conn, ~"SELECT 1", Opts);
        query -> minato_query:query(Conn, ?SQL, [1], Opts);
        cached -> minato_query:cached(Conn, ?SQL, [1], Opts);
        execute -> minato_query:execute(Conn, Statement, [], Opts)
    end.

-spec lasting(term()) -> dynamic().
lasting(Timeout) ->
    #{timeout => Timeout}.

a_statement_may_be_given_no_deadline_test() ->
    {_Server, Conn} = connected([selected([~"1"])]),
    ?assertMatch(
        {ok, [#{rows := [{~"1"}]}], _Read},
        minato_query:simple(Conn, ~"SELECT 1", #{timeout => infinity})
    ).

%%----------------------------------------------------------------------
%% What a query reports of itself
%%----------------------------------------------------------------------

a_result_is_reported_with_its_command_and_its_rows_test() ->
    {_Server, Conn} = connected(parsed([?INT4], [?INT4]) ++ ran([<<7:32>>])),
    ?assertMatch(
        [{start, _Asked}, {stop, #{outcome := ok, command := select, num_rows := 1}}],
        events(fun() -> minato_query:query(Conn, ?SQL, [7]) end)
    ).

a_simple_query_is_reported_with_how_many_statements_it_ran_test() ->
    {_Server, Conn} = connected([selected([~"1"])]),
    [{start, _Asked}, {stop, Stop}] =
        events(fun() -> minato_query:simple(Conn, ~"SELECT 1") end),
    ?assertMatch(#{outcome := ok, statements := 1}, Stop),
    ?assertNot(is_map_key(reason, Stop)).

a_refusal_is_reported_without_what_the_server_quoted_test() ->
    {_Server, Conn} = connected([[refused(~"42601")], [], [], ?IDLE]),
    [{start, _Asked}, {stop, Stop}] =
        events(fun() -> minato_query:query(Conn, ?SQL, [7]) end),
    ?assertMatch(#{outcome := error, reason := {pgsql_error, #{code := ~"42601"}}}, Stop),
    #{reason := {pgsql_error, Fields}} = Stop,
    ?assertNot(is_map_key(message, Fields)).

a_connection_that_stops_answering_is_reported_as_an_error_test() ->
    {_Server, Conn} = connected([], #{timeout => 100}),
    Self = self(),
    [{start, _Asked}, {stop, Stop}] =
        events(fun() -> Self ! {answered, minato_query:simple(Conn, ~"SELECT 1")} end),
    Reason =
        receive
            {answered, {error, Lost}} -> Lost
        after 0 -> error(not_answered)
        end,
    ?assertMatch(#{outcome := error, reason := Reason}, Stop).

a_prepared_statement_is_reported_under_its_name_test() ->
    Script = prepared([?INT4], [?INT4]) ++ ran([<<7:32>>]),
    {_Server, Conn} = connected(Script),
    {ok, Statement, Ready} = minato_query:prepare(Conn, ~"mine", ?SQL),
    ok = application:set_env(minato, log_statements, true),
    try
        ?assertMatch(
            [
                {start, #{path := prepared, sql := ~"mine"}},
                {stop, #{path := prepared, outcome := ok, num_rows := 1}}
            ],
            events(fun() -> minato_query:execute(Ready, Statement, [7]) end)
        )
    after
        ok = application:unset_env(minato, log_statements)
    end.

a_prepare_that_is_described_and_then_left_unanswered_is_an_error_test() ->
    Script = [[parse_complete], described([?INT4], [?INT4]), []],
    {_Server, Conn} = connected(Script, #{timeout => 100}),
    ?assertMatch({error, _Reason}, minato_query:prepare(Conn, ~"mine", ?SQL)).

%% Only a raise that is about the call leaves the connection fit to be told to
%% forget the statement. After any other, nothing more is written on it.
a_first_use_answered_out_of_turn_closes_nothing_test() ->
    Script = parsed([?INT4], [?INT4]) ++ [[parse_complete]],
    {Server, Conn} = connected(Script, #{timeout => 100}),
    ?assertError(
        {minato_query, #{reason := unexpected_message}}, minato_query:cached(Conn, ?SQL, [7])
    ),
    ?assertEqual([parse, describe, flush, bind, execute, sync], kinds(at_rest(Server))).

%% Every event of a query is sent from the process that asked, so all of them
%% are here by the time the call has come back.
events(Fun) ->
    Handler = {?MODULE, self()},
    {ok, _Started} = application:ensure_all_started(telemetry),
    ok = telemetry:attach_many(
        Handler, [[minato, query, start], [minato, query, stop]], fun ?MODULE:event/4, self()
    ),
    try
        _ = Fun(),
        seen()
    after
        ok = telemetry:detach(Handler)
    end.

event([minato, query, Phase], _Measurements, Metadata, Test) ->
    Test ! {query_event, Phase, Metadata},
    ok.

seen() ->
    receive
        {query_event, Phase, Metadata} -> [{Phase, Metadata} | seen()]
    after 0 -> []
    end.

%%----------------------------------------------------------------------
%% Scripts
%%----------------------------------------------------------------------

%% What a server answers `Parse`, `Describe` and `Flush` with.
parsed(Parameters, Columns) ->
    [[parse_complete], described(Parameters, Columns), []].

%% What it answers `Parse`, `Describe` and `Sync` with.
prepared(Parameters, Columns) ->
    [[parse_complete], described(Parameters, Columns), ?IDLE].

described(Parameters, []) ->
    [{parameter_description, Parameters}, no_data];
described(Parameters, Columns) ->
    [{parameter_description, Parameters}, {row_description, [column(Oid) || Oid <- Columns]}].

column(Oid) ->
    #{
        name => ~"a",
        table_oid => 0,
        column => 0,
        type_oid => Oid,
        type_size => -1,
        type_modifier => -1,
        format => text
    }.

%% What it answers `Bind`, `Execute` and `Sync` with for one row.
ran(Row) ->
    [[bind_complete], [{data_row, Row}, {command_complete, ~"SELECT 1"}], ?IDLE].

%% What it answers them with when it will not run the statement.
stale(Code, Status) ->
    [[refused(Code)], [], [{ready_for_query, Status}]].

refused(Code) ->
    {error_response, #{severity => ~"ERROR", code => Code, message => ~"refused"}}.

selected(Row) ->
    [
        {row_description, [column(?TEXT)]},
        {data_row, Row},
        {command_complete, ~"SELECT 1"},
        {ready_for_query, idle}
    ].

%% A first use of `?SQL` that keeps it.
kept() ->
    parsed([?INT4], [?INT4]) ++ ran([<<1:32>>]).

keep(Server, Conn) ->
    {ok, _First, Kept} = minato_query:cached(Conn, ?SQL, [1]),
    [{parse, Name, _Sql, _Oids} | _Rest] = asked(Server),
    {Name, Kept}.

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

connected(Script) ->
    connected(Script, #{}).

connected(Script, Opts) ->
    Server = minato_backend_server:start([?READY | Script]),
    Port = minato_backend_server:port(Server),
    {ok, Conn} = minato_conn:connect(
        maps:merge(#{host => "127.0.0.1", port => Port, user => ~"minato", timeout => 500}, Opts)
    ),
    {Server, Conn}.

%% Every exchange here has been answered by the time it is asked about, and
%% the server hands a message over before it answers it.
asked(Server) ->
    asked(Server, 20).

%% For what is expected not to have been sent, and for what is never answered.
at_rest(Server) ->
    asked(Server, 200).

asked(Server, Quiet) ->
    [
        Message
     || Message <- minato_backend_server:received(Server, Quiet), kind(Message) =/= startup
    ].

kinds(Messages) ->
    [kind(Message) || Message <- Messages].

kind(Message) when is_atom(Message) -> Message;
kind(Message) -> element(1, Message).

named({close, statement, _Name} = Close) -> Close;
named(Message) -> kind(Message).

round_trips(Messages) ->
    length([Message || Message <- Messages, lists:member(kind(Message), [flush, sync, query])]).
