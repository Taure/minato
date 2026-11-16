-module(minato_socket_tests).
-moduledoc """
`minato_socket:quiet/2` over loopback, both ways of asking.

The Windows way is asked here on whatever machine runs the tests, because
`socket:ioctl/2` answers `nread` on POSIX too. What it cannot show is why Windows
needs it; the soak suite on the Windows runner is what shows that.
""".

-include_lib("eunit/include/eunit.hrl").

-define(WINDOWS, {win32, nt}).
-define(POSIX, {unix, linux}).

an_idle_socket_is_quiet_test() ->
    {Client, Server} = pair(),
    ?assert(minato_socket:quiet(Client, ?WINDOWS)),
    ?assert(minato_socket:quiet(Client, ?POSIX)),
    closed(Client, Server).

bytes_waiting_are_not_quiet_test() ->
    {Client, Server} = pair(),
    ok = gen_tcp:send(Server, ~"E"),
    ok = arrived(Client, 100),
    ?assertNot(minato_socket:quiet(Client, ?WINDOWS)),
    ?assertNot(minato_socket:quiet(Client, ?POSIX)),
    closed(Client, Server).

a_closed_peer_is_not_quiet_where_a_read_can_ask_test() ->
    {Client, Server} = pair(),
    ok = gen_tcp:close(Server),
    ?assert(eventually(fun() -> not minato_socket:quiet(Client, ?POSIX) end, 100)),
    ok = minato_socket:close(Client).

a_closed_socket_is_not_quiet_test() ->
    {Client, Server} = pair(),
    ok = minato_socket:close(Client),
    ?assertNot(minato_socket:quiet(Client, ?WINDOWS)),
    ?assertNot(minato_socket:quiet(Client, ?POSIX)),
    ok = gen_tcp:close(Server).

the_machine_it_runs_on_decides_how_to_ask_test() ->
    {Client, Server} = pair(),
    ?assert(minato_socket:quiet(Client)),
    ok = gen_tcp:send(Server, ~"E"),
    ok = arrived(Client, 100),
    ?assertNot(minato_socket:quiet(Client)),
    closed(Client, Server).

a_v6_address_connects_and_carries_bytes_test_() ->
    case gen_tcp:listen(0, [binary, inet6, {active, false}, {ip, {0, 0, 0, 0, 0, 0, 0, 1}}]) of
        {ok, Listen} ->
            [?_test(carried(Listen, {0, 0, 0, 0, 0, 0, 0, 1}))];
        {error, _No_v6_loopback_here} ->
            []
    end.

more_than_one_write_takes_is_all_sent_test_() ->
    {timeout, 30, fun() ->
        {Client, Server} = pair(),
        Sent = binary:copy(~"minato", 2000000),
        Parent = self(),
        Reader = spawn_link(fun() ->
            receive
                {read, Socket} ->
                    Parent ! {read, self(), gen_tcp:recv(Socket, byte_size(Sent), 20000)}
            end
        end),
        ok = gen_tcp:controlling_process(Server, Reader),
        Reader ! {read, Server},
        ?assertEqual(ok, minato_socket:send(Client, [Sent], 20000)),
        receive
            {read, Reader, Read} -> ?assertEqual({ok, Sent}, Read)
        after 20000 -> error(nothing_read)
        end,
        closed(Client, Server)
    end}.

carried(Listen, Address) ->
    {ok, Port} = inet:port(Listen),
    {ok, Client} = minato_socket:connect(Address, Port, [], 5000),
    {ok, Server} = gen_tcp:accept(Listen, 5000),
    ok = gen_tcp:close(Listen),
    ok = minato_socket:send(Client, ~"over v6"),
    ?assertEqual({ok, ~"over v6"}, gen_tcp:recv(Server, 7, 5000)),
    closed(Client, Server).

pair() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, loopback}]),
    {ok, Port} = inet:port(Listen),
    {ok, Client} = minato_socket:connect({127, 0, 0, 1}, Port, [], 5000),
    {ok, Server} = gen_tcp:accept(Listen, 5000),
    ok = gen_tcp:close(Listen),
    {Client, Server}.

closed(Client, Server) ->
    ok = minato_socket:close(Client),
    ok = gen_tcp:close(Server).

arrived(_Socket, 0) ->
    {error, nothing_arrived};
arrived(Socket, Attempts) ->
    case socket:ioctl(Socket, nread) of
        {ok, 0} ->
            timer:sleep(10),
            arrived(Socket, Attempts - 1);
        {ok, _Waiting} ->
            ok
    end.

eventually(_Check, 0) ->
    false;
eventually(Check, Attempts) ->
    case Check() of
        true ->
            true;
        false ->
            timer:sleep(10),
            eventually(Check, Attempts - 1)
    end.
