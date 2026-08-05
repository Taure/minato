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

`sql` is present when `minato` was configured with `log_statements => true`,
and absent otherwise. A statement is not a secret but it is close to one:
`SELECT * FROM users WHERE email = $1` in a log is fine, and the same statement
written by a caller that pasted the value in is a leak. Parameters are never in
an event, in any configuration, for the same reason - they are the values
themselves.

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
