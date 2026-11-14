-module(minato_telemetry).
-moduledoc """
Every event minato emits, in one module.

Instrumentation belongs in one place for the same reason the protocol codec
does: the event names, the measurements and the metadata keys are a contract
with whoever is collecting them, and a contract spread across eight call sites
drifts. Everything here is `m:telemetry`, which is what an OpenTelemetry bridge,
a Prometheus exporter and a `logger` handler all already know how to read.

## The events

Spans follow the `telemetry:span/3` shape, so each is three events - `start`,
`stop`, and `exception` when the work raised - and `stop` carries a `duration`
in native units.

| event | when |
| --- | --- |
| `[minato, connect, start\\|stop\\|exception]` | opening a connection, including TLS and authentication |
| `[minato, query, start\\|stop\\|exception]` | one statement, whichever query path ran it |
| `[minato, checkout, start\\|stop\\|exception]` | borrowing a connection, so `duration` is the time spent waiting for one |
| `[minato, connection, opened]` | a pool connection became available |
| `[minato, connection, closed]` | a pool connection was closed, with why |
| `[minato, notification, received]` | `LISTEN` delivered something |
| `[minato, listener, reconnected]` | a listener lost its connection and resubscribed, so notifications were missed |

## What is in the metadata, and what is never

A query event says where it went: `host`, `port` and `database` as the
connection was asked to reach them, `pool` when a pool holds the connection,
and `path` for which query path ran it. They are on `start`, `stop` and
`exception` alike, so a handler that only reads `stop` can still label a
duration by database and pool.

`sql` is present when `minato` was configured with `log_statements => true`,
and absent otherwise. A statement is not a secret but it is close to one:
`SELECT * FROM users WHERE email = $1` in a log is fine, and the same statement
written by a caller that pasted the value in is a leak. Parameters are never in
an event, in any configuration, for the same reason - they are the values
themselves.

The same holds for a value that arrives inside a failure. A server error keeps
the fields that name things - `code`, `severity`, `severity_non_localised`,
`constraint`, `schema`, `table`, `column`, `data_type`, `routine` - and loses
`message`, `detail`, `hint` and the rest, because those quote the row that
violated the constraint or the input that would not parse. A parameter that
would not encode is reported as its type and why, with `redacted` where the
value was, and a message that could not be read keeps its lengths and counts
and loses its bytes the same way.
The caller is still handed the whole server error as the return value; it is
the event that is narrowed.

`log_values => true` in the `minato` application environment puts all of it
back, for a development node or an incident. Like `log_statements` it is read
per call.

Passwords never reach this module at all. See `m:minato_conn` for where they
stop.

## Attaching

```erlang
telemetry:attach(<<"minato-slow">>, [minato, query, stop], fun
    (_Event, #{duration := Duration}, #{command := Command}, _Config) ->
        case erlang:convert_time_unit(Duration, native, millisecond) of
            Slow when Slow > 100 -> logger:warning(#{slow_query => Command, ms => Slow});
            _Fast -> ok
        end
end, undefined).
```
""".

-export([span/3, event/2, event/3, statements/0, statements/1]).
-export([values/0, reason/1, frames/1]).

-define(NAMING_FIELDS, [
    code,
    severity,
    severity_non_localised,
    constraint,
    schema,
    table,
    column,
    data_type,
    routine
]).

-doc "The metadata a caller attaches to an event: atoms to whatever they carry.".
-type metadata() :: #{atom() => term()}.

-doc "The measurements an event carries. Durations are in native time units.".
-type measurements() :: #{atom() => number()}.

-export_type([metadata/0, measurements/0]).

-doc """
Run a function as a span: `start`, then `stop` or `exception`.

The function answers `{Result, ExtraMetadata}`, and the extra metadata is merged
into the `stop` event, which is how a query reports the command it turned out to
be and how many rows it returned. The result is whatever the function returned,
which is why it is untyped here: this module carries answers without knowing
what they are.
""".
-spec span([atom()], metadata(), fun(() -> {dynamic(), metadata()})) -> dynamic().
span(Name, Metadata, Fun) ->
    telemetry:span(Name, Metadata, Fun).

-doc "`event/3` with no measurements beyond the time it happened.".
-spec event([atom()], metadata()) -> ok.
event(Name, Metadata) ->
    event(Name, #{}, Metadata).

-doc "Emit one event.".
-spec event([atom()], measurements(), metadata()) -> ok.
event(Name, Measurements, Metadata) ->
    telemetry:execute(Name, Measurements#{system_time => erlang:system_time()}, Metadata).

-doc """
Whether statements may be put in events and logs.

Off unless the `minato` application environment says `log_statements` is true.
Read once per call rather than cached, because an operator turning it on to
diagnose something at three in the morning should not have to restart anything.
""".
-spec statements() -> boolean().
statements() ->
    application:get_env(minato, log_statements, false) =:= true.

-doc "Add the statement to metadata, if statements may be logged at all.".
-spec statements(iodata()) -> metadata().
statements(Sql) ->
    case statements() of
        true -> #{sql => iolist_to_binary(Sql)};
        false -> #{}
    end.

-doc """
Whether a value may appear in an event or in a raised error.

Off unless the `minato` application environment says `log_values` is true, and
read per call for the reason `statements/0` is.
""".
-spec values() -> boolean().
values() ->
    application:get_env(minato, log_values, false) =:= true.

-doc """
A failure as an event may carry it: what went wrong, without the values.

```erlang
1> minato_telemetry:reason({pgsql_error, #{code => ~"23505", detail => ~"Key (email)=(a@b.se) already exists."}}).
{pgsql_error,#{code => <<"23505">>}}
```
""".
-spec reason(Reason) -> Reason when Reason :: term().
reason(Reason) ->
    case values() of
        true -> Reason;
        false -> narrowed(Reason)
    end.

-spec narrowed(dynamic()) -> dynamic().
narrowed({pgsql_error, Fields}) when is_map(Fields) ->
    {pgsql_error, maps:with(?NAMING_FIELDS, Fields)};
narrowed({minato_codec, #{value := _Value} = Report}) ->
    {minato_codec, Report#{value := redacted}};
narrowed({Module, #{data := Data} = Report} = Reason) when
    Module =:= minato_protocol; Module =:= minato_query
->
    case holds_no_bytes(Data) of
        true -> Reason;
        false -> {Module, Report#{data := redacted}}
    end;
narrowed(Reason) ->
    Reason.

%% A report's data is either what was counted, a length or a number of columns,
%% or what was read, and only the second can be somebody's row.
-spec holds_no_bytes(term()) -> boolean().
holds_no_bytes(Data) when is_integer(Data); is_atom(Data) -> true;
holds_no_bytes(Data) when is_tuple(Data) -> lists:all(fun holds_no_bytes/1, tuple_to_list(Data));
holds_no_bytes(_Bytes) -> false.

-doc """
A stacktrace as an event may carry it: where, without the arguments.

A frame holds the arguments of the call that failed when nothing matched them,
and on the query path those are the parameters.
""".
-spec frames([dynamic()]) -> [dynamic()].
frames(Stacktrace) ->
    case values() of
        true -> Stacktrace;
        false -> [frame(Frame) || Frame <- Stacktrace]
    end.

-spec frame(dynamic()) -> dynamic().
frame({Module, Function, Arguments, Location}) when is_list(Arguments) ->
    {Module, Function, length(Arguments), Location};
frame(Frame) ->
    Frame.
