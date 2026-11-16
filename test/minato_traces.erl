-module(minato_traces).
-moduledoc """
minato's `telemetry` spans as OpenTelemetry spans.

`attach/0` once, after `opentelemetry` has started. A statement, the checkout
it waited on and the connect behind a new connection each become a span, named
and described as the OpenTelemetry conventions for a database client ask. A
statement and its checkout run in the caller's process, so they are children
of whatever span the caller has open.

Needs `opentelemetry_api` and `opentelemetry_telemetry`.
""".

-export([attach/0, detach/0, handle/4]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(HANDLER, ~"minato-traces").
-define(ATTRIBUTES, [
    {database, 'db.namespace'},
    {port, 'server.port'},
    {pool, 'db.client.connection.pool.name'},
    {sql, 'db.query.text'}
]).

-spec attach() -> ok | {error, already_exists}.
attach() ->
    telemetry:attach_many(
        ?HANDLER,
        [
            [minato, Span, Stage]
         || Span <- [connect, query, checkout], Stage <- [start, stop, exception]
        ],
        fun ?MODULE:handle/4,
        undefined
    ).

-spec detach() -> ok | {error, not_found}.
detach() ->
    telemetry:detach(?HANDLER).

-spec handle([atom()], map(), map(), term()) -> ok.
handle([minato, Span, start], _Measurements, Metadata, _Config) ->
    _ = otel_telemetry:start_telemetry_span(?MODULE, name(Span, Metadata), Metadata, #{
        kind => kind(Span), attributes => attributes(Metadata)
    }),
    ok;
handle([minato, _Span, _Ended], _Measurements, Metadata, _Config) ->
    Ctx = otel_telemetry:set_current_telemetry_span(?MODULE, Metadata),
    _ = ended(Ctx, Metadata),
    otel_telemetry:end_telemetry_span(?MODULE, Metadata).

%% The statement is not known to be a SELECT until it has been answered, so a
%% query span starts under the name of its database and is renamed here.
ended(Ctx, #{outcome := ok, command := Command, database := Database}) ->
    Operation = iolist_to_binary(string:uppercase(operation(Command))),
    _ = otel_span:update_name(Ctx, <<Operation/binary, " ", Database/binary>>),
    otel_span:set_attributes(Ctx, #{'db.operation.name' => Operation});
ended(Ctx, #{reason := Reason}) ->
    _ = otel_span:set_attributes(Ctx, failure(Reason)),
    otel_span:set_status(Ctx, ?OTEL_STATUS_ERROR);
ended(_Ctx, _Metadata) ->
    true.

name(query, #{database := Database}) -> Database;
name(connect, _Metadata) -> ~"minato connect";
name(checkout, _Metadata) -> ~"minato checkout".

kind(checkout) -> ?SPAN_KIND_INTERNAL;
kind(_Span) -> ?SPAN_KIND_CLIENT.

attributes(Metadata) ->
    Named =
        #{Name => Value || {Key, Name} <- ?ATTRIBUTES, {ok, Value} <- [maps:find(Key, Metadata)]},
    addressed(Named#{'db.system.name' => ~"postgresql"}, Metadata).

addressed(Attributes, #{host := {local, _Path}}) ->
    Attributes;
addressed(Attributes, #{host := Host}) when is_tuple(Host) ->
    case inet:ntoa(Host) of
        {error, einval} -> Attributes;
        Address -> Attributes#{'server.address' => list_to_binary(Address)}
    end;
addressed(Attributes, #{host := Host}) when is_atom(Host) ->
    Attributes#{'server.address' => atom_to_binary(Host)};
addressed(Attributes, #{host := Host}) ->
    Attributes#{'server.address' => unicode:characters_to_binary(Host)};
addressed(Attributes, _Metadata) ->
    Attributes.

operation(Command) when is_atom(Command) -> atom_to_binary(Command);
operation(Command) when is_binary(Command) -> Command.

%% A server's refusal is known by its SQLSTATE. Anything else is known by what
%% kind of thing it is, never by its text, which can quote a value.
failure({pgsql_error, #{code := Code}}) ->
    #{'db.response.status_code' => Code, 'error.type' => Code};
failure({Kind, _Detail}) when is_atom(Kind) ->
    #{'error.type' => Kind};
failure(Reason) when is_atom(Reason) ->
    #{'error.type' => Reason};
failure(_Reason) ->
    #{'error.type' => '_OTHER'}.
