-module(minato_traces_SUITE).
-moduledoc """
The OpenTelemetry bridge the observability guide shows, run for real.

`m:minato_traces` is the module in the guide, and `m:minato_traces_tests`
holds the guide to it. Here it is attached to the OpenTelemetry SDK with an
exporter that sends every finished span to the test, and the spans are read:
what they are called, what they hang under, what they say about the server,
and what of the caller's they do not say.

Every case runs inside a span of its own, as a request handler would, and
reads the spans of that trace only.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry_api/include/otel_tracer.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    a_statement_is_a_client_span_under_the_callers/1,
    a_statement_span_says_where_it_went/1,
    a_checkout_is_a_span_of_its_own/1,
    a_refused_statement_is_an_error_with_its_sqlstate/1,
    a_raise_is_an_error_named_for_its_kind/1,
    a_connect_is_a_client_span/1,
    nothing_the_caller_passed_is_in_a_span/1,
    the_statement_is_in_a_span_only_when_asked_for/1
]).

-define(TIMEOUT, 10000).
-define(POOL, minato_traces_pool).

-spec all() -> [atom()].
all() ->
    [
        a_statement_is_a_client_span_under_the_callers,
        a_statement_span_says_where_it_went,
        a_checkout_is_a_span_of_its_own,
        a_refused_statement_is_an_error_with_its_sqlstate,
        a_raise_is_an_error_named_for_its_kind,
        a_connect_is_a_client_span,
        nothing_the_caller_passed_is_in_a_span,
        the_statement_is_in_a_span_only_when_asked_for
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(connection()) of
        {ok, Conn} ->
            ok = minato_conn:close(Conn),
            _ = application:load(opentelemetry),
            ok = application:set_env(opentelemetry, processors, [{otel_simple_processor, #{}}]),
            {ok, _Otel} = application:ensure_all_started(opentelemetry),
            {ok, _Bridge} = application:ensure_all_started(opentelemetry_telemetry),
            {ok, _Started} = application:ensure_all_started(minato),
            ok = minato_traces:attach(),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok = minato_traces:detach(),
    ok = application:stop(minato),
    ok = application:stop(opentelemetry).

-spec init_per_testcase(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_testcase(_Case, Config) ->
    {ok, _Pid} = minato:start_pool(?POOL, #{size => 1, min_size => 1, connection => connection()}),
    ok = minato:health(?POOL, ?TIMEOUT),
    ok = otel_simple_processor:set_exporter(otel_exporter_pid, self()),
    Config.

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(_Case, _Config) ->
    _ = application:unset_env(minato, log_statements),
    ok = minato:stop_pool(?POOL).

%%----------------------------------------------------------------------
%% Cases
%%----------------------------------------------------------------------

-spec a_statement_is_a_client_span_under_the_callers([{atom(), term()}]) -> ok.
a_statement_is_a_client_span_under_the_callers(_Config) ->
    {Request, Spans} = traced(fun() ->
        {ok, #{rows := [{7}]}} = minato:query(?POOL, ~"SELECT $1::int4", [7])
    end),
    Statement = named(~"SELECT minato_test", Spans),
    ?assertEqual(?SPAN_KIND_CLIENT, Statement#span.kind),
    ?assertEqual(Request#span.span_id, Statement#span.parent_span_id),
    ?assertEqual(Request#span.trace_id, Statement#span.trace_id),
    ?assertEqual(undefined, Statement#span.status).

-spec a_statement_span_says_where_it_went([{atom(), term()}]) -> ok.
a_statement_span_says_where_it_went(_Config) ->
    {_Request, Spans} = traced(fun() ->
        {ok, _Result} = minato:query(?POOL, ~"SELECT $1::int4", [7])
    end),
    #{host := Host, port := Port, database := Database} = connection(),
    ?assertEqual(
        #{
            'db.system.name' => ~"postgresql",
            'db.namespace' => Database,
            'db.operation.name' => ~"SELECT",
            'db.client.connection.pool.name' => ?POOL,
            'server.address' => list_to_binary(Host),
            'server.port' => Port
        },
        attributes(named(~"SELECT minato_test", Spans))
    ).

-spec a_checkout_is_a_span_of_its_own([{atom(), term()}]) -> ok.
a_checkout_is_a_span_of_its_own(_Config) ->
    {Request, Spans} = traced(fun() ->
        {ok, _Result} = minato:query(?POOL, ~"SELECT $1::int4", [7])
    end),
    Checkout = named(~"minato checkout", Spans),
    Statement = named(~"SELECT minato_test", Spans),
    ?assertEqual(?SPAN_KIND_INTERNAL, Checkout#span.kind),
    ?assertEqual(Request#span.span_id, Checkout#span.parent_span_id),
    ?assertMatch(#{'db.client.connection.pool.name' := ?POOL}, attributes(Checkout)),
    ?assert(Checkout#span.end_time =< Statement#span.start_time).

-spec a_refused_statement_is_an_error_with_its_sqlstate([{atom(), term()}]) -> ok.
a_refused_statement_is_an_error_with_its_sqlstate(_Config) ->
    {_Request, Spans} = traced(fun() ->
        {error, {pgsql_error, #{code := ~"22012"}}} =
            minato:query(?POOL, ~"SELECT 1 / $1::int4", [0])
    end),
    Statement = named(~"minato_test", Spans),
    ?assertMatch(#status{code = ?OTEL_STATUS_ERROR}, Statement#span.status),
    ?assertMatch(
        #{'db.response.status_code' := ~"22012", 'error.type' := ~"22012"},
        attributes(Statement)
    ).

-spec a_raise_is_an_error_named_for_its_kind([{atom(), term()}]) -> ok.
a_raise_is_an_error_named_for_its_kind(_Config) ->
    {_Request, Spans} = traced(fun() ->
        ?assertError(
            {minato_codec, _Report}, minato:query(?POOL, ~"SELECT $1::int4", [~"seven"])
        )
    end),
    Statement = named(~"minato_test", Spans),
    ?assertMatch(#status{code = ?OTEL_STATUS_ERROR}, Statement#span.status),
    ?assertMatch(#{'error.type' := minato_codec}, attributes(Statement)).

-spec a_connect_is_a_client_span([{atom(), term()}]) -> ok.
a_connect_is_a_client_span(_Config) ->
    {Request, Spans} = traced(fun() ->
        {ok, Conn} = minato_conn:connect(connection()),
        ok = minato_conn:close(Conn)
    end),
    Connect = named(~"minato connect", Spans),
    #{port := Port, database := Database} = connection(),
    ?assertEqual(?SPAN_KIND_CLIENT, Connect#span.kind),
    ?assertEqual(Request#span.span_id, Connect#span.parent_span_id),
    ?assertMatch(
        #{
            'db.system.name' := ~"postgresql",
            'db.namespace' := Database,
            'server.address' := _Host,
            'server.port' := Port
        },
        attributes(Connect)
    ).

-spec nothing_the_caller_passed_is_in_a_span([{atom(), term()}]) -> ok.
nothing_the_caller_passed_is_in_a_span(_Config) ->
    Needle = ~"a-value-nobody-else-wrote",
    {_Request, Spans} = traced(fun() ->
        {ok, #{rows := [{Needle}]}} = minato:query(?POOL, ~"SELECT $1::text", [Needle]),
        {error, {pgsql_error, #{code := ~"22P02", message := Quoted}}} =
            minato:query(?POOL, ~"SELECT $1::text::int4", [Needle]),
        ?assertNotEqual(nomatch, binary:match(Quoted, Needle)),
        ?assertError({minato_codec, _Report}, minato:query(?POOL, ~"SELECT $1::int4", [Needle]))
    end),
    ?assertEqual(6, length(Spans)),
    Written = unicode:characters_to_binary(io_lib:format("~0tp", [Spans])),
    ?assertEqual(nomatch, binary:match(Written, Needle)).

-spec the_statement_is_in_a_span_only_when_asked_for([{atom(), term()}]) -> ok.
the_statement_is_in_a_span_only_when_asked_for(_Config) ->
    Sql = ~"SELECT $1::int4 AS asked",
    {_Quiet, Without} = traced(fun() -> {ok, _Result} = minato:query(?POOL, Sql, [1]) end),
    ok = application:set_env(minato, log_statements, true),
    {_Loud, With} = traced(fun() -> {ok, _Result} = minato:query(?POOL, Sql, [1]) end),
    ?assertNot(maps:is_key('db.query.text', attributes(named(~"SELECT minato_test", Without)))),
    ?assertMatch(#{'db.query.text' := Sql}, attributes(named(~"SELECT minato_test", With))).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

%% Spans are exported as they end, and the caller's ends last, so everything
%% that arrives before it and shares its trace is what the function made.
traced(Fun) ->
    _ = ?with_span(~"the caller's", #{}, fun(_Ctx) -> Fun() end),
    finished([]).

finished(Earlier) ->
    receive
        {span, #span{name = ~"the caller's", trace_id = Trace} = Request} ->
            {Request, [
                Span
             || #span{trace_id = Mine} = Span <- lists:reverse(Earlier), Mine =:= Trace
            ]};
        {span, Span} ->
            finished([Span | Earlier])
    after ?TIMEOUT ->
        error({the_callers_span_never_ended, Earlier})
    end.

named(Name, Spans) ->
    case [Span || #span{name = Found} = Span <- Spans, Found =:= Name] of
        [Span] -> Span;
        Other -> error({expected_one_span, Name, Other, [Span#span.name || Span <- Spans]})
    end.

attributes(#span{attributes = Attributes}) ->
    otel_attributes:map(Attributes).

connection() ->
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
