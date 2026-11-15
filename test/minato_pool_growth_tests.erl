-module(minato_pool_growth_tests).
-moduledoc """
How many connections a pool opens at once, against a server that takes its time
over each and answers the reset as PostgreSQL does.
""".

-include_lib("eunit/include/eunit.hrl").

-export([answered/1]).

-define(POOL, minato_pool_growth_tests).
-define(SLOW, 300).

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).

-define(REFUSED, [
    {error_response, #{
        severity => ~"FATAL", code => ~"57P03", message => ~"the database system is starting up"
    }}
]).

-define(TEXT, #{
    name => ~"?column?",
    table_oid => 0,
    column => 0,
    type_oid => 25,
    type_size => -1,
    type_modifier => -1,
    format => text
}).

everybody_waiting_has_a_connection_on_its_way_test_() ->
    {timeout, 30, fun() ->
        Server = minato_backend_server:start(slow(?READY)),
        try
            ok = pooled(Server, #{size => 3, min_size => 1}),
            Started = erlang:monotonic_time(millisecond),
            Borrowers = [borrower() || _ <- lists:seq(1, 3)],
            Answers = [borrowed(Borrower) || Borrower <- Borrowers],
            Took = erlang:monotonic_time(millisecond) - Started,
            ?assertMatch([{ok, _}, {ok, _}, {ok, _}], Answers),
            ?assert(Took < 2 * ?SLOW),
            ?assertMatch(#{borrowed := 3, idle := 0, waiting := 0}, minato:stats(?POOL)),
            ok = lists:foreach(fun returned/1, Borrowers)
        after
            _ = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end}.

no_more_are_opened_than_are_waited_for_test_() ->
    {timeout, 30, fun() ->
        Server = minato_backend_server:start(slow(?READY)),
        try
            ok = pooled(Server, #{size => 5, min_size => 0}),
            Borrowers = [borrower() || _ <- lists:seq(1, 2)],
            ?assertMatch([{ok, _}, {ok, _}], [borrowed(Borrower) || Borrower <- Borrowers]),
            timer:sleep(?SLOW),
            ?assertEqual(2, startups(minato_backend_server:received(Server))),
            ?assertMatch(#{borrowed := 2, idle := 0}, minato:stats(?POOL)),
            ok = lists:foreach(fun returned/1, Borrowers)
        after
            _ = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end}.

a_pool_never_grows_past_its_size_for_those_waiting_test_() ->
    {timeout, 30, fun() ->
        Server = minato_backend_server:start(slow(?READY)),
        try
            ok = pooled(Server, #{size => 2, min_size => 0}),
            Borrowers = [borrower() || _ <- lists:seq(1, 4)],
            Answers = [borrowed(Borrower) || Borrower <- Borrowers],
            ?assertEqual(2, length([Conn || {ok, Conn} <- Answers])),
            ?assertEqual(2, length([Late || {error, checkout_timeout} = Late <- Answers])),
            ?assertEqual(2, startups(minato_backend_server:received(Server))),
            ok = lists:foreach(fun returned/1, Borrowers)
        after
            _ = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end}.

a_server_that_is_refusing_is_asked_one_at_a_time_test_() ->
    {timeout, 30, fun() ->
        Server = minato_backend_server:start([{then, [], 150, ?REFUSED}]),
        try
            ok = pooled(Server, #{size => 3, min_size => 1, disconnected => wait}),
            Borrowers = [borrower() || _ <- lists:seq(1, 3)],
            Answers = [borrowed(Borrower) || Borrower <- Borrowers],
            ?assertEqual(lists:duplicate(3, {error, checkout_timeout}), Answers),
            Asked = startups(minato_backend_server:received(Server)),
            ?assert(Asked >= 3),
            ?assert(Asked =< 6)
        after
            _ = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end}.

%%----------------------------------------------------------------------
%% The server
%%----------------------------------------------------------------------

slow(Opening) ->
    [{then, [], ?SLOW, Opening} | lists:duplicate(8, {reply, {?MODULE, answered}})].

-doc false.
answered({query, ~"SHOW max_connections"}) ->
    [
        {row_description, [?TEXT]},
        {data_row, [~"100"]},
        {command_complete, ~"SHOW"},
        {ready_for_query, idle}
    ];
answered({query, <<"CLOSE ALL; ", _/binary>> = Reset}) ->
    [
        {command_complete, ~"CLOSE CURSOR ALL"},
        {command_complete, ~"SET"},
        {command_complete, ~"RESET"},
        {command_complete, ~"UNLISTEN"},
        {row_description, [?TEXT]},
        {data_row, [~""]},
        {command_complete, ~"SELECT 1"},
        {command_complete, ~"DISCARD TEMP"},
        {command_complete, ~"DISCARD SEQUENCES"},
        {row_description, [?TEXT]},
        {data_row, [nonce(Reset)]},
        {command_complete, ~"SELECT 1"},
        {ready_for_query, idle}
    ].

nonce(Reset) ->
    [_Before, Quoted] = binary:split(Reset, ~"DISCARD SEQUENCES; SELECT '"),
    [Nonce, _After] = binary:split(Quoted, ~"'"),
    Nonce.

startups(Read) ->
    length([Startup || {startup, _Parameters} = Startup <- Read]).

%%----------------------------------------------------------------------
%% Borrowers
%%----------------------------------------------------------------------

borrower() ->
    Test = self(),
    spawn_link(fun() ->
        Answer = minato_pool:checkout(?POOL, 1000),
        Test ! {borrowed, self(), Answer},
        receive
            return -> gave_back(Answer)
        end,
        Test ! {returned, self()}
    end).

gave_back({ok, Conn}) -> minato_pool:checkin(?POOL, Conn);
gave_back({error, _Reason}) -> ok.

borrowed(Borrower) ->
    receive
        {borrowed, Borrower, Answer} -> Answer
    after 3000 -> error(never_answered)
    end.

returned(Borrower) ->
    Borrower ! return,
    receive
        {returned, Borrower} -> ok
    after 3000 -> error(never_returned)
    end.

pooled(Server, Sizes) ->
    {ok, _Started} = application:ensure_all_started(minato),
    _ = minato:stop_pool(?POOL),
    Connection = #{
        host => "127.0.0.1",
        port => minato_backend_server:port(Server),
        user => ~"minato",
        timeout => 1000
    },
    {ok, _Pool} = minato:start_pool(?POOL, Sizes#{connection => Connection}),
    ok.
