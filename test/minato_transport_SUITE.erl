-module(minato_transport_SUITE).
-moduledoc """
Both transports, against a real PostgreSQL.

`m:minato_socket` answers the same six calls `m:gen_tcp` answers, so the point
of this suite is that everything above the transport cannot tell which one it
got: the same authentication, the same query paths, the same errors leaving a
connection usable, and the same pool lending it out and taking it back. Every
case runs twice, once per group, so neither transport rests on being the
default - `socket` is, and `inet` would otherwise be exercised nowhere.

The two hard parts are proved rather than described. `m:ssl` takes one of these
handles directly, so TLS is the same exchange over a different socket and the
certificate hash SCRAM binds to is the same hash. `m:socket` has no active mode,
so `LISTEN` is a `select` registered by the owning process and answered in its
own mailbox - no reader process between the socket and the connection - and a
notification has to arrive through it. The driver gets there by `{active, once}`
instead, and the case asserts which shape it took rather than accepting either.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([
    a_query_runs/1,
    a_cached_statement_runs_more_than_once/1,
    a_failing_statement_leaves_the_connection_usable/1,
    a_transaction_commits/1,
    a_result_set_spanning_many_reads_arrives_whole/1,
    a_socket_option_the_driver_takes_is_taken_here/1,
    an_option_this_transport_cannot_honour_is_refused/1,
    a_pool_lends_a_connection_and_takes_it_back/1,
    a_pooled_connection_outlives_the_process_that_opened_it/1,
    a_borrower_that_dies_does_not_take_the_pool_down/1,
    tls_runs_over_this_transport/1,
    a_notification_arrives_over_this_transport/1,
    a_connection_that_dies_while_waiting_says_so/1,
    a_connection_goes_back_to_reading_after_waiting/1,
    a_listener_runs_over_this_transport/1
]).

-define(TIMEOUT, 10000).

-spec all() -> [{group, atom()}].
all() ->
    [{group, socket}, {group, inet}].

-spec groups() -> [{atom(), [term()], [atom()]}].
groups() ->
    [{Transport, [], cases()} || Transport <- [socket, inet]].

-spec cases() -> [atom()].
cases() ->
    [
        a_query_runs,
        a_cached_statement_runs_more_than_once,
        a_failing_statement_leaves_the_connection_usable,
        a_transaction_commits,
        a_result_set_spanning_many_reads_arrives_whole,
        a_socket_option_the_driver_takes_is_taken_here,
        an_option_this_transport_cannot_honour_is_refused,
        a_pool_lends_a_connection_and_takes_it_back,
        a_pooled_connection_outlives_the_process_that_opened_it,
        a_borrower_that_dies_does_not_take_the_pool_down,
        tls_runs_over_this_transport,
        a_notification_arrives_over_this_transport,
        a_connection_that_dies_while_waiting_says_so,
        a_connection_goes_back_to_reading_after_waiting,
        a_listener_runs_over_this_transport
    ].

%% Reachability is asked over the driver transport, so that a socket transport
%% which cannot connect fails the suite instead of skipping it. A skip here
%% would mean "no PostgreSQL", and it has to keep meaning only that.
-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    {ok, _Started} = application:ensure_all_started(minato),
    case minato_conn:connect((base())#{transport => inet}) of
        {ok, Conn} ->
            ok = minato_conn:close(Conn),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok.

-spec init_per_group(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_group(Transport, Config) ->
    [{transport, Transport} | Config].

-spec end_per_group(atom(), [{atom(), term()}]) -> ok.
end_per_group(_Transport, _Config) ->
    ok.

%%----------------------------------------------------------------------
%% The same client, either transport
%%----------------------------------------------------------------------

a_query_runs(Config) ->
    Conn = connected(Config),
    {ok, #{rows := [{42}], command := select}, Ready} =
        minato_query:query(Conn, ~"SELECT $1::int4", [42]),
    ok = minato_conn:close(Ready).

a_cached_statement_runs_more_than_once(Config) ->
    Conn = connected(Config),
    {ok, #{rows := [{1}]}, First} = minato_query:cached(Conn, ~"SELECT $1::int4", [1]),
    {ok, #{rows := [{2}]}, Second} = minato_query:cached(First, ~"SELECT $1::int4", [2]),
    ?assertEqual({1, 64}, minato_conn:statements(Second)),
    ok = minato_conn:close(Second).

a_failing_statement_leaves_the_connection_usable(Config) ->
    Conn = connected(Config),
    {error, {pgsql_error, #{code := ~"42601"}}, Usable} =
        minato_query:query(Conn, ~"NOT SQL AT ALL", []),
    {ok, #{rows := [{1}]}, Ready} = minato_query:query(Usable, ~"SELECT $1::int4", [1]),
    ok = minato_conn:close(Ready).

a_transaction_commits(Config) ->
    Conn = connected(Config),
    {ok, done, Ready} = minato_txn:transaction(Conn, fun(Inside) ->
        {ok, #{rows := [{7}]}, Written} = minato_query:query(Inside, ~"SELECT $1::int4", [7]),
        {ok, done, Written}
    end),
    ok = minato_conn:close(Ready).

a_result_set_spanning_many_reads_arrives_whole(Config) ->
    Conn = connected(Config),
    Sql = ~"SELECT i, repeat('x', 32) FROM generate_series(1, 5000) i",
    {ok, #{rows := Rows, num_rows := 5000}, Ready} = minato_query:cached(Conn, Sql, []),
    ?assertEqual(5000, length(Rows)),
    ?assertEqual({1, ~"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}, hd(Rows)),
    ?assertEqual({5000, ~"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}, lists:last(Rows)),
    ok = minato_conn:close(Ready).

%%----------------------------------------------------------------------
%% Socket options, which the socket transport has to answer for itself
%%----------------------------------------------------------------------

a_socket_option_the_driver_takes_is_taken_here(Config) ->
    Opts = (opts(Config))#{
        socket_options => [{keepalive, true}, {recbuf, 65536}, {sndbuf, 65536}]
    },
    {ok, Conn} = minato_conn:connect(Opts),
    {ok, #{rows := [{1}]}, Ready} = minato_query:query(Conn, ~"SELECT $1::int4", [1]),
    ok = minato_conn:close(Ready).

an_option_this_transport_cannot_honour_is_refused(Config) ->
    Opts = (opts(Config))#{socket_options => [{send_timeout, 5000}]},
    ok = judged(transport(Config), minato_conn:connect(Opts)).

%% `send_timeout` is the driver's, and this module has no answer for it. The
%% refusal is the point: an option that did something through the driver has to
%% either keep doing it or say that it stopped, never quietly become nothing.
judged(socket, {error, {socket, {unsupported_socket_option, {send_timeout, 5000}}}}) -> ok;
judged(inet, {ok, Conn}) -> minato_conn:close(Conn).

%%----------------------------------------------------------------------
%% The pool, which is where the ownership question lives
%%----------------------------------------------------------------------

a_pool_lends_a_connection_and_takes_it_back(Config) ->
    Name = pool(lends, Config),
    {ok, #{rows := [{42}]}} = minato:query(Name, ~"SELECT $1::int4", [42]),
    {ok, #{rows := [{43}]}} = minato:query(Name, ~"SELECT $1::int4", [43]),
    #{disconnects := 0, checkouts := 2} = minato_pool:stats(Name),
    _ = minato:stop_pool(Name).

a_pooled_connection_outlives_the_process_that_opened_it(Config) ->
    Name = pool(outlives, Config),
    _ = [minato:query(Name, ~"SELECT $1::int4", [N]) || N <- lists:seq(1, 20)],
    #{disconnects := 0} = minato_pool:stats(Name),
    _ = minato:stop_pool(Name).

a_borrower_that_dies_does_not_take_the_pool_down(Config) ->
    Name = pool(borrower, Config),
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
%% TLS, which ssl does over either handle unchanged
%%----------------------------------------------------------------------

tls_runs_over_this_transport(Config) ->
    case reachable() of
        false -> {skip, no_tls_server};
        true -> over_tls(Config)
    end.

%% The test certificates are made by the second compose service, so a machine
%% running the suite without it has no CA to verify against and no server to
%% verify. Reading the file first keeps that a skip rather than an enoent.
reachable() ->
    filelib:is_regular(certificate("ca.crt")).

over_tls(Config) ->
    case minato_conn:connect(secured(Config)) of
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

a_notification_arrives_over_this_transport(Config) ->
    Channel = channel(~"minato_transport_suite", Config),
    Conn = connected(Config),
    {ok, _Results, Listening} = minato_query:simple(Conn, <<"LISTEN ", Channel/binary>>),
    {ok, Waiting} = minato_conn:activate(Listening),
    ok = notify(Channel, ~"without a read outstanding", Config),
    {Kind, Notification} = awaited(Waiting),
    ?assertEqual(shape(transport(Config)), Kind),
    ?assertMatch(
        {notification_response, _Pid, Channel, ~"without a read outstanding"},
        Notification
    ),
    ok = minato_conn:close(Waiting).

%% The server going away while a wait is outstanding is not the same as a read
%% finding a closed socket, and the machines do not agree on how it is said: a
%% `select` that never becomes readable, a completion answered with an error, or
%% the wait taken away entirely with an `abort`. All three have to reach the
%% owner as a close, because an owner that hears nothing is a listener that
%% never reconnects.
a_connection_that_dies_while_waiting_says_so(Config) ->
    Marker = atom_to_binary(named(dies, Config)),
    {ok, Conn} = minato_conn:connect((opts(Config))#{
        parameters => #{~"application_name" => Marker}
    }),
    {ok, Waiting} = minato_conn:activate(Conn),
    ok = terminated(Marker, Config),
    ?assertMatch({closed, _Reason}, closed(Waiting)).

%% A wait is for one message, so what arrives before the close - the server's
%% own `FATAL` on its way out - is read and the connection armed again, which is
%% what a listener does between notifications.
closed(Conn) ->
    receive
        Message ->
            case minato_conn:handle_message(Conn, Message) of
                {messages, _Any, Again} -> closed(rearmed(Again));
                ignore -> closed(Conn);
                {closed, Reason} -> {closed, Reason}
            end
    after ?TIMEOUT -> ct:fail(never_said_it_closed)
    end.

rearmed(Conn) ->
    case minato_conn:activate(Conn) of
        {ok, Armed} -> Armed;
        {error, Reason} -> ct:fail({never_armed_again, Reason})
    end.

terminated(Marker, Config) ->
    {ok, Conn} = minato_conn:connect(opts(Config)),
    Sql = ~"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = $1",
    {ok, #{rows := Rows}, Ready} = minato_query:query(Conn, Sql, [Marker]),
    ok = minato_conn:close(Ready),
    ?assertMatch([_Killed | _Rest], Rows),
    ok.

a_connection_goes_back_to_reading_after_waiting(Config) ->
    Conn = connected(Config),
    {ok, Waiting} = minato_conn:activate(Conn),
    {ok, Passive} = minato_conn:deactivate(Waiting),
    {ok, #{rows := [{1}]}, Ready} = minato_query:query(Passive, ~"SELECT $1::int4", [1]),
    ok = minato_conn:close(Ready).

a_listener_runs_over_this_transport(Config) ->
    Name = named(listener, Config),
    First = channel(~"minato_transport_listener", Config),
    Second = channel(~"minato_transport_listener_again", Config),
    {ok, _Pid} = minato:start_listener(Name, #{connection => opts(Config)}),
    ok = minato:listen(Name, First),
    ok = notify(First, ~"all the way up", Config),
    receive
        {minato_notification, First, ~"all the way up", _From} -> ok
    after ?TIMEOUT -> ct:fail(no_notification)
    end,
    ok = minato:listen(Name, Second),
    ok = notify(Second, ~"and again", Config),
    receive
        {minato_notification, Second, ~"and again", _Also} -> ok
    after ?TIMEOUT -> ct:fail(no_second_notification)
    end,
    ok = minato:stop_listener(Name).

%% The kind is asserted rather than assumed, because it is the whole difference
%% between the machines and between the transports: POSIX says the socket is
%% readable and leaves the bytes in it, Windows completes the read and puts them
%% in the message, and the driver sends a `tcp` message with no `$socket` in
%% sight. A run that took another path would otherwise pass without ever
%% touching this one.
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

shape(inet) -> undefined;
shape(socket) -> shape(os:type());
shape({win32, _Flavour}) -> completion;
shape(_Posix) -> select.

notify(Channel, Payload, Config) ->
    {ok, Conn} = minato_conn:connect(opts(Config)),
    Sql = <<"NOTIFY ", Channel/binary, ", '", Payload/binary, "'">>,
    {ok, _Results, Ready} = minato_query:simple(Conn, Sql),
    minato_conn:close(Ready).

%%----------------------------------------------------------------------

connected(Config) ->
    {ok, Conn} = minato_conn:connect(opts(Config)),
    Conn.

secured(Config) ->
    (opts(Config))#{
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

%% Both groups run every case, so a pool, a listener or a `LISTEN` channel named
%% after the case alone would be named twice.
pool(Case, Config) ->
    Name = named(Case, Config),
    {ok, _Pid} = minato:start_pool(Name, #{
        size => 2, min_size => 2, connection => opts(Config)
    }),
    Name.

named(Case, Config) ->
    list_to_atom(
        "minato_transport_suite_" ++ atom_to_list(transport(Config)) ++ "_" ++ atom_to_list(Case)
    ).

channel(Prefix, Config) ->
    <<Prefix/binary, "_", (atom_to_binary(transport(Config)))/binary>>.

transport(Config) ->
    proplists:get_value(transport, Config).

opts(Config) ->
    (base())#{transport => transport(Config)}.

base() ->
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
