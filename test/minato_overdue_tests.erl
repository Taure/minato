-module(minato_overdue_tests).
-moduledoc """
The process that ends a TLS write which ran out of time, and what stands in
for it on a node where the `minato` application is not running.
""".

-include_lib("eunit/include/eunit.hrl").

%%----------------------------------------------------------------------
%% With the application
%%----------------------------------------------------------------------

it_is_started_with_the_application_and_only_once_test_() ->
    {timeout, 30, fun() ->
        _ = application:stop(minato),
        ?assertMatch({ok, _Started}, application:ensure_all_started(minato)),
        Pid = whereis(minato_overdue),
        ?assert(is_pid(Pid)),
        ?assertEqual({error, {already_started, Pid}}, minato_overdue:start_link())
    end}.

a_write_that_ran_out_has_its_socket_shut_down_test_() ->
    running(fun() ->
        Pid = whereis(minato_overdue),
        {Socket, Peer} = connected(),
        Watch = minato_overdue:watch(Socket, 50),
        ?assert(is_reference(Watch)),
        ?assertEqual(ok, socket:send(Socket, ~"before")),
        ok = timer:sleep(200),
        ?assertMatch({error, _Shut}, socket:send(Socket, ~"after")),
        ?assert(minato_overdue:ran_out(Watch)),
        ?assertEqual(Pid, whereis(minato_overdue)),
        closed(Socket, Peer)
    end).

a_write_that_finished_in_time_is_left_alone_test_() ->
    running(fun() ->
        {Socket, Peer} = connected(),
        Watch = minato_overdue:watch(Socket, 100),
        ?assertEqual(ok, minato_overdue:finished(Watch)),
        ok = timer:sleep(250),
        ?assertEqual(ok, socket:send(Socket, ~"still open")),
        closed(Socket, Peer)
    end).

a_write_that_failed_before_its_time_did_not_run_out_test_() ->
    running(fun() ->
        {Socket, Peer} = connected(),
        Watch = minato_overdue:watch(Socket, 60000),
        ?assertNot(minato_overdue:ran_out(Watch)),
        closed(Socket, Peer)
    end).

what_is_not_a_socket_does_not_stop_it_test_() ->
    running(fun() ->
        Pid = whereis(minato_overdue),
        _ = [
            minato_overdue ! Message
         || Message <- [{overdue, not_a_socket}, {overdue, make_ref()}, {overdue, self()}, hello]
        ],
        ok = gen_server:cast(minato_overdue, hello),
        ?assertEqual(ok, gen_server:call(minato_overdue, hello)),
        ?assertEqual(Pid, whereis(minato_overdue)),
        {Socket, Peer} = connected(),
        _Watch = minato_overdue:watch(Socket, 20),
        ok = timer:sleep(150),
        ?assertMatch({error, _Shut}, socket:send(Socket, ~"after")),
        closed(Socket, Peer)
    end).

%%----------------------------------------------------------------------
%% Without it
%%----------------------------------------------------------------------

without_the_application_a_write_still_runs_out_test_() ->
    stopped(fun() ->
        {Socket, Peer} = connected(),
        {_Timer, Alone} = Watch = minato_overdue:watch(Socket, 50),
        ?assert(is_process_alive(Alone)),
        ok = timer:sleep(200),
        ?assertMatch({error, _Shut}, socket:send(Socket, ~"after")),
        ?assert(minato_overdue:ran_out(Watch)),
        ?assertNot(is_process_alive(Alone)),
        closed(Socket, Peer)
    end).

without_the_application_a_write_that_finished_is_left_alone_test_() ->
    stopped(fun() ->
        {Socket, Peer} = connected(),
        {_Timer, Alone} = Watch = minato_overdue:watch(Socket, 100),
        ?assertEqual(ok, minato_overdue:finished(Watch)),
        ok = timer:sleep(250),
        ?assertNot(is_process_alive(Alone)),
        ?assertEqual(ok, socket:send(Socket, ~"still open")),
        closed(Socket, Peer)
    end).

