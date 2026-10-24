-module(minato_pool_reset_tests).
-moduledoc """
A pool whose every connection answers the reset with something else, which no
real server can be made to do without a superuser.
""".

-include_lib("eunit/include/eunit.hrl").

-define(POOL, minato_pool_reset_tests).

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).

-define(NOT_THE_RESET, [{command_complete, ~"SELECT 1"}, {ready_for_query, idle}]).

-define(SHOWN, [{command_complete, ~"SHOW"}, {ready_for_query, idle}]).

-define(REFUSED, [
    {command_complete, ~"CLOSE CURSOR ALL"},
    {error_response, #{
        severity => ~"ERROR", code => ~"42501", message => ~"role alice_secret denied"
    }},
    {ready_for_query, idle}
]).

a_checkout_gives_up_after_the_pool_and_one_more_test_() ->
    {timeout, 30, fun a_checkout_gives_up_after_the_pool_and_one_more/0}.

a_checkout_gives_up_after_the_pool_and_one_more() ->
    {ok, _Started} = application:ensure_all_started(minato),
    Server = minato_backend_server:start([
        ?READY, ?NOT_THE_RESET, ?NOT_THE_RESET, ?NOT_THE_RESET, ?NOT_THE_RESET
    ]),
    {ok, _Pid} = minato:start_pool(?POOL, #{
        size => 2, min_size => 2, connection => connection(Server)
    }),
    try
        ?assertEqual(
            {error, {session_reset, unread_answer}}, minato_pool:checkout(?POOL, 5000)
        ),
        Opened = [Startup || {startup, _} = Startup <- minato_backend_server:received(Server)],
        ?assert(length(Opened) =< 5)
    after
        ok = minato:stop_pool(?POOL),
        minato_backend_server:stop(Server)
    end.

a_refused_reset_reports_only_its_sqlstate_test_() ->
    {timeout, 30, fun a_refused_reset_reports_only_its_sqlstate/0}.

a_refused_reset_reports_only_its_sqlstate() ->
    {ok, _Started} = application:ensure_all_started(minato),
    Server = minato_backend_server:start([?READY, ?REFUSED, ?REFUSED]),
    {ok, _Pid} = minato:start_pool(?POOL, #{
        size => 1, min_size => 1, connection => connection(Server)
    }),
    try
        ?assertEqual(
            {error, {session_reset, {pgsql_error, #{code => ~"42501"}}}},
            minato_pool:checkout(?POOL, 5000)
        )
    after
        ok = minato:stop_pool(?POOL),
        minato_backend_server:stop(Server)
    end.

%% Outside a transaction a `ROLLBACK` is a warning in the server log, once per
%% checkin.
a_connection_with_no_transaction_is_reset_without_a_rollback_test_() ->
    {timeout, 30, fun a_connection_with_no_transaction_is_reset_without_a_rollback/0}.

a_connection_with_no_transaction_is_reset_without_a_rollback() ->
    {ok, _Started} = application:ensure_all_started(minato),
    Server = minato_backend_server:start([?READY, ?SHOWN]),
    {ok, _Pid} = minato:start_pool(?POOL, #{
        size => 1, min_size => 1, connection => connection(Server)
    }),
    try
        Queries = [Sql || {query, Sql} <- minato_backend_server:received(Server)],
        ?assertMatch([~"SHOW max_connections", <<"CLOSE ALL; ", _/binary>>], Queries)
    after
        ok = minato:stop_pool(?POOL),
        minato_backend_server:stop(Server)
    end.

connection(Server) ->
    #{
        host => "127.0.0.1",
        port => minato_backend_server:port(Server),
        user => ~"minato",
        timeout => 1000
    }.
