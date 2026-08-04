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
    a_commit_the_server_downgrades_is_reported/1,
    the_status_follows_the_transaction/1,
    a_savepoint_recovers_a_failed_statement/1,
    a_released_savepoint_keeps_its_work/1
]).

-define(TIMEOUT, 10000).

-spec all() -> [atom()].
all() ->
    [
        a_committed_transaction_keeps_its_work,
        a_rolled_back_transaction_keeps_nothing,
        a_rollback_answer_reports_its_reason,
        an_exception_rolls_back_and_is_re_raised,
        a_commit_the_server_downgrades_is_reported,
        the_status_follows_the_transaction,
        a_savepoint_recovers_a_failed_statement,
        a_released_savepoint_keeps_its_work
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