without_the_application_a_write_that_failed_early_did_not_run_out_test_() ->
    stopped(fun() ->
        {Socket, Peer} = connected(),
        {_Timer, Alone} = Watch = minato_overdue:watch(Socket, 60000),
        ?assertNot(minato_overdue:ran_out(Watch)),
        ok = timer:sleep(50),
        ?assertNot(is_process_alive(Alone)),
        closed(Socket, Peer)
    end).

without_the_application_a_writer_that_died_is_not_waited_for_test_() ->
    stopped(fun() ->
        {Socket, Peer} = connected(),
        Self = self(),
        Writer = spawn(fun() ->
            Self ! {watching, minato_overdue:watch(Socket, 60000)}
        end),
        Alone =
            receive
                {watching, {_Timer, Pid}} -> Pid
            after 5000 -> error(not_watching)
            end,
        Monitor = erlang:monitor(process, Alone),
        ?assertNot(is_process_alive(Writer)),
        receive
            {'DOWN', Monitor, process, Alone, Reason} -> ?assertEqual(normal, Reason)
        after 5000 -> error(still_watching)
        end,
        ?assertEqual(ok, socket:send(Socket, ~"still open")),
        closed(Socket, Peer)
    end).

without_the_application_what_is_not_a_socket_ends_the_watch_quietly_test_() ->
    stopped(fun() ->
        {_Timer, Alone} = minato_overdue:watch(what_is_not_a_socket(), 10),
        Monitor = erlang:monitor(process, Alone),
        receive
            {'DOWN', Monitor, process, Alone, Reason} -> ?assertEqual(normal, Reason)
        after 5000 -> error(still_watching)
        end
    end).

%%----------------------------------------------------------------------
%% Either way
%%----------------------------------------------------------------------

a_write_that_finished_leaves_neither_a_timer_nor_a_message_test_() ->
    [
        Within(fun() ->
            {Socket, Peer} = connected(),
            Watch = minato_overdue:watch(Socket, 60000),
            ?assertEqual(ok, minato_overdue:finished(Watch)),
            ?assertEqual(false, left(timer(Watch), 50)),
            ?assertEqual(nothing, told_of_the_timer()),
            closed(Socket, Peer)
        end)
     || Within <- [fun running/1, fun stopped/1]
    ].

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

timer({Timer, _Alone}) -> Timer;
timer(Timer) -> Timer.

%% The timer is cancelled without waiting for it, so it is asked after a moment.
left(Timer, Tries) ->
    case erlang:read_timer(Timer) of
        false ->
            false;
        Left when Tries =:= 0 ->
            Left;
        _Left ->
            timer:sleep(10),
            left(Timer, Tries - 1)
    end.

told_of_the_timer() ->
    receive
        {cancel_timer, _Timer, _Left} = Told -> Told
    after 50 -> nothing
    end.

running(Fun) ->
    {timeout, 30, fun() ->
        {ok, _Started} = application:ensure_all_started(minato),
        Fun()
    end}.

stopped(Fun) ->
    {timeout, 30, fun() ->
        Running = lists:keymember(minato, 1, application:which_applications()),
        _ = application:stop(minato),
        try
            ?assertEqual(undefined, whereis(minato_overdue)),
            Fun()
        after
            _ = Running andalso application:ensure_all_started(minato)
        end
    end}.

what_is_not_a_socket() ->
    not_a_socket.

connected() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    {ok, Socket} = socket:open(inet, stream, tcp),
    ok = socket:connect(Socket, #{family => inet, addr => {127, 0, 0, 1}, port => Port}),
    {ok, Peer} = gen_tcp:accept(Listen, 5000),
    ok = gen_tcp:close(Listen),
    {Socket, Peer}.

closed(Socket, Peer) ->
    _ = socket:close(Socket),
    gen_tcp:close(Peer).
