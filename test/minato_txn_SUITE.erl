-module(minato_txn_SUITE).
-moduledoc """
Transactions, against a real PostgreSQL.

A transaction can only be proved by asking the server what survived it, so every
case here writes a row and then counts the rows on a second connection: a
rollback the client believes in but the server never performed looks exactly
like a commit from inside the same session.

The case worth the whole suite is `a_commit_the_server_downgrades_is_reported`.
PostgreSQL answers `COMMIT` with the tag `ROLLBACK` when the transaction had
already failed, and a client that reads that as success reports work as written
that the server threw away.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    a_committed_transaction_keeps_its_work/1,
    a_rolled_back_transaction_keeps_nothing/1,
    a_rollback_answer_reports_its_reason/1,
    an_exception_rolls_back_and_is_re_raised/1,
    an_exception_leaves_no_transaction_open_on_the_server/1,
    a_commit_the_server_downgrades_is_reported/1,
    a_pooled_commit_the_server_downgrades_is_reported/1,
    a_pooled_transaction_that_raises_keeps_nothing/1,
    the_status_follows_the_transaction/1,
    a_savepoint_recovers_a_failed_statement/1,
    a_released_savepoint_keeps_its_work/1,
    an_exception_with_an_answer_unread_rolls_back_and_keeps_the_connection/1,
    an_exception_with_a_rollback_unread_is_not_mistaken_for_its_own/1,
    an_exception_with_an_exchange_left_open_rolls_back/1,
    an_exception_in_the_middle_of_an_answer_never_answers_out_of_step/1
]).

-define(TIMEOUT, 10000).
-define(POOL, minato_txn_pool).

-spec all() -> [atom()].
all() ->
    [
        a_committed_transaction_keeps_its_work,
        a_rolled_back_transaction_keeps_nothing,
        a_rollback_answer_reports_its_reason,
        an_exception_rolls_back_and_is_re_raised,
        an_exception_leaves_no_transaction_open_on_the_server,
        a_commit_the_server_downgrades_is_reported,
        a_pooled_commit_the_server_downgrades_is_reported,
        a_pooled_transaction_that_raises_keeps_nothing,
        the_status_follows_the_transaction,
        a_savepoint_recovers_a_failed_statement,
        a_released_savepoint_keeps_its_work,
        an_exception_with_an_answer_unread_rolls_back_and_keeps_the_connection,
        an_exception_with_a_rollback_unread_is_not_mistaken_for_its_own,
        an_exception_with_an_exchange_left_open_rolls_back,
        an_exception_in_the_middle_of_an_answer_never_answers_out_of_step
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(opts()) of
        {ok, Conn} ->
            {ok, _Results, Ready} = minato_query:simple(Conn, schema()),
            ok = minato_conn:close(Ready),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    case minato_conn:connect(opts()) of
        {ok, Conn} ->
            {ok, _Results, Ready} = minato_query:simple(Conn, ~"DROP TABLE IF EXISTS minato_txn"),
            minato_conn:close(Ready);
        {error, _Reason} ->
            ok
    end.

-spec init_per_testcase(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_testcase(_Case, Config) ->
    {ok, Conn} = minato_conn:connect(opts()),
    {ok, _Results, Ready} = minato_query:simple(Conn, ~"TRUNCATE minato_txn"),
    [{conn, Ready} | Config].

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(_Case, Config) ->
    minato_conn:close(conn(Config)).

-spec a_committed_transaction_keeps_its_work([{atom(), term()}]) -> ok.
a_committed_transaction_keeps_its_work(Config) ->
    {ok, done, _Conn} = minato_txn:transaction(conn(Config), fun(Open) ->
        {ok, _Result, Written} = insert(Open, ~"a"),
        {ok, done, Written}
    end),
    ?assertEqual([~"a"], committed()).

-spec a_rolled_back_transaction_keeps_nothing([{atom(), term()}]) -> ok.
a_rolled_back_transaction_keeps_nothing(Config) ->
    {rollback, no, _Conn} = minato_txn:transaction(conn(Config), fun(Open) ->
        {ok, _Result, Written} = insert(Open, ~"a"),
        {rollback, no, Written}
    end),
    ?assertEqual([], committed()).

-spec a_rollback_answer_reports_its_reason([{atom(), term()}]) -> ok.
a_rollback_answer_reports_its_reason(Config) ->
    Answer = minato_txn:transaction(conn(Config), fun(Open) -> {rollback, too_expensive, Open} end),
    ?assertMatch({rollback, too_expensive, _Conn}, Answer).

-spec an_exception_rolls_back_and_is_re_raised([{atom(), term()}]) -> ok.
an_exception_rolls_back_and_is_re_raised(Config) ->
    Conn = conn(Config),
    ?assertThrow(
        no_thanks,
        minato_txn:transaction(Conn, fun(Open) ->
            {ok, _Result, _Written} = insert(Open, ~"a"),
            throw(no_thanks)
        end)
    ),
    ?assertEqual([], committed()),
    ?assertEqual(idle, minato_txn:status(Conn)).

-spec a_commit_the_server_downgrades_is_reported([{atom(), term()}]) -> ok.
a_commit_the_server_downgrades_is_reported(Config) ->
    {ok, Open} = minato_txn:open(conn(Config)),
    {ok, _Result, Written} = insert(Open, ~"a"),
    {error, {pgsql_error, _Fields}, Failed} = minato_query:query(
        Written, ~"INSERT INTO minato_txn (name) VALUES ($1)", [null]
    ),
    ?assertEqual(failed, minato_txn:status(Failed)),
    ?assertMatch({error, transaction_rolled_back, _Conn}, minato_txn:commit(Failed)),
    ?assertEqual([], committed()).

%% Nothing committed is what an open transaction looks like from a second
%% connection too, so the first one is asked: the server says whether it is in
%% a transaction with every answer, and a row written after the exception has
%% to be there for everybody at once.
-spec an_exception_leaves_no_transaction_open_on_the_server([{atom(), term()}]) -> ok.
an_exception_leaves_no_transaction_open_on_the_server(Config) ->
    Conn = conn(Config),
    ?assertError(
        badarg,
        minato_txn:transaction(Conn, fun(Open) ->
            {ok, _Result, _Written} = insert(Open, ~"a"),
            error(badarg)
        end)
    ),
    {ok, _Result, Asked} = insert(Conn, ~"b"),
    ?assertEqual(idle, minato_txn:status(Asked)),
    ?assertEqual([~"b"], committed()).

%% The same downgrade through the pool, where the caller sees only the answer:
%% a function that swallowed a failed statement and answered `ok` must not be
%% told its work was kept.
-spec a_pooled_commit_the_server_downgrades_is_reported([{atom(), term()}]) -> ok.
a_pooled_commit_the_server_downgrades_is_reported(_Config) ->
    pooled(fun() ->
        Answer = minato:transaction(?POOL, fun(Open) ->
            {ok, _Result, Written} = insert(Open, ~"a"),
            {error, {pgsql_error, _Fields}, Failed} = insert(Written, ~"a"),
            {ok, done, Failed}
        end),
        ?assertEqual({error, transaction_rolled_back}, Answer),
        ?assertEqual([], committed()),
        ?assertMatch({ok, #{rows := [{1}]}}, minato:query(?POOL, ~"SELECT 1::int4", []))
    end).

-spec a_pooled_transaction_that_raises_keeps_nothing([{atom(), term()}]) -> ok.
a_pooled_transaction_that_raises_keeps_nothing(_Config) ->
    pooled(fun() ->
        ?assertThrow(
            no_thanks,
            minato:transaction(?POOL, fun(Open) ->
                {ok, _Result, _Written} = insert(Open, ~"a"),
                throw(no_thanks)
            end)
        ),
        ?assertEqual({ok, done}, minato:transaction(?POOL, fun(Open) -> {ok, done, Open} end)),
        {ok, _Result} = minato:query(?POOL, ~"INSERT INTO minato_txn (name) VALUES ($1)", [~"b"]),
        ?assertEqual([~"b"], committed())
    end).

pooled(Test) ->
    {ok, _Started} = application:ensure_all_started(minato),
    {ok, _Pid} = minato:start_pool(?POOL, #{size => 1, connection => opts()}),
    try
        Test()
    after
        ok = minato:stop_pool(?POOL)
    end.

-spec the_status_follows_the_transaction([{atom(), term()}]) -> ok.
the_status_follows_the_transaction(Config) ->
    Conn = conn(Config),
    ?assertEqual(idle, minato_txn:status(Conn)),
    {ok, Open} = minato_txn:open(Conn),
    ?assertEqual(transaction, minato_txn:status(Open)),
    {ok, Closed} = minato_txn:rollback(Open),
    ?assertEqual(idle, minato_txn:status(Closed)).

-spec a_savepoint_recovers_a_failed_statement([{atom(), term()}]) -> ok.
a_savepoint_recovers_a_failed_statement(Config) ->
    {ok, Open} = minato_txn:open(conn(Config)),
    {ok, _First, Written} = insert(Open, ~"a"),
    {ok, Marked} = minato_txn:savepoint(Written, ~"before"),
    {error, {pgsql_error, _Fields}, Failed} = insert(Marked, ~"a"),
    {ok, Recovered} = minato_txn:rollback_to(Failed, ~"before"),
    ?assertEqual(transaction, minato_txn:status(Recovered)),
    {ok, _Second, More} = insert(Recovered, ~"b"),
    {ok, _Committed} = minato_txn:commit(More),
    ?assertEqual([~"a", ~"b"], committed()).

-spec a_released_savepoint_keeps_its_work([{atom(), term()}]) -> ok.
a_released_savepoint_keeps_its_work(Config) ->
    {ok, Open} = minato_txn:open(conn(Config)),
    {ok, Marked} = minato_txn:savepoint(Open, ~"here"),
    {ok, _Result, Written} = insert(Marked, ~"a"),
    {ok, Released} = minato_txn:release(Written, ~"here"),
    {ok, _Committed} = minato_txn:commit(Released),
    ?assertEqual([~"a"], committed()).

%%----------------------------------------------------------------------
%% An exception with answers still on their way
%%----------------------------------------------------------------------

%% The function wrote a statement and raised before reading what came back.
%% The rollback is sent on the connection the function was given, so the
%% answer it reads first is the function's, not its own, and a caller that
%% went on with the connection would read every answer one statement late.
-spec an_exception_with_an_answer_unread_rolls_back_and_keeps_the_connection([{atom(), term()}]) ->
    ok.
an_exception_with_an_answer_unread_rolls_back_and_keeps_the_connection(Config) ->
    Conn = conn(Config),
    Unread = ~"INSERT INTO minato_txn (name) VALUES ('a'); SELECT generate_series(1, 50000)",
    ?assertError(
        boom,
        minato_txn:transaction(Conn, fun(Open) ->
            ok = minato_conn:send(Open, {query, Unread}),
            error(boom)
        end)
    ),
    ?assertEqual([], committed()),
    ?assertEqual({ok, [{1}], idle}, asked(Conn, ~"SELECT 1")),
    ?assertEqual({ok, [{2}], idle}, asked(Conn, ~"SELECT 2")).

-spec an_exception_with_a_rollback_unread_is_not_mistaken_for_its_own([{atom(), term()}]) -> ok.
an_exception_with_a_rollback_unread_is_not_mistaken_for_its_own(Config) ->
    Conn = conn(Config),
    ?assertThrow(
        gone,
        minato_txn:transaction(Conn, fun(Open) ->
            {ok, _Result, Written} = insert(Open, ~"a"),
            ok = minato_conn:send(Written, {query, ~"ROLLBACK"}),
            throw(gone)
        end)
    ),
    ?assertEqual([], committed()),
    ?assertEqual({ok, [{1}], idle}, asked(Conn, ~"SELECT 1")).

%% A `Parse` the server refused and no `Sync` after it: everything but a `Sync`
%% is ignored from there on, a `ROLLBACK` included.
-spec an_exception_with_an_exchange_left_open_rolls_back([{atom(), term()}]) -> ok.
an_exception_with_an_exchange_left_open_rolls_back(Config) ->
    Conn = conn(Config),
    ?assertExit(
        stopped,
        minato_txn:transaction(Conn, fun(Open) ->
            {ok, _Result, Written} = insert(Open, ~"a"),
            ok = minato_conn:send(Written, [{parse, ~"", ~"NOT SQL AT ALL", []}, flush]),
            exit(stopped)
        end)
    ),
    ?assertEqual([], committed()),
    ?assertEqual({ok, [{1}], idle}, asked(Conn, ~"SELECT 1")).

%% The function stopped part way through reading, and what it had read went
%% with it. The connection it was given may now start in the middle of a
%% message. Either it is read through to the rollback or it is closed; what it
%% must never do is hand the next statement somebody else's answer.
-spec an_exception_in_the_middle_of_an_answer_never_answers_out_of_step([{atom(), term()}]) ->
    ok.
an_exception_in_the_middle_of_an_answer_never_answers_out_of_step(_Config) ->
    {ok, Conn} = minato_conn:connect((opts())#{timeout => 1000}),
    Unread = ~"INSERT INTO minato_txn (name) VALUES ('a'); SELECT generate_series(1, 50000)",
    ?assertError(
        boom,
        minato_txn:transaction(Conn, fun(Open) ->
            ok = minato_conn:send(Open, {query, Unread}),
            {ok, _First, Read} = minato_conn:next(Open),
            {ok, _Second, _More} = minato_conn:next(Read),
            error(boom)
        end)
    ),
    ?assertEqual([], committed()),
    case asked(Conn, ~"SELECT 1") of
        {ok, Rows, Status} -> ?assertEqual({[{1}], idle}, {Rows, Status});
        {error, Reason} -> ?assertMatch({socket, _Closed}, Reason)
    end,
    ok = minato_conn:close(Conn).

asked(Conn, Sql) ->
    case minato_query:query(Conn, Sql, []) of
        {ok, #{rows := Rows}, Read} -> {ok, Rows, minato_txn:status(Read)};
        {error, Reason, _Read} -> {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

%%----------------------------------------------------------------------
%% Asking the server what survived
%%----------------------------------------------------------------------

insert(Conn, Name) ->
    minato_query:query(Conn, ~"INSERT INTO minato_txn (name) VALUES ($1)", [Name]).

committed() ->
    {ok, Conn} = minato_conn:connect(opts()),
    Sql = ~"SELECT name FROM minato_txn ORDER BY name",
    {ok, #{rows := Rows}, Read} = minato_query:query(Conn, Sql, []),
    ok = minato_conn:close(Read),
    [Name || {Name} <- Rows].

conn(Config) ->
    {conn, Conn} = lists:keyfind(conn, 1, Config),
    Conn.

schema() ->
    ~"""
    DROP TABLE IF EXISTS minato_txn;
    CREATE TABLE minato_txn (name text PRIMARY KEY)
    """.

opts() ->
    #{
        host => env("MINATO_PG_HOST", "127.0.0.1"),
        port => list_to_integer(env("MINATO_PG_PORT", "55432")),
        user => list_to_binary(env("MINATO_PG_USER", "minato")),
        password => list_to_binary(env("MINATO_PG_PASSWORD", "minato")),
        database => list_to_binary(env("MINATO_PG_DATABASE", "minato_test")),
        timeout => ?TIMEOUT
    }.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
