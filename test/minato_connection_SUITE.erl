-module(minato_connection_SUITE).
-moduledoc """
The connection, against a real PostgreSQL.

`minato_conn_tests` proves what the client does with a server that misbehaves,
which needs a server written to misbehave. This proves the ordinary case against
the only opinion that counts: a connection that reaches `ReadyForQuery` against
`postgres:17`, authenticated with SCRAM, and can then be used to run a
statement and to cancel one.

Cancellation is the case worth having here rather than against a stub. It is the
one part of the protocol that needs a second connection and the server's own
`BackendKeyData`, and a stub proving minato sent the right bytes proves nothing
about whether PostgreSQL accepts them.

The suite skips when no server answers, so `rebar3 ct` on a machine without
Docker is not a failure.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    connects_and_reports_what_the_server_said/1,
    a_wrong_password_is_refused/1,
    an_unknown_database_is_refused/1,
    a_password_fun_is_called_at_connect_time/1,
    scram_alone_is_enough_for_this_server/1,
    a_server_without_tls_is_refused_when_tls_is_required/1,
    the_connection_can_run_a_statement/1,
    a_running_statement_can_be_cancelled/1
]).

-define(TIMEOUT, 10000).

-spec all() -> [atom()].
all() ->
    [
        connects_and_reports_what_the_server_said,
        a_wrong_password_is_refused,
        an_unknown_database_is_refused,
        a_password_fun_is_called_at_connect_time,
        scram_alone_is_enough_for_this_server,
        a_server_without_tls_is_refused_when_tls_is_required,
        the_connection_can_run_a_statement,
        a_running_statement_can_be_cancelled
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case gen_tcp:connect(host(), port(), [binary, {active, false}], ?TIMEOUT) of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            Config;
        {error, Reason} ->
            {skip, {no_server, host(), port(), Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok.

-spec connects_and_reports_what_the_server_said([{atom(), term()}]) -> ok.
connects_and_reports_what_the_server_said(_Config) ->
    {ok, Conn} = minato_conn:connect(opts(#{})),
    ?assertMatch(<<"1", _/binary>>, minato_conn:parameter(Conn, ~"server_version")),
    ?assertEqual(~"UTF8", minato_conn:parameter(Conn, ~"client_encoding")),
    ?assertMatch(
        {Pid, Secret} when is_integer(Pid) andalso is_integer(Secret),
        minato_conn:backend_key(Conn)
    ),
    ok = minato_conn:close(Conn).

-spec a_wrong_password_is_refused([{atom(), term()}]) -> ok.
a_wrong_password_is_refused(_Config) ->
    Result = minato_conn:connect(opts(#{password => ~"not the password"})),
    ?assertMatch({error, {pgsql_error, #{code := ~"28P01"}}}, Result).

-spec an_unknown_database_is_refused([{atom(), term()}]) -> ok.
an_unknown_database_is_refused(_Config) ->
    Result = minato_conn:connect(opts(#{database => ~"no_such_database"})),
    ?assert(refused(Result)).

%% The server writes its FATAL and then the backend exits. On Windows a socket
%% closed with anything still unread is reset rather than shut down, and a reset
%% discards what the other end had already received, so the message can be gone
%% before it is read. What has to hold everywhere is that the connection is
%% refused and that minato says why as far as it was told.
refused({error, {pgsql_error, #{code := ~"3D000"}}}) -> true;
refused({error, {socket, _Gone_before_it_was_read}}) -> os:type() =:= {win32, nt};
refused(_Connected_or_something_else) -> false.

-spec a_password_fun_is_called_at_connect_time([{atom(), term()}]) -> ok.
a_password_fun_is_called_at_connect_time(_Config) ->
    Asked = counters:new(1, []),
    Password = fun() ->
        ok = counters:add(Asked, 1, 1),
        password()
    end,
    {ok, Conn} = minato_conn:connect(opts(#{password => Password})),
    ok = minato_conn:close(Conn),
    ?assertEqual(1, counters:get(Asked, 1)).

-spec scram_alone_is_enough_for_this_server([{atom(), term()}]) -> ok.
scram_alone_is_enough_for_this_server(_Config) ->
    {ok, Conn} = minato_conn:connect(opts(#{auth => [scram_sha_256]})),
    ok = minato_conn:close(Conn).

-spec a_server_without_tls_is_refused_when_tls_is_required([{atom(), term()}]) -> ok.
a_server_without_tls_is_refused_when_tls_is_required(_Config) ->
    ?assertEqual({error, tls_refused}, minato_conn:connect(opts(#{ssl => true}))).

-spec the_connection_can_run_a_statement([{atom(), term()}]) -> ok.
the_connection_can_run_a_statement(_Config) ->
    {ok, Conn} = minato_conn:connect(opts(#{})),
    ok = minato_conn:send(Conn, {query, ~"SELECT 1 AS one, 'ok'::text AS word"}),
    {Rows, Read} = collect(Conn, [], []),
    ok = minato_conn:close(Read),
    ?assertEqual([{1, ~"ok"}], Rows).

-spec a_running_statement_can_be_cancelled([{atom(), term()}]) -> ok.
a_running_statement_can_be_cancelled(_Config) ->
    Named = opts(#{parameters => #{~"application_name" => ~"minato_cancel_test"}}),
    {ok, Conn} = minato_conn:connect(Named),
    ok = minato_conn:send(Conn, {query, ~"SELECT pg_sleep(30)"}),
    ok = running(100),
    ok = minato_conn:cancel(Conn),
    Reported = until_error(Conn),
    ok = minato_conn:close(Conn),
    ?assertMatch(#{code := ~"57014"}, Reported).

%%----------------------------------------------------------------------
%% Reading a result without a query layer
%%----------------------------------------------------------------------

collect(Conn, Fields, Rows) ->
    case minato_conn:next(Conn) of
        {ok, {row_description, Described}, Read} ->
            collect(Read, Described, Rows);
        {ok, {data_row, Columns}, Read} ->
            Decoded = minato_protocol:decode_row(minato_protocol:decoder(Fields, #{}), Columns),
            collect(Read, Fields, [Decoded | Rows]);
        {ok, {ready_for_query, _Status}, Read} ->
            {lists:reverse(Rows), Read};
        {ok, _Message, Read} ->
            collect(Read, Fields, Rows)
    end.

until_error(Conn) ->
    case minato_conn:next(Conn) of
        {ok, {error_response, Fields}, _Read} -> Fields;
        {ok, {ready_for_query, _Status}, _Read} -> not_cancelled;
        {ok, _Message, Read} -> until_error(Read);
        {error, Reason} -> {no_answer, Reason}
    end.

running(0) ->
    {error, never_started};
running(Attempts) ->
    {ok, Conn} = minato_conn:connect(opts(#{})),
    Sql = <<
        "SELECT count(*) FROM pg_stat_activity WHERE application_name = $1 ",
        "AND state = 'active' AND query LIKE 'SELECT pg_sleep%'"
    >>,
    {ok, #{rows := [{Count}]}, Read} = minato_query:query(Conn, Sql, [~"minato_cancel_test"]),
    ok = minato_conn:close(Read),
    case Count > 0 of
        true ->
            ok;
        false ->
            timer:sleep(20),
            running(Attempts - 1)
    end.

%%----------------------------------------------------------------------
%% Where the server is
%%----------------------------------------------------------------------

opts(Opts) ->
    maps:merge(
        #{
            host => host(),
            port => port(),
            user => user(),
            password => password(),
            database => database(),
            timeout => ?TIMEOUT
        },
        Opts
    ).

host() ->
    env("MINATO_PG_HOST", "127.0.0.1").

port() ->
    list_to_integer(env("MINATO_PG_PORT", "55432")).

database() ->
    list_to_binary(env("MINATO_PG_DATABASE", "minato_test")).

user() ->
    list_to_binary(env("MINATO_PG_USER", "minato")).

password() ->
    list_to_binary(env("MINATO_PG_PASSWORD", "minato")).

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
