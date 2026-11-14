-module(minato_pool_limit_tests).
-moduledoc """
What a pool makes of the limit it asks its first connection for, against a
server that answers the question with whatever each case needs.
""".

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

-define(POOL, minato_pool_limit_tests).

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).

-define(NOT_THE_RESET, [{command_complete, ~"SELECT 1"}, {ready_for_query, idle}]).

%%----------------------------------------------------------------------
%% The limit a pool asks its first connection for
%%----------------------------------------------------------------------

a_limit_is_read_from_a_short_run_of_digits_and_nothing_else_test_() ->
    [
        ?_assertEqual(Expected, minato_pool:limit(Results))
     || {Expected, Results} <- [
            {100, [#{rows => [{~"100"}]}]},
            {0, [#{rows => [{~"0"}]}]},
            {1234567890, [#{rows => [{~"1234567890"}]}]},
            {unknown, [#{rows => [{~"plenty"}]}]},
            {unknown, [#{rows => [{~"100 or so"}]}]},
            {unknown, [#{rows => [{~"-1"}]}]},
            {unknown, [#{rows => [{~""}]}]},
            {unknown, [#{rows => [{binary:copy(~"9", 11)}]}]},
            {unknown, [#{rows => [{null}]}]},
            {unknown, [#{rows => [{~"100"}, {~"200"}]}]},
            {unknown, [#{rows => [{~"100", ~"200"}]}]},
            {unknown, [#{rows => []}]},
            {unknown, []}
        ]
    ].

a_pool_outlives_whatever_answers_its_question_test_() ->
    [
        {timeout, 30,
            {Label, fun() ->
                ok = ready(),
                Server = minato_backend_server:start([?READY, Answer]),
                Connection = opts(minato_backend_server:port(Server), #{timeout => 1000}),
                {ok, Pool} = minato:start_pool(?POOL, #{
                    size => 1, min_size => 1, connection => Connection
                }),
                try
                    ok = asked_for_the_limit(Server, 50),
                    timer:sleep(300),
                    ?assertEqual(Pool, whereis(?POOL)),
                    ?assertMatch(#{size := 1}, minato:stats(?POOL))
                after
                    ok = minato:stop_pool(?POOL),
                    minato_backend_server:stop(Server)
                end
            end}}
     || {Label, Answer} <- [
            {"a limit that is not a number", shown(~"plenty")},
            {"a limit of a megabyte of digits", shown(binary:copy(~"9", 1 bsl 20))},
            {"a row with no columns", [{data_row, <<0:16>>}, {ready_for_query, idle}]},
            {"a message that is not one", [{unsupported, $D, ~"x"}, {ready_for_query, idle}]},
            {"a refusal", [
                {error_response, #{
                    severity => ~"ERROR", code => ~"42501", message => ~"permission denied"
                }},
                {ready_for_query, idle}
            ]}
        ]
    ].

a_pool_still_answers_while_its_question_goes_unanswered_test_() ->
    {timeout, 30, fun() ->
        ok = ready(),
        Server = minato_backend_server:start([?READY]),
        Connection = opts(minato_backend_server:port(Server), #{timeout => 5000}),
        {ok, _Pool} = minato:start_pool(?POOL, #{
            size => 1, min_size => 1, connection => Connection
        }),
        try
            ok = asked_for_the_limit(Server, 50),
            {Microseconds, Stats} = timer:tc(fun() -> minato:stats(?POOL) end),
            ?assertMatch(#{size := 1, idle := 0}, Stats),
            ?assert(Microseconds < 1000000)
        after
            ok = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end}.

shown(Limit) ->
    [
        {row_description, [
            #{
                name => ~"max_connections",
                table_oid => 0,
                column => 0,
                type_oid => 25,
                type_size => -1,
                type_modifier => -1,
                format => text
            }
        ]},
        {data_row, [Limit]},
        {command_complete, ~"SHOW"},
        {ready_for_query, idle}
    ].

asked_for_the_limit(_Server, 0) ->
    error(never_asked);
asked_for_the_limit(Server, Tries) ->
    case
        [Sql || {query, ~"SHOW max_connections" = Sql} <- minato_backend_server:received(Server)]
    of
        [] -> asked_for_the_limit(Server, Tries - 1);
        _Asked -> ok
    end.

%%----------------------------------------------------------------------
%% What the pool does with the answer
%%----------------------------------------------------------------------

a_pool_that_wants_more_than_a_quarter_of_the_limit_says_so_once_test_() ->
    {timeout, 30, fun() ->
        ?assertMatch(
            [#{size := 26, server_max_connections := 100}], budgets(26)
        )
    end}.

a_pool_that_wants_a_quarter_of_the_limit_says_nothing_test_() ->
    {timeout, 30, fun() -> ?assertEqual([], budgets(25)) end}.

%% Two connections are opened before either has its answer, so both ask.
budgets(Size) ->
    Warnings = warnings(fun() ->
        Server = minato_backend_server:start([?READY, shown(~"100")]),
        try
            ok = pooled(Server, #{size => Size, min_size => 2}),
            Read = read(Server, fun(Seen) -> limits(Seen) >= 2 end),
            ?assertEqual(2, limits(Read)),
            timer:sleep(100),
            ?assertMatch(#{disconnects := 0}, minato:stats(?POOL))
        after
            _ = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end),
    [Warning || #{event := connection_budget} = Warning <- Warnings].

%% No connection here answers the reset, so a checkout goes through more than
%% one, and the pool has its answer from the first.
a_connection_opened_after_the_answer_is_not_asked_again_test_() ->
    {timeout, 30, fun() ->
        Server = minato_backend_server:start([?READY, shown(~"100"), ?NOT_THE_RESET]),
        try
            ok = pooled(Server, #{size => 1, min_size => 1}),
            ?assertEqual(
                {error, {session_reset, unread_answer}}, minato_pool:checkout(?POOL, 5000)
            ),
            Read = read(Server, fun(Seen) -> resets(Seen) >= 2 end),
            ?assert(resets(Read) >= 2),
            ?assertEqual(1, limits(Read))
        after
            _ = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end}.

a_question_that_is_never_answered_costs_the_connection_test_() ->
    {timeout, 30, fun() ->
        Server = minato_backend_server:start([?READY]),
        try
            Failed = failures(fun() ->
                ok = pooled(Server, #{size => 1, min_size => 1}, #{timeout => 200}),
                Read = read(Server, fun(Seen) -> limits(Seen) >= 2 end),
                ?assert(limits(Read) >= 2),
                ?assert(lists:member(terminate, Read)),
                ?assertMatch(#{disconnects := Lost} when Lost >= 1, minato:stats(?POOL))
            end),
            ?assertMatch([#{reason := {socket, timeout}} | _Later], Failed)
        after
            _ = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end}.

an_answer_that_is_not_a_message_costs_the_connection_test_() ->
    {timeout, 30, fun() ->
        NotOne = [{unsupported, $D, ~"x"}, {ready_for_query, idle}],
        Server = minato_backend_server:start([?READY, NotOne]),
        try
            Failed = failures(fun() ->
                ok = pooled(Server, #{size => 1, min_size => 1}),
                Read = read(Server, fun(Seen) -> limits(Seen) >= 2 end),
                ?assert(limits(Read) >= 2),
                ?assert(lists:member(terminate, Read))
            end),
            ?assertMatch([#{reason := {minato_protocol, _Why}} | _Later], Failed)
        after
            _ = minato:stop_pool(?POOL),
            minato_backend_server:stop(Server)
        end
    end}.

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

%% A run that was cut short leaves its pool under the supervisor, and the next
%% run would find the name taken.
ready() ->
    {ok, _Started} = application:ensure_all_started(minato),
    _ = minato:stop_pool(?POOL),
    ok.

pooled(Server, Sizes) ->
    pooled(Server, Sizes, #{}).

pooled(Server, Sizes, Opts) ->
    ok = ready(),
    Connection = opts(minato_backend_server:port(Server), Opts),
    {ok, _Pool} = minato:start_pool(?POOL, Sizes#{connection => Connection}),
    ok.

opts(Port, Opts) ->
    maps:merge(
        #{host => "127.0.0.1", port => Port, user => ~"minato", timeout => 5000},
        Opts
    ).

%% Everything the server has read, once that is enough or it has been asked
%% often enough. The server hands over what it read only once, so it is kept.
read(Server, Enough) ->
    read(Server, Enough, 25, []).

read(Server, Enough, Tries, Before) ->
    Read = Before ++ minato_backend_server:received(Server),
    case Tries =:= 0 orelse Enough(Read) of
        true -> Read;
        false -> read(Server, Enough, Tries - 1, Read)
    end.

limits(Read) ->
    length([Sql || {query, ~"SHOW max_connections" = Sql} <- Read]).

resets(Read) ->
    length([Sql || {query, <<"CLOSE ALL; ", _/binary>> = Sql} <- Read]).

failures(Fun) ->
    [Warning || #{event := connect_failed} = Warning <- warnings(Fun)].

%% What this pool warned of while `Fun` ran.
warnings(Fun) ->
    Handler = minato_pool_limit_tests_capture,
    ok = logger:add_handler(Handler, ?MODULE, #{config => self()}),
    try
        _ = Fun(),
        heard()
    after
        logger:remove_handler(Handler)
    end.

log(#{level := warning, msg := {report, #{pool := ?POOL} = Report}}, #{config := Test}) ->
    Test ! {warned, Report};
log(_Event, _Config) ->
    ok.

heard() ->
    receive
        {warned, Report} -> [Report | heard()]
    after 100 -> []
    end.
