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

-define(INT4, 23).
-define(TEXT, 25).

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).
-define(IDLE, [{ready_for_query, idle}]).
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
    ?assert(lists:member({cancel_request, 4242, 777}, asked(Server))).

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

refused(Code) ->
    {error_response, #{severity => ~"ERROR", code => Code, message => ~"refused"}}.

selected(Row) ->
    [
        {row_description, [column(?TEXT)]},
        {data_row, Row},
        {command_complete, ~"SELECT 1"},
        {ready_for_query, idle}
    ].

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

connected(Script) ->
    connected(Script, #{}).

connected(Script, Opts) ->
    Server = minato_backend_server:start([?READY | Script]),
    Port = minato_backend_server:port(Server),
    {ok, Conn} = minato_conn:connect(
        maps:merge(#{host => "127.0.0.1", port => Port, user => ~"minato", timeout => 1000}, Opts)
    ),
    {Server, Conn}.

asked(Server) ->
    [Message || Message <- minato_backend_server:received(Server), kind(Message) =/= startup].

kinds(Messages) ->
    [kind(Message) || Message <- Messages].

kind(Message) when is_atom(Message) -> Message;
kind(Message) -> element(1, Message).

round_trips(Messages) ->
    length([Message || Message <- Messages, lists:member(kind(Message), [flush, sync, query])]).
