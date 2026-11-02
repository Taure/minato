-module(minato_tls_SUITE).
-moduledoc """
TLS, against a PostgreSQL that really has it.

Every other suite talks to a server with no TLS, which can only prove that
minato refuses to continue when a server declines - the failure path. It cannot
prove the one that matters: that a handshake completes, that the certificate is
verified against a CA rather than accepted, that the hostname is checked, and
that what follows is a working session on an encrypted socket.

The TLS server in the compose file generates its own certificate authority and
a `localhost` certificate signed by it when it starts, and writes both
certificates into `test/certs`, which git ignores. The private keys never leave
the container: a key committed to a repository is a key somebody has to reason
about, and generating one costs a second.

The suite verifies against that CA, which is what a deployment with a private CA
does.

The server is the judge of whether the session is encrypted:
`pg_stat_ssl` reports it per backend, so the suite asks the server rather than
believing the client.

Skips when no TLS server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    a_verified_handshake_opens_a_working_session/1,
    the_server_reports_the_session_as_encrypted/1,
    an_untrusted_certificate_is_refused/1,
    a_hostname_the_certificate_does_not_cover_is_refused/1,
    verification_can_be_turned_off_deliberately/1,
    a_query_of_any_size_survives_the_tls_record_layer/1,
    a_transaction_works_over_tls/1,
    the_exchange_is_bound_to_the_tls_session/1,
    channel_binding_can_be_required/1,
    a_required_binding_is_refused_without_tls/1,
    the_certificate_hash_is_the_one_the_server_computes/1,
    a_ca_pinned_by_file_is_the_ca_that_decides/1,
    closing_a_session_never_waits_for_ever/1,
    closing_with_answers_unread_waits_only_for_the_server/1,
    closing_a_busy_session_is_bounded/1,
    on_windows_an_idle_session_closes_once_the_server_has/1,
    on_windows_closing_a_busy_session_waits_a_second_at_most/1
]).

-define(TIMEOUT, 15000).
-define(SLOW_AFTER, 20000).
-define(WINDOWS, {win32, nt}).

%% Without one of these a case that blocks runs into Common Test's thirty minute
%% default, which is longer than CI gives the whole step, so a hang arrives as a
%% killed job with no case name and no stack. Every operation in this suite is
%% bounded by a five second connect or a ten second read, so a case that reaches
%% sixty seconds is stuck somewhere that has no deadline of its own, and the
%% timetrap's stack trace is the thing worth having.
-spec suite() -> [{timetrap, {seconds, pos_integer()}}].
suite() ->
    [{timetrap, {seconds, 60}}].

-spec all() -> [atom()].
all() ->
    [
        a_verified_handshake_opens_a_working_session,
        the_server_reports_the_session_as_encrypted,
        an_untrusted_certificate_is_refused,
        a_hostname_the_certificate_does_not_cover_is_refused,
        verification_can_be_turned_off_deliberately,
        a_query_of_any_size_survives_the_tls_record_layer,
        a_transaction_works_over_tls,
        the_exchange_is_bound_to_the_tls_session,
        channel_binding_can_be_required,
        a_required_binding_is_refused_without_tls,
        the_certificate_hash_is_the_one_the_server_computes,
        a_ca_pinned_by_file_is_the_ca_that_decides,
        closing_a_session_never_waits_for_ever,
        closing_with_answers_unread_waits_only_for_the_server,
        closing_a_busy_session_is_bounded,
        on_windows_an_idle_session_closes_once_the_server_has,
        on_windows_closing_a_busy_session_waits_a_second_at_most
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case gen_tcp:connect(host(), port(), [binary, {active, false}], ?TIMEOUT) of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            Config;
        {error, Reason} ->
            {skip, {no_tls_server, host(), port(), Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok.

-spec init_per_testcase(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_testcase(Case, Config) ->
    Test = self(),
    [{slow_watch, spawn(fun() -> watch(Case, Test) end)} | Config].

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(_Case, Config) ->
    stop_watching(proplists:get_value(slow_watch, Config)).

stop_watching(Watch) when is_pid(Watch) ->
    exit(Watch, kill),
    ok;
stop_watching(_None) ->
    ok.

watch(Case, Test) ->
    receive
    after ?SLOW_AFTER -> slow(Case, Test)
    end.

slow(Case, Test) ->
    Processes = [describe(Pid) || Pid <- erlang:processes(), Pid =:= Test orelse tls_related(Pid)],
    Sockets = [{Socket, socket:info(Socket)} || Socket <- socket:which_sockets()],
    ct:pal(
        "slow: ~p still running after ~pms~nprocesses:~n~p~nsockets:~n~p",
        [Case, ?SLOW_AFTER, Processes, Sockets]
    ).

describe(Pid) ->
    Info = erlang:process_info(Pid, [
        registered_name,
        initial_call,
        current_stacktrace,
        status,
        message_queue_len,
        messages,
        links
    ]),
    {Pid, initial(Pid), trimmed(Info)}.

trimmed(undefined) -> undefined;
trimmed(Info) -> [trim(Item) || Item <- Info].

trim({messages, Messages}) -> {messages, lists:sublist(Messages, 10)};
trim(Item) -> Item.

initial(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dictionary} -> proplists:get_value('$initial_call', Dictionary);
        undefined -> undefined
    end.

tls_related(Pid) ->
    Frames =
        case erlang:process_info(Pid, current_stacktrace) of
            {current_stacktrace, Stack} -> [Module || {Module, _F, _A, _L} <- Stack];
            undefined -> []
        end,
    Initial =
        case initial(Pid) of
            {Module, _F, _A} -> [Module];
            _None -> []
        end,
    lists:any(fun tls_module/1, Frames ++ Initial).

tls_module(Module) ->
    lists:member(Module, [
        tls_client_connection,
        tls_client_connection_1_3,
        tls_gen_connection,
        tls_sender,
        tls_socket_tcp,
        ssl_gen_statem,
        socket,
        prim_socket
    ]).

-spec a_verified_handshake_opens_a_working_session([{atom(), term()}]) -> ok.
a_verified_handshake_opens_a_working_session(_Config) ->
    {ok, Conn} = minato_conn:connect(verified()),
    {ok, #{rows := [{42}]}, Read} = minato_query:query(Conn, ~"SELECT $1::int4", [42]),
    ok = minato_conn:close(Read).

-spec the_server_reports_the_session_as_encrypted([{atom(), term()}]) -> ok.
the_server_reports_the_session_as_encrypted(_Config) ->
    {ok, Conn} = minato_conn:connect(verified()),
    Sql = ~"SELECT ssl, version FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
    {ok, #{rows := [{Encrypted, Version}]}, Read} = minato_query:query(Conn, Sql, []),
    ok = minato_conn:close(Read),
    ?assertEqual(true, Encrypted),
    ?assertMatch(<<"TLSv1", _Rest/binary>>, Version).

-spec an_untrusted_certificate_is_refused([{atom(), term()}]) -> ok.
an_untrusted_certificate_is_refused(_Config) ->
    Trusting = maps:remove(ssl_options, verified()),
    ?assertMatch({error, {tls, _Reason}}, minato_conn:connect(Trusting)).

-spec a_hostname_the_certificate_does_not_cover_is_refused([{atom(), term()}]) -> ok.
a_hostname_the_certificate_does_not_cover_is_refused(_Config) ->
    Elsewhere = (verified())#{host => "127.0.0.1", ssl_options => [{cacerts, cacerts()}]},
    ?assertMatch({error, {tls, _Reason}}, minato_conn:connect(Elsewhere)).

%% `cacertfile` and `cacerts` answer the same question, so a caller who pins a
%% private CA by file must not also be handed the public bundle: two answers to
%% "which authorities are trusted" is the wider one deciding. The test CA is not
%% in any public bundle, so a handshake that succeeds is one this file carried.
-spec a_ca_pinned_by_file_is_the_ca_that_decides([{atom(), term()}]) -> ok.
a_ca_pinned_by_file_is_the_ca_that_decides(_Config) ->
    Pinned = (verified())#{ssl_options => [{cacertfile, certificate("ca.crt")}]},
    {ok, Conn} = minato_conn:connect(Pinned),
    {ok, #{rows := [{1}]}, Ready} = minato_query:query(Conn, ~"SELECT $1::int4", [1]),
    ok = minato_conn:close(Ready).

-spec verification_can_be_turned_off_deliberately([{atom(), term()}]) -> ok.
verification_can_be_turned_off_deliberately(_Config) ->
    Unverified = (verified())#{host => "127.0.0.1", ssl_options => [{verify, verify_none}]},
    {ok, Conn} = minato_conn:connect(Unverified),
    ok = minato_conn:close(Conn).

-spec a_query_of_any_size_survives_the_tls_record_layer([{atom(), term()}]) -> ok.
a_query_of_any_size_survives_the_tls_record_layer(_Config) ->
    {ok, Conn} = minato_conn:connect(verified()),
    Value = crypto:strong_rand_bytes(1000000),
    {ok, #{rows := [{Back}]}, Read} = minato_query:query(Conn, ~"SELECT $1::bytea", [Value]),
    ?assertEqual(Value, Back),
    Rows = ~"SELECT i FROM generate_series(1, 5000) i",
    {ok, #{num_rows := Count}, Counted} = minato_query:query(Read, Rows, []),
    ok = minato_conn:close(Counted),
    ?assertEqual(5000, Count).

-spec a_transaction_works_over_tls([{atom(), term()}]) -> ok.
a_transaction_works_over_tls(_Config) ->
    {ok, Conn} = minato_conn:connect(verified()),
    {ok, both, Committed} = minato_txn:transaction(Conn, fun(Open) ->
        {ok, _First, One} = minato_query:query(Open, ~"SELECT 1", []),
        {ok, _Second, Two} = minato_query:query(One, ~"SELECT 2", []),
        {ok, both, Two}
    end),
    ?assertEqual(idle, minato_txn:status(Committed)),
    ok = minato_conn:close(Committed).

-spec the_exchange_is_bound_to_the_tls_session([{atom(), term()}]) -> ok.
the_exchange_is_bound_to_the_tls_session(_Config) ->
    {ok, Conn} = minato_conn:connect(verified()),
    ?assertMatch(<<_Hash/binary>>, minato_conn:channel_binding(Conn)),
    ok = minato_conn:close(Conn).

-spec channel_binding_can_be_required([{atom(), term()}]) -> ok.
channel_binding_can_be_required(_Config) ->
    Bound = (verified())#{channel_binding => require},
    {ok, Conn} = minato_conn:connect(Bound),
    {ok, #{rows := [{1}]}, Read} = minato_query:query(Conn, ~"SELECT 1", []),
    ok = minato_conn:close(Read).

-spec a_required_binding_is_refused_without_tls([{atom(), term()}]) -> ok.
a_required_binding_is_refused_without_tls(_Config) ->
    Plain = #{
        host => "127.0.0.1",
        port => list_to_integer(env("MINATO_PG_PORT", "55432")),
        user => list_to_binary(env("MINATO_PG_USER", "minato")),
        password => list_to_binary(env("MINATO_PG_PASSWORD", "minato")),
        database => list_to_binary(env("MINATO_PG_DATABASE", "minato_test")),
        channel_binding => require,
        timeout => ?TIMEOUT
    },
    ?assertError(
        {minato_auth, #{reason := {channel_binding_not_offered, _Mechanisms}}},
        minato_conn:connect(Plain)
    ).

-spec the_certificate_hash_is_the_one_the_server_computes([{atom(), term()}]) -> ok.
the_certificate_hash_is_the_one_the_server_computes(_Config) ->
    {ok, Conn} = minato_conn:connect(verified()),
    Hash = minato_conn:channel_binding(Conn),
    ok = minato_conn:close(Conn),
    [{'Certificate', Der, not_encrypted}] = public_key:pem_decode(pem()),
    ?assertEqual(crypto:hash(sha256, Der), Hash).

%% On Windows about one close in a few hundred used to hang in `socket:close/1`
%% inside the TLS connection process (#58), so a few hundred closes is what it
%% takes for this to say anything there. Nowhere else has the race to find.
-spec closing_a_session_never_waits_for_ever([{atom(), term()}]) -> ok.
closing_a_session_never_waits_for_ever(_Config) ->
    lists:foreach(
        fun(_) ->
            {ok, Conn} = minato_conn:connect(verified()),
            ok = minato_conn:close(Conn)
        end,
        lists:seq(1, closes(os:type()))
    ).

closes({win32, _Name}) -> 300;
closes(_Os) -> 30.

-spec closing_with_answers_unread_waits_only_for_the_server([{atom(), term()}]) -> ok.
closing_with_answers_unread_waits_only_for_the_server(_Config) ->
    {ok, Conn} = minato_conn:connect((verified())#{cancel_timeout => 10000}),
    ok = minato_conn:send(Conn, {query, ~"SELECT i FROM generate_series(1, 100000) i"}),
    Started = erlang:monotonic_time(millisecond),
    ok = minato_conn:close(Conn),
    ?assert(erlang:monotonic_time(millisecond) - Started < 5000).

-spec closing_a_busy_session_is_bounded([{atom(), term()}]) -> ok.
closing_a_busy_session_is_bounded(_Config) ->
    {ok, Conn} = minato_conn:connect((verified())#{cancel_timeout => infinity}),
    ok = minato_conn:send(Conn, {query, ~"SELECT pg_sleep(20)"}),
    {Took, ok} = timed(fun() -> minato_conn:close(Conn) end),
    ?assert(Took < 2000).

%% The Windows close, asked for here on whatever machine runs the suite, against
%% a server that really closes: it ends because the server closed, not because
%% the wait ran out.
-spec on_windows_an_idle_session_closes_once_the_server_has([{atom(), term()}]) -> ok.
on_windows_an_idle_session_closes_once_the_server_has(_Config) ->
    {ok, Conn} = minato_conn:connect(verified()),
    {Took, ok} = timed(fun() -> minato_conn:close(Conn, ?WINDOWS) end),
    ?assert(Took < 500).

-spec on_windows_closing_a_busy_session_waits_a_second_at_most([{atom(), term()}]) -> ok.
on_windows_closing_a_busy_session_waits_a_second_at_most(_Config) ->
    {ok, Conn} = minato_conn:connect((verified())#{cancel_timeout => infinity}),
    ok = minato_conn:send(Conn, {query, ~"SELECT pg_sleep(20)"}),
    {Took, ok} = timed(fun() -> minato_conn:close(Conn, ?WINDOWS) end),
    ?assert(Took >= 1000),
    ?assert(Took < 2000).

timed(Fun) ->
    Started = erlang:monotonic_time(millisecond),
    Result = Fun(),
    {erlang:monotonic_time(millisecond) - Started, Result}.

%%----------------------------------------------------------------------
%% Where the server is
%%----------------------------------------------------------------------

verified() ->
    #{
        host => host(),
        port => port(),
        user => list_to_binary(env("MINATO_PG_USER", "minato")),
        password => list_to_binary(env("MINATO_PG_PASSWORD", "minato")),
        database => list_to_binary(env("MINATO_PG_DATABASE", "minato_test")),
        ssl => true,
        ssl_options => [{cacerts, cacerts()}],
        timeout => ?TIMEOUT
    }.

cacerts() ->
    {ok, Pem} = file:read_file(certificate("ca.crt")),
    [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)].

pem() ->
    {ok, Pem} = file:read_file(certificate("server.crt")),
    Pem.

certificate(Name) ->
    Directory = code:lib_dir(minato),
    filename:join([directory(Directory), "test", "certs", Name]).

directory({error, Reason}) ->
    error({no_application_directory, Reason});
directory(Directory) ->
    Directory.

host() ->
    env("MINATO_TLS_HOST", "localhost").

port() ->
    list_to_integer(env("MINATO_TLS_PORT", "55433")).

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
