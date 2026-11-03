-module(minato_pool_connector_tests).
-moduledoc """
The process a pool starts to open a connection can die without answering.

The server here accepts and never says a word, so the connector waits on its
first read for as long as its timeout allows and is killed while it waits. The
pool has to count that as a failed connect and try again, or it holds the slot
as in flight for good and never fills.
""".

-include_lib("eunit/include/eunit.hrl").

-define(POOL, minato_pool_connector_tests).

a_connector_that_dies_without_answering_is_retried_test() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    Test = self(),
    Acceptor = spawn(fun() -> accepting(Listen, Test, []) end),
    ok = gen_tcp:controlling_process(Listen, Acceptor),
    Trapping = process_flag(trap_exit, true),
    {ok, Pool} = minato_pool:start_link(?POOL, #{
        size => 1,
        min_size => 1,
        connection => #{host => "127.0.0.1", port => Port, user => ~"u", timeout => 60000}
    }),
    try
        ok = accepted(1),
        [Connector] = connectors(),
        exit(Connector, kill),
        ok = accepted(2),
        ?assertMatch(#{disconnects := 1, idle := 0}, minato_pool:stats(?POOL))
    after
        ok = gen_server:stop(Pool),
        process_flag(trap_exit, Trapping),
        exit(Acceptor, kill)
    end.

accepting(Listen, Test, Held) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Test ! {accepted, length(Held) + 1},
    accepting(Listen, Test, [Socket | Held]).

accepted(Count) ->
    receive
        {accepted, Count} -> ok
    after 3000 -> error({not_accepted, Count})
    end.

%% The connector is a plain fun, so its initial call says nothing; its stack is
%% where it shows.
connectors() ->
    Depth = erlang:system_flag(backtrace_depth, 64),
    try
        [Pid || Pid <- processes(), connecting(erlang:process_info(Pid, current_stacktrace))]
    after
        erlang:system_flag(backtrace_depth, Depth)
    end.

connecting({current_stacktrace, Frames}) ->
    lists:keymember(connected, 2, [Frame || {minato_pool, _, _, _} = Frame <- Frames]);
connecting(undefined) ->
    false.
