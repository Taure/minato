-module(minato_telemetry_SUITE).
-moduledoc """
The events minato emits, which are a contract.

A metric that stops being emitted is a dashboard that goes flat and an alert
that never fires, and neither of those looks like a failure until somebody needs
them. Every event, every measurement key and every metadata key an operator
would build on is asserted here, so removing one breaks a test rather than a
production dashboard six months later.

The statement is the one field with a rule attached: it appears only when
`log_statements` is on, because a statement written by a caller who pasted a
value into it carries that value. The suite asserts both directions.

Skips when no server answers.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([collect/4]).
-export([
    a_query_is_a_span/1,
    a_failed_query_reports_why/1,
    a_connect_is_a_span/1,
    a_failed_connect_reports_why/1,
    a_checkout_measures_the_wait/1,
    an_opened_connection_is_announced/1,
    a_discarded_connection_is_announced/1,
    a_notification_is_counted/1,
    the_statement_is_absent_by_default/1,
    the_statement_is_present_when_asked_for/1,
    parameters_are_never_in_an_event/1
]).

-define(TIMEOUT, 15000).
-define(POOL, minato_telemetry_pool).

-spec all() -> [atom()].
all() ->
    [
        a_query_is_a_span,
        a_failed_query_reports_why,
        a_connect_is_a_span,
        a_failed_connect_reports_why,
        a_checkout_measures_the_wait,
        an_opened_connection_is_announced,
        a_discarded_connection_is_announced,
        a_notification_is_counted,
        the_statement_is_absent_by_default,
        the_statement_is_present_when_asked_for,
        parameters_are_never_in_an_event
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case minato_conn:connect(connection()) of
        {ok, Conn} ->
            ok = minato_conn:close(Conn),
            {ok, _Started} = application:ensure_all_started(minato),
            {ok, _Pid} = minato:start_pool(?POOL, #{size => 2, connection => connection()}),
            Config;
        {error, Reason} ->
            {skip, {no_server, Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    ok = application:stop(minato).

-spec init_per_testcase(atom(), [{atom(), term()}]) -> [{atom(), term()}].
init_per_testcase(Case, Config) ->
    ok = telemetry:attach_many(handler(Case), events(), fun ?MODULE:collect/4, self()),
    [{handler, handler(Case)} | Config].

-spec end_per_testcase(atom(), [{atom(), term()}]) -> ok.
end_per_testcase(Case, _Config) ->
    ok = application:unset_env(minato, log_statements),
    _ = telemetry:detach(handler(Case)),
    ok.

-spec a_query_is_a_span([{atom(), term()}]) -> ok.
a_query_is_a_span(_Config) ->
    {ok, _Result} = minato:query(?POOL, ~"SELECT $1::int4", [7]),
    {_Start, StartMeta} = awaited([minato, query, start], #{path => cached}),
    #{telemetry_span_context := Span} = StartMeta,
    {Stop, StopMeta} = awaited([minato, query, stop], #{telemetry_span_context => Span}),
    ?assertMatch(#{path := cached}, StartMeta),
    ?assertMatch(#{duration := _Duration, monotonic_time := _When}, Stop),
    ?assertMatch(#{outcome := ok, command := select, num_rows := 1}, StopMeta).

-spec a_failed_query_reports_why([{atom(), term()}]) -> ok.
a_failed_query_reports_why(_Config) ->
    {error, _Reason} = minato:query(?POOL, ~"SELECT * FROM no_such_table", []),
    {_Stop, StopMeta} = awaited([minato, query, stop]),
    ?assertMatch(#{outcome := error, reason := {pgsql_error, #{code := ~"42P01"}}}, StopMeta).

-spec a_connect_is_a_span([{atom(), term()}]) -> ok.
a_connect_is_a_span(_Config) ->
    {ok, Conn} = minato_conn:connect(connection()),
    ok = minato_conn:close(Conn),
    {_Start, StartMeta} = awaited([minato, connect, start]),
    {Stop, StopMeta} = awaited([minato, connect, stop]),
    ?assertMatch(#{database := ~"minato_test", user := ~"minato", ssl := false}, StartMeta),
    ?assertMatch(#{duration := _Duration}, Stop),
    ?assertMatch(#{outcome := ok}, StopMeta).

-spec a_failed_connect_reports_why([{atom(), term()}]) -> ok.
a_failed_connect_reports_why(_Config) ->
    {error, _Reason} = minato_conn:connect((connection())#{password => ~"wrong"}),
    {_Stop, StopMeta} = awaited([minato, connect, stop]),
    ?assertMatch(#{outcome := error, reason := {pgsql_error, #{code := ~"28P01"}}}, StopMeta).

-spec a_checkout_measures_the_wait([{atom(), term()}]) -> ok.
a_checkout_measures_the_wait(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    ok = minato_pool:checkin(?POOL, Conn),
    {_Start, StartMeta} = awaited([minato, checkout, start]),
    {Stop, StopMeta} = awaited([minato, checkout, stop]),
    ?assertMatch(#{pool := ?POOL}, StartMeta),
    ?assertMatch(#{duration := _Duration}, Stop),
    ?assertMatch(#{outcome := ok}, StopMeta).

-spec an_opened_connection_is_announced([{atom(), term()}]) -> ok.
an_opened_connection_is_announced(_Config) ->
    {ok, _Pid} = minato:start_pool(minato_telemetry_extra, #{
        size => 1, connection => connection()
    }),
    {_Measurements, Metadata} = awaited([minato, connection, opened]),
    ?assertMatch(#{pool := minato_telemetry_extra}, Metadata),
    ok = minato:stop_pool(minato_telemetry_extra).

-spec a_discarded_connection_is_announced([{atom(), term()}]) -> ok.
a_discarded_connection_is_announced(_Config) ->
    {ok, Conn} = minato_pool:checkout(?POOL),
    ok = minato_pool:discard(?POOL, Conn),
    {_Measurements, Metadata} = awaited([minato, connection, closed]),
    ?assertMatch(#{pool := ?POOL, reason := discarded}, Metadata).

-spec a_notification_is_counted([{atom(), term()}]) -> ok.
a_notification_is_counted(_Config) ->
    {ok, _Pid} = minato:start_listener(minato_telemetry_listener, #{connection => connection()}),
    ok = minato:listen(minato_telemetry_listener, ~"telemetry_events"),
    {ok, _Result} = minato:query(?POOL, ~"SELECT pg_notify($1, $2)", [
        ~"telemetry_events", ~"payload"
    ]),
    {Measurements, Metadata} = awaited([minato, notification, received]),
    ?assertMatch(#{subscribers := 1, bytes := 7}, Measurements),
    ?assertMatch(#{channel := ~"telemetry_events"}, Metadata),
    ok = minato:stop_listener(minato_telemetry_listener).

-spec the_statement_is_absent_by_default([{atom(), term()}]) -> ok.
the_statement_is_absent_by_default(_Config) ->
    {ok, _Result} = minato:query(?POOL, ~"SELECT $1::int4", [7]),
    {_Start, StartMeta} = awaited([minato, query, start]),
    ?assertNot(maps:is_key(sql, StartMeta)).

-spec the_statement_is_present_when_asked_for([{atom(), term()}]) -> ok.
the_statement_is_present_when_asked_for(_Config) ->
    ok = application:set_env(minato, log_statements, true),
    {ok, _Result} = minato:query(?POOL, ~"SELECT $1::int4", [7]),
    {_Start, StartMeta} = awaited([minato, query, start]),
    ?assertMatch(#{sql := ~"SELECT $1::int4"}, StartMeta).

-spec parameters_are_never_in_an_event([{atom(), term()}]) -> ok.
parameters_are_never_in_an_event(_Config) ->
    ok = application:set_env(minato, log_statements, true),
    Secret = ~"hunter2",
    {ok, _Result} = minato:query(?POOL, ~"SELECT $1::text", [Secret]),
    Events = drained(),
    ?assertEqual([], [
        Event
     || {_Name, _Measurements, Metadata} = Event <- Events,
        lists:member(Secret, maps:values(Metadata))
    ]),
    ?assert(length(Events) >= 2).

%%----------------------------------------------------------------------
%% Collecting events
%%----------------------------------------------------------------------

collect(Name, Measurements, Metadata, Test) ->
    Test ! {telemetry, Name, Measurements, Metadata},
    ok.

awaited(Name) ->
    receive
        {telemetry, Name, Measurements, Metadata} -> {Measurements, Metadata}
    after ?TIMEOUT -> error({never_emitted, Name})
    end.

%% A pool opens connections when it needs them rather than up front, and the
%% first connection of one asks the server how many it will allow. That is a
%% query, and it is a span, so waiting for "the next event" is waiting for
%% whichever query got there first. This waits for the one the test ran, which
%% for a stop event means the one carrying the start event's span context.
awaited(Name, Wanted) ->
    {Measurements, Metadata} = awaited(Name),
    case maps:with(maps:keys(Wanted), Metadata) of
        Wanted -> {Measurements, Metadata};
        _Somebody_elses -> awaited(Name, Wanted)
    end.

drained() ->
    receive
        {telemetry, Name, Measurements, Metadata} -> [{Name, Measurements, Metadata} | drained()]
    after 200 -> []
    end.

events() ->
    [
        [minato, query, start],
        [minato, query, stop],
        [minato, query, exception],
        [minato, connect, start],
        [minato, connect, stop],
        [minato, checkout, start],
        [minato, checkout, stop],
        [minato, connection, opened],
        [minato, connection, closed],
        [minato, notification, received],
        [minato, listener, reconnected]
    ].

handler(Case) ->
    atom_to_binary(Case).

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
