-module(minato_socket_SUITE).
-moduledoc """
The `socket` transport, against a real PostgreSQL.

`m:minato_socket` answers the same six calls `m:gen_tcp` answers, so the point
of this suite is that everything above the transport cannot tell which one it
got: the same authentication, the same query paths, the same errors leaving a
connection usable, and the same pool lending it out and taking it back.

The two hard parts are proved rather than described. `m:ssl` takes one of these
handles directly, so TLS is the same exchange over a different socket and the
certificate hash SCRAM binds to is the same hash. `m:socket` has no active mode,
so `LISTEN` is a `select` registered by the owning process and answered in its
own mailbox - no reader process between the socket and the connection - and a
notification has to arrive through it.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    a_query_runs/1,
    a_cached_statement_runs_more_than_once/1,
    a_failing_statement_leaves_the_connection_usable/1,
    a_transaction_commits/1,
    a_result_set_spanning_many_reads_arrives_whole/1,
    a_pool_lends_a_connection_and_takes_it_back/1,
    a_pooled_connection_outlives_the_process_that_opened_it/1,
    a_borrower_that_dies_does_not_take_the_pool_down/1,
    tls_runs_over_this_transport/1,
    a_notification_arrives_over_this_transport/1,
    a_connection_goes_back_to_reading_after_waiting/1,
    a_listener_runs_over_this_transport/1
]).

-define(TIMEOUT, 10000).

-spec all() -> [atom()].
all() ->
    [
        a_query_runs,
        a_cached_statement_runs_more_than_once,
        a_failing_statement_leaves_the_connection_usable,
        a_transaction_commits,
        a_result_set_spanning_many_reads_arrives_whole,
        a_pool_lends_a_connection_and_takes_it_back,
        a_pooled_connection_outlives_the_process_that_opened_it,
        a_borrower_that_dies_does_not_take_the_pool_down,
        tls_runs_over_this_transport,
        a_notification_arrives_over_this_transport,
        a_connection_goes_back_to_reading_after_waiting,
        a_listener_runs_over_this_transport
    ].

%% Reachability is asked over the driver transport, so that a socket transport
%% which cannot connect fails the suite instead of skipping it. A skip here
%% would mean "no PostgreSQL", and it has to keep meaning only that.
-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    {ok, _Started} = application:ensure_all_started(minato),
    case minato_conn:connect(maps:remove(transport, opts())) of
        {ok, Conn} ->
            ok = minato_conn:close(Conn),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok.

%%----------------------------------------------------------------------
%% The same client, a different transport
%%----------------------------------------------------------------------

a_query_runs(_Config) ->
    Conn = connected(),
    {ok, #{rows := [{42}], command := select}, Ready} =
        minato_query:query(Conn, ~"SELECT $1::int4", [42]),
    ok = minato_conn:close(Ready).

a_cached_statement_runs_more_than_once(_Config) ->
    Conn = connected(),
    {ok, #{rows := [{1}]}, First} = minato_query:cached(Conn, ~"SELECT $1::int4", [1]),
    {ok, #{rows := [{2}]}, Second} = minato_query:cached(First, ~"SELECT $1::int4", [2]),
    ?assertEqual({1, 64}, minato_conn:statements(Second)),
    ok = minato_conn:close(Second).

a_failing_statement_leaves_the_connection_usable(_Config) ->
    Conn = connected(),
    {error, {pgsql_error, #{code := ~"42601"}}, Usable} =
        minato_query:query(Conn, ~"NOT SQL AT ALL", []),
    {ok, #{rows := [{1}]}, Ready} = minato_query:query(Usable, ~"SELECT $1::int4", [1]),
    ok = minato_conn:close(Ready).

a_transaction_commits(_Config) ->
    Conn = connected(),
    {ok, done, Ready} = minato_txn:transaction(Conn, fun(Inside) ->
        {ok, #{rows := [{7}]}, Written} = minato_query:query(Inside, ~"SELECT $1::int4", [7]),
        {ok, done, Written}
    end),
    ok = minato_conn:close(Ready).

a_result_set_spanning_many_reads_arrives_whole(_Config) ->
    Conn = connected(),
    Sql = ~"SELECT i, repeat('x', 32) FROM generate_series(1, 5000) i",
    {ok, #{rows := Rows, num_rows := 5000}, Ready} = minato_query:cached(Conn, Sql, []),
    ?assertEqual(5000, length(Rows)),
    ?assertEqual({1, ~"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}, hd(Rows)),
    ?assertEqual({5000, ~"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}, lists:last(Rows)),
    ok = minato_conn:close(Ready).

%%----------------------------------------------------------------------
%% The pool, which is where the ownership question lives
%%----------------------------------------------------------------------

a_pool_lends_a_connection_and_takes_it_back(_Config) ->
    Name = pool(lends),
    {ok, #{rows := [{42}]}} = minato:query(Name, ~"SELECT $1::int4", [42]),
    {ok, #{rows := [{43}]}} = minato:query(Name, ~"SELECT $1::int4", [43]),
    #{disconnects := 0, checkouts := 2} = minato_pool:stats(Name),
    _ = minato:stop_pool(Name).

a_pooled_connection_outlives_the_process_that_opened_it(_Config) ->
    Name = pool(outlives),
    _ = [minato:query(Name, ~"SELECT $1::int4", [N]) || N <- lists:seq(1, 20)],
    #{disconnects := 0} = minato_pool:stats(Name),
    _ = minato:stop_pool(Name).

a_borrower_that_dies_does_not_take_the_pool_down(_Config) ->
    Name = pool(borrower),
    {ok, _Result} = minato:query(Name, ~"SELECT $1::int4", [1]),
    {Pid, Ref} = spawn_monitor(fun() ->
        {ok, _Conn} = minato_pool:checkout(Name),
        exit(taken_out_with_a_connection)
    end),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> ok
    after ?TIMEOUT -> ct:fail(borrower_never_died)
    end,
    {ok, #{rows := [{2}]}} = minato:query(Name, ~"SELECT $1::int4", [2]),
    _ = minato:stop_pool(Name).

%%----------------------------------------------------------------------
%% TLS, which ssl does over one of these handles unchanged
%%----------------------------------------------------------------------

tls_runs_over_this_transport(_Config) ->
    case minato_conn:connect(secured()) of
        {ok, Conn} ->
            {ok, #{rows := [{42}]}, Ready} = minato_query:query(Conn, ~"SELECT $1::int4", [42]),
            ?assertNotEqual(undefined, minato_conn:channel_binding(Ready)),
            {ok, #{rows := [{true}]}, Read} =
                minato_query:query(
                    Ready, ~"SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", []
                ),
            ok = minato_conn:close(Read);
        {error, Reason} ->
            {skip, {no_tls_server, Reason}}
    end.

%%----------------------------------------------------------------------
%% Waiting for the server without a read outstanding
%%----------------------------------------------------------------------

a_notification_arrives_over_this_transport(_Config) ->
    Conn = connected(),
    {ok, _Results, Listening} = minato_query:simple(Conn, ~"LISTEN minato_socket_suite"),
    {ok, Waiting} = minato_conn:activate(Listening),
    ok = notify(~"minato_socket_suite", ~"without a read outstanding"),
    {Kind, Notification} = awaited(Waiting),
    ?assertEqual(shape(os:type()), Kind),
    ?assertMatch(
        {notification_response, _Pid, ~"minato_socket_suite", ~"without a read outstanding"},
        Notification
    ),
    ok = minato_conn:close(Waiting).

a_connection_goes_back_to_reading_after_waiting(_Config) ->
    Conn = connected(),
    {ok, Waiting} = minato_conn:activate(Conn),
    {ok, Passive} = minato_conn:deactivate(Waiting),
    {ok, #{rows := [{1}]}, Ready} = minato_query:query(Passive, ~"SELECT $1::int4", [1]),
    ok = minato_conn:close(Ready).

a_listener_runs_over_this_transport(_Config) ->
    Name = minato_socket_suite_listener,
    {ok, _Pid} = minato:start_listener(Name, #{connection => opts()}),
    ok = minato:listen(Name, ~"minato_socket_listener"),
    ok = notify(~"minato_socket_listener", ~"all the way up"),
    receive
        {minato_notification, ~"minato_socket_listener", ~"all the way up", _From} -> ok
    after ?TIMEOUT -> ct:fail(no_notification)
    end,
    ok = minato:listen(Name, ~"minato_socket_listener_again"),
    ok = notify(~"minato_socket_listener_again", ~"and again"),
    receive
        {minato_notification, ~"minato_socket_listener_again", ~"and again", _Also} -> ok
    after ?TIMEOUT -> ct:fail(no_second_notification)
    end,
    ok = minato:stop_listener(Name).

%% The kind is asserted rather than assumed, because it is the whole difference
%% between the two machines: POSIX says the socket is readable and leaves the
%% bytes in it, Windows completes the read and puts them in the message. A run
%% that took the other path would otherwise pass without ever touching this one.
awaited(Conn) ->
    awaited(Conn, undefined).

awaited(Conn, Kind) ->
    receive
        Message ->
            case minato_conn:handle_message(Conn, Message) of
                {messages, [], Again} -> awaited(Again, kind(Message, Kind));
                {messages, Messages, _Read} -> {kind(Message, Kind), hd(Messages)};
                ignore -> awaited(Conn, Kind);
                {closed, Reason} -> ct:fail({closed, Reason})
            end
    after ?TIMEOUT -> ct:fail(no_notification)
    end.

kind({'$socket', _Socket, Kind, _What}, _Seen) -> Kind;
kind(_Sent_from_here, Seen) -> Seen.

shape({win32, _Flavour}) -> completion;
shape(_Posix) -> select.

notify(Channel, Payload) ->
    {ok, Conn} = minato_conn:connect(opts()),
    Sql = <<"NOTIFY ", Channel/binary, ", '", Payload/binary, "'">>,
    {ok, _Results, Ready} = minato_query:simple(Conn, Sql),
    minato_conn:close(Ready).

%%----------------------------------------------------------------------

connected() ->
    {ok, Conn} = minato_conn:connect(opts()),
    Conn.

secured() ->
    (opts())#{
        host => env("MINATO_TLS_HOST", "localhost"),
        port => list_to_integer(env("MINATO_TLS_PORT", "55433")),
        ssl => true,
        ssl_options => [{cacerts, cacerts()}]
    }.

cacerts() ->
    {ok, Pem} = file:read_file(certificate("ca.crt")),
    [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)].

certificate(Name) ->
    filename:join([directory(code:lib_dir(minato)), "test", "certs", Name]).

directory({error, Reason}) ->
    error({no_application_directory, Reason});
directory(Directory) ->
    Directory.

pool(Case) ->
    Name = list_to_atom("minato_socket_suite_" ++ atom_to_list(Case)),
    {ok, _Pid} = minato:start_pool(Name, #{
        size => 2, min_size => 2, connection => opts()
    }),
    Name.

opts() ->
    #{
        host => env("MINATO_PG_HOST", "127.0.0.1"),
        port => list_to_integer(env("MINATO_PG_PORT", "55432")),
        user => list_to_binary(env("MINATO_PG_USER", "minato")),
        password => list_to_binary(env("MINATO_PG_PASSWORD", "minato")),
        database => list_to_binary(env("MINATO_PG_DATABASE", "minato_test")),
        transport => socket,
        timeout => ?TIMEOUT
    }.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
