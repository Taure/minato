-module(minato_query).
-moduledoc """
Running SQL on a connection, in both of the protocol's two query paths.

`simple/2` is the simple query protocol: one message, any number of statements,
every value in the text format, and no parameters. `query/3` is the extended
protocol: `Parse`, `Describe`, `Bind`, `Execute`, `Sync`, with parameters sent
as parameters and results asked for in the binary format wherever minato has a
codec for the type.

Both take a connection and hand one back, because the connection carries the
bytes that have arrived but not been read. A result and a connection to carry on
from is the whole return value:

```erlang
{ok, #{rows := [{1}]}, Conn1} = minato_query:query(Conn, ~"SELECT $1::int", [1]).
```

## Which formats are asked for

`Describe` says what the parameter types are and what the result columns are,
and `minato_codec:preferred_format/1` turns each of those OIDs into `binary` for
a type minato has a codec for and `text` for one it does not. A column of an
extension type therefore still arrives, as its text representation, rather than
failing the query.

`RowDescription` from a `Describe` reports every column as text, because the
formats are not chosen until `Bind`. minato replaces those with what it asked
for before decoding, since believing the description would decode binary bytes
as text on the first integer column.

## Errors leave the connection usable

A statement that fails is a normal outcome. `{error, {pgsql_error, Fields},
Conn}` hands the connection back because the extended protocol says a failed
statement is discarded until `Sync`, and this module reads on to
`ReadyForQuery` before returning, so the connection really is ready.

A connection returned in the error tuple is usable. One that is not usable is
not returned: `{error, {socket, _}}` has no connection in it, because a socket
that failed mid-message leaves the stream at an unknown offset, and there is
nothing to hand back that could be trusted.

## What is not here

No transactions and no `LISTEN`. Both are session state rather than statements,
and both need the connection to be pinned to the caller for longer than one
query, so they belong with the pool that hands connections out.
""".

-export([
    simple/2,
    simple/3,
    query/3,
    query/4,
    cached/3,
    cached/4,
    prepare/3,
    execute/3,
    execute/4,
    close/2
]).

-include_lib("kernel/include/logger.hrl").

-define(UNNAMED, ~"").

-record(statement, {
    name :: binary(),
    parameters :: [minato_oid:oid()],
    fields :: [minato_protocol:field()],
    formats :: [minato_codec:format()]
}).

-doc """
A parsed statement on the server, with what it takes and what it returns.

Belongs to the connection it was prepared on: a name is only meaningful to the
session that parsed it, so a statement cannot be carried to another connection.
""".
-opaque statement() :: #statement{}.

-doc """
What went wrong.

Every failure here comes from the connection layer or from the server. A
parameter count that does not match raises instead of being returned, because it
is a bug in the caller rather than a condition to branch on.
""".
-type error() :: minato_conn:error().

-doc "The map carried by an `error({minato_query, Report})` exception.".
-type report() :: #{message := term(), reason := term(), data := term()}.

-export_type([statement/0, error/0, report/0]).

-type conn() :: minato_conn:conn().

-doc """
Decoding options, plus how long the statement may run.

```erlang
#{timeout => timeout(),
  return_rows_as_maps => boolean(),
  column_name_as_atom => boolean(),
  uuid_format => string | binary,
  datetime_format => datetime | microseconds,
  numeric_format => binary | float}
```

Everything but `timeout` is passed to `m:minato_protocol` unchanged. `timeout`
becomes a deadline on the statement: when it expires the statement is cancelled
on the server rather than abandoned, and comes back as `57014` with the
connection still usable. It defaults to the connection's own read timeout, so a
statement that outlives that costs a statement rather than a connection. See
`minato_conn:deadline/2`.
""".
-type opts() :: #{
    timeout => timeout(),
    return_rows_as_maps => boolean(),
    column_name_as_atom => boolean(),
    uuid_format => string | binary,
    datetime_format => datetime | microseconds,
    numeric_format => binary | float
}.

-export_type([opts/0]).
-type result() :: minato_protocol:result().

-doc "`simple/3` with the default decoding options.".
-spec simple(conn(), iodata()) ->
    {ok, [result()], conn()} | {error, error(), conn()} | {error, error()}.
simple(Conn, Sql) ->
    simple(Conn, Sql, #{}).

-doc """
Run one or more statements through the simple query protocol.

Answers with one result per statement, in order, which is why this is the only
function here that returns a list. Every value comes back in the text format,
because the simple query protocol has nowhere to ask for anything else.

There are no parameters. A value pasted into the SQL is an injection waiting to
be found, so anything with a value in it belongs in `query/3`.
""".
-spec simple(conn(), iodata(), opts()) ->
    {ok, [result()], conn()} | {error, error(), conn()} | {error, error()}.
simple(Conn, Sql, Opts) ->
    Bounded = bounded(Conn, Opts),
    Decoding = decoding(Opts),
    observed(simple, Sql, fun() ->
        case minato_conn:send(Bounded, {query, Sql}) of
            ok -> collect(Bounded, Decoding, minato_protocol:decoder([], Decoding));
            {error, Reason} -> {error, Reason}
        end
    end).

-doc "`query/4` with the default decoding options.".
-spec query(conn(), iodata(), [term()]) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
query(Conn, Sql, Parameters) ->
    query(Conn, Sql, Parameters, #{}).

-doc """
Run one statement with parameters, through the extended protocol.

The statement is parsed unnamed, so it is replaced by the next one and nothing
accumulates on the server. A statement that will run again belongs in
`prepare/3`, which parses it once and keeps it.

Two round trips: `Parse` and `Describe` have to be answered before the
parameters can be encoded, because their types are the server's to decide.
That is the price of not guessing them, and `prepare/3` pays it once.
""".
-spec query(conn(), iodata(), [term()], opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
query(Conn, Sql, Parameters, Opts) ->
    Bounded = bounded(Conn, Opts),
    Decoding = decoding(Opts),
    observed(unnamed, Sql, fun() ->
        case describe(Bounded, ?UNNAMED, Sql) of
            {ok, Statement, Described} -> run(Described, Statement, Parameters, Decoding);
            Failed -> Failed
        end
    end).

-doc "`cached/4` with the default decoding options.".
-spec cached(conn(), iodata(), [term()]) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
cached(Conn, Sql, Parameters) ->
    cached(Conn, Sql, Parameters, #{}).

-doc """
Run a statement, parsing it once per connection and keeping it.

The same SQL on the same connection costs one round trip after the first, which
is what `query/3` cannot do: it parses unnamed every time, because it has
nowhere to keep anything. A pooled caller gets a different connection each time
and would pay the parse on each of them; a connection that keeps its statements
pays it once per connection instead.

The cache is the connection's, bounded by `prepared_statements` in
`t:minato_conn:opts/0`, and a connection that is full runs anything new unnamed.
A workload with unbounded distinct SQL therefore gets the uncached path rather
than an unbounded pile of parsed statements in the backend.

## A cached plan the server stops accepting

Changing a table under a prepared statement makes PostgreSQL refuse it with
`0A000`, because the result type it was planned for is not the one it would
return now. That is not an error the caller can do anything with, so it is not
returned: the statement is dropped from the cache, parsed again, and run once
more. A second `0A000` is a real failure and is returned.
""".
-spec cached(conn(), iodata(), [term()], opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
cached(Conn, Sql, Parameters, Opts) ->
    Key = iolist_to_binary(Sql),
    Bounded = bounded(Conn, Opts),
    Decoding = decoding(Opts),
    observed(cached, Key, fun() ->
        case minato_conn:recall(Bounded, Key) of
            undefined -> parsed(Bounded, Key, Parameters, Decoding);
            Statement -> reused(Bounded, Key, Statement, Parameters, Decoding)
        end
    end).

-spec parsed(conn(), binary(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
parsed(Conn, Sql, Parameters, Opts) ->
    case minato_conn:claim(Conn) of
        {undefined, Full} -> query(Full, Sql, Parameters, Opts);
        {Name, Claimed} -> prepared(Claimed, Name, Sql, Parameters, Opts)
    end.

-spec prepared(conn(), binary(), binary(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
prepared(Conn, Name, Sql, Parameters, Opts) ->
    case prepare(Conn, Name, Sql) of
        {ok, Statement, Ready} ->
            run(minato_conn:remember(Ready, Sql, Statement), Statement, Parameters, Opts);
        Failed ->
            Failed
    end.

-spec reused(conn(), binary(), statement(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
reused(Conn, Sql, Statement, Parameters, Opts) ->
    case run(Conn, Statement, Parameters, Opts) of
        {error, {pgsql_error, #{code := ~"0A000"}}, Stale} ->
            replanned(Stale, Sql, Statement, Parameters, Opts);
        Answer ->
            Answer
    end.

-spec replanned(conn(), binary(), statement(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
replanned(Conn, Sql, Statement, Parameters, Opts) ->
    ?LOG_INFO(
        #{event => cached_plan_invalidated, sql => statement_for_log(Sql)},
        #{domain => [minato]}
    ),
    Forgotten = minato_conn:forget(Conn, Sql),
    case close(Forgotten, Statement) of
        {ok, Closed} -> parsed(Closed, Sql, Parameters, Opts);
        {error, Reason} -> {error, Reason}
    end.

-doc """
Parse a statement under a name and keep it for the life of the connection.

The describe round trip happens here rather than on every `execute/3`, which is
the point: a statement run in a loop costs one round trip a time.

The name is the caller's. Reusing one replaces what it named, and `close/2`
gives it back.
""".
-spec prepare(conn(), binary(), iodata()) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
prepare(Conn, Name, Sql) ->
    case describe(Conn, Name, Sql) of
        {ok, Statement, Described} -> ready(Described, Statement);
        Failed -> Failed
    end.

-doc "`execute/4` with the default decoding options.".
-spec execute(conn(), statement(), [term()]) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
execute(Conn, Statement, Parameters) ->
    execute(Conn, Statement, Parameters, #{}).

-doc """
Run a prepared statement.

Raises `error({minato_query, t:report/0})` when the number of parameters does
not match what the statement was described as taking. That is a bug in the
caller rather than a condition to branch on: the server would refuse it too, a
round trip later and with a worse message.

The connection is put back to ready before the exception is raised, with a
`Sync` and a read to `ReadyForQuery`. Raising in the middle of an extended query
cycle would otherwise leave a connection that is only good for closing, which is
a heavy price for what is usually a typo.
""".
-spec execute(conn(), statement(), [term()], opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
execute(Conn, Statement, Parameters, Opts) ->
    Bounded = bounded(Conn, Opts),
    Decoding = decoding(Opts),
    observed(prepared, name(Statement), fun() ->
        run(Bounded, Statement, Parameters, Decoding)
    end).

-spec name(statement()) -> binary().
name(#statement{name = Name}) ->
    Name.

-spec bounded(conn(), opts()) -> conn().
bounded(Conn, Opts) ->
    minato_conn:deadline(Conn, maps:get(timeout, Opts, minato_conn:timeout(Conn))).

-spec decoding(opts()) -> minato_protocol:opts().
decoding(Opts) ->
    #{
        return_rows_as_maps => maps:get(return_rows_as_maps, Opts, false),
        column_name_as_atom => maps:get(column_name_as_atom, Opts, false),
        uuid_format => maps:get(uuid_format, Opts, string),
        datetime_format => maps:get(datetime_format, Opts, datetime),
        numeric_format => maps:get(numeric_format, Opts, binary)
    }.

-doc """
Close a prepared statement and free what the server holds for it.

A connection that is handed back to a pool with a hundred one-off named
statements on it is a connection leaking server memory for the rest of its life.
""".
-spec close(conn(), statement()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
close(Conn, #statement{name = Name}) ->
    case minato_conn:send(Conn, [{close, statement, Name}, sync]) of
        ok -> closed(Conn);
        {error, Reason} -> {error, Reason}
    end.

%%----------------------------------------------------------------------
%% Instrumentation
%%----------------------------------------------------------------------

-spec observed(atom(), iodata(), fun(() -> Answer)) -> Answer.
observed(Path, Sql, Fun) ->
    Metadata = maps:merge(#{path => Path}, minato_telemetry:statements(Sql)),
    minato_telemetry:span([minato, query], Metadata, fun() -> reported(cleared(Fun())) end).

-spec cleared(dynamic()) -> dynamic().
cleared({ok, Answer, Conn}) -> {ok, Answer, minato_conn:deadline(Conn, infinity)};
cleared({error, Reason, Conn}) -> {error, Reason, minato_conn:deadline(Conn, infinity)};
cleared(Answer) -> Answer.

-spec reported(dynamic()) -> {dynamic(), minato_telemetry:metadata()}.
reported({ok, #{command := Command, num_rows := Rows}, _Conn} = Answer) ->
    {Answer, #{outcome => ok, command => Command, num_rows => Rows}};
reported({ok, Results, _Conn} = Answer) when is_list(Results) ->
    {Answer, #{outcome => ok, statements => length(Results)}};
reported({error, Reason, _Conn} = Answer) ->
    {Answer, #{outcome => error, reason => Reason}};
reported({error, Reason} = Answer) ->
    {Answer, #{outcome => error, reason => Reason}}.

%%----------------------------------------------------------------------
%% The extended protocol
%%----------------------------------------------------------------------

-spec describe(conn(), binary(), iodata()) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
describe(Conn, Name, Sql) ->
    Messages = [{parse, Name, Sql, []}, {describe, statement, Name}, flush],
    case minato_conn:send(Conn, Messages) of
        ok -> described(Conn, Name, undefined, undefined);
        {error, Reason} -> {error, Reason}
    end.

-spec described(
    conn(), binary(), [minato_oid:oid()] | undefined, [minato_protocol:field()] | undefined
) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
described(Conn, Name, Parameters, Fields) ->
    case minato_conn:next(Conn) of
        {ok, parse_complete, Read} ->
            described(Read, Name, Parameters, Fields);
        {ok, {parameter_description, Oids}, Read} ->
            described(Read, Name, Oids, Fields);
        {ok, {row_description, Described}, Read} ->
            {ok, statement(Name, Parameters, Described), Read};
        {ok, no_data, Read} ->
            {ok, statement(Name, Parameters, []), Read};
        {ok, {notice_response, _Fields}, Read} ->
            described(Read, Name, Parameters, Fields);
        {ok, {error_response, Reported}, Read} ->
            abort(Read, {pgsql_error, Reported});
        {ok, Message, _Read} ->
            unexpected(Message, describe);
        {error, Reason} ->
            {error, Reason}
    end.

-spec statement(binary(), [minato_oid:oid()] | undefined, [minato_protocol:field()]) ->
    statement().
statement(Name, Parameters, Fields) ->
    #statement{
        name = Name,
        parameters = parameters(Parameters),
        fields = [Field#{format => format(Field)} || Field <- Fields],
        formats = [format(Field) || Field <- Fields]
    }.

-spec format(minato_protocol:field()) -> minato_codec:format().
format(#{type_oid := Oid}) ->
    minato_codec:preferred_format(Oid).

-spec parameters([minato_oid:oid()] | undefined) -> [minato_oid:oid()].
parameters(undefined) -> [];
parameters(Oids) -> Oids.

-spec ready(conn(), statement()) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
ready(Conn, Statement) ->
    case minato_conn:send(Conn, sync) of
        ok -> prepared(Conn, Statement);
        {error, Reason} -> {error, Reason}
    end.

-spec prepared(conn(), statement()) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
prepared(Conn, Statement) ->
    case drain(Conn) of
        {ok, Drained} -> {ok, Statement, Drained};
        {error, Reason} -> {error, Reason}
    end.

-spec closed(conn()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
closed(Conn) ->
    drain(Conn).

-spec run(conn(), statement(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
run(Conn, #statement{} = Statement, Parameters, Opts) ->
    #statement{name = Name, parameters = Oids, formats = Formats, fields = Fields} = Statement,
    Encoded = encode(Conn, Oids, Parameters, Opts),
    Bind =
        {bind, ?UNNAMED, Name, [minato_codec:preferred_format(Oid) || Oid <- Oids], Encoded,
            Formats},
    case minato_conn:send(Conn, [Bind, {execute, ?UNNAMED, 0}, sync]) of
        ok -> executed(Conn, minato_protocol:decoder(Fields, Opts), Opts);
        {error, Reason} -> {error, Reason}
    end.

-spec encode(conn(), [minato_oid:oid()], [term()], minato_protocol:opts()) -> [iodata() | null].
encode(_Conn, Oids, Parameters, Opts) when length(Oids) =:= length(Parameters) ->
    encoded(Oids, Parameters, codec_opts(Opts));
encode(Conn, Oids, Parameters, _Opts) ->
    ok = resync(Conn),
    bad(bind, parameter_count_mismatch, {length(Oids), length(Parameters)}).

-spec encoded([minato_oid:oid()], [term()], minato_codec:opts()) -> [iodata() | null].
encoded([], [], _Opts) ->
    [];
encoded([Oid | Oids], [Value | Values], Opts) ->
    Encoded = minato_codec:encode(Oid, Value, minato_codec:preferred_format(Oid), Opts),
    [Encoded | encoded(Oids, Values, Opts)].

-spec codec_opts(minato_protocol:opts()) -> minato_codec:opts().
codec_opts(Opts) ->
    maps:with([uuid_format, datetime_format, numeric_format], Opts).

-spec executed(conn(), minato_protocol:decoder(), minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
executed(Conn, Decoder, Opts) ->
    case minato_conn:next(Conn) of
        {ok, {data_row, Columns}, Read} ->
            keep(minato_protocol:decode_row(Decoder, Columns), executed(Read, Decoder, Opts));
        {ok, {command_complete, Complete}, Read} ->
            stamp(Complete, executed(Read, Decoder, Opts));
        {ok, empty_query_response, Read} ->
            stamp({empty, undefined}, executed(Read, Decoder, Opts));
        {ok, {ready_for_query, _Status}, Read} ->
            {ok, minato_protocol:result({unknown, undefined}, []), Read};
        {ok, {error_response, Reported}, Read} ->
            failed(Read, {pgsql_error, Reported});
        {ok, Message, _Read} when
            Message =:= parse_complete;
            Message =:= no_data;
            element(1, Message) =:= parameter_description
        ->
            unexpected(Message, execute);
        {ok, _Message, Read} ->
            executed(Read, Decoder, Opts);
        {error, Reason} ->
            {error, Reason}
    end.

-spec keep(minato_protocol:row(), Answer) -> Answer when
    Answer :: {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
keep(Row, {ok, #{rows := Rows} = Result, Conn}) ->
    {ok, Result#{rows := [Row | Rows]}, Conn};
keep(_Row, Failed) ->
    Failed.

-spec stamp(minato_protocol:tag(), Answer) -> Answer when
    Answer :: {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
stamp({Command, NumRows}, {ok, Result, Conn}) ->
    {ok, Result#{command := Command, num_rows := NumRows}, Conn};
stamp(_Complete, Failed) ->
    Failed.

%%----------------------------------------------------------------------
%% The simple protocol
%%----------------------------------------------------------------------

-spec collect(conn(), minato_protocol:opts(), minato_protocol:decoder()) ->
    {ok, [result()], conn()} | {error, error(), conn()} | {error, error()}.
collect(Conn, Opts, Decoder) ->
    case minato_conn:next(Conn) of
        {ok, {row_description, Described}, Read} ->
            collect(Read, Opts, minato_protocol:decoder(Described, Opts));
        {ok, {data_row, Columns}, Read} ->
            first(minato_protocol:decode_row(Decoder, Columns), collect(Read, Opts, Decoder));
        {ok, {command_complete, Complete}, Read} ->
            began(Complete, collect(Read, Opts, Decoder));
        {ok, empty_query_response, Read} ->
            began({empty, undefined}, collect(Read, Opts, Decoder));
        {ok, {ready_for_query, _Status}, Read} ->
            {ok, [], Read};
        {ok, {error_response, Reported}, Read} ->
            refused({pgsql_error, Reported}, collect(Read, Opts, Decoder));
        {ok, _Message, Read} ->
            collect(Read, Opts, Decoder);
        {error, Reason} ->
            {error, Reason}
    end.

-spec first(minato_protocol:row(), Answer) -> Answer when
    Answer :: {ok, [result()], conn()} | {error, error(), conn()} | {error, error()}.
first(Row, {ok, [#{rows := Rows} = Result | Results], Conn}) ->
    {ok, [Result#{rows := [Row | Rows]} | Results], Conn};
first(_Row, Answer) ->
    Answer.

-spec began(minato_protocol:tag(), Answer) -> Answer when
    Answer :: {ok, [result()], conn()} | {error, error(), conn()} | {error, error()}.
began(Complete, {ok, Results, Conn}) ->
    {ok, [minato_protocol:result(Complete, []) | Results], Conn};
began(_Complete, Failed) ->
    Failed.

-spec refused(error(), {ok, [result()], conn()} | {error, error(), conn()} | {error, error()}) ->
    {error, error(), conn()} | {error, error()}.
refused(Reason, {ok, _Results, Conn}) ->
    {error, Reason, Conn};
refused(_Reason, Failed) ->
    Failed.

%%----------------------------------------------------------------------
%% Getting back to a ready connection
%%----------------------------------------------------------------------

-spec resync(conn()) -> ok.
resync(Conn) ->
    case minato_conn:send(Conn, sync) of
        ok ->
            _ = drain(Conn),
            ok;
        {error, _Reason} ->
            ok
    end.

-spec abort(conn(), error()) -> {error, error(), conn()} | {error, error()}.
abort(Conn, Reason) ->
    case minato_conn:send(Conn, sync) of
        ok -> failed(Conn, Reason);
        {error, Sending} -> {error, Sending}
    end.

-spec failed(conn(), error()) -> {error, error(), conn()} | {error, error()}.
failed(Conn, Reason) ->
    case drain(Conn) of
        {ok, Drained} -> {error, Reason, Drained};
        {error, Draining} -> {error, Draining}
    end.

-spec drain(conn()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
drain(Conn) ->
    case minato_conn:next(Conn) of
        {ok, {ready_for_query, _Status}, Read} -> {ok, Read};
        {ok, _Message, Read} -> drain(Read);
        {error, Reason} -> {error, Reason}
    end.

-spec unexpected(minato_protocol:backend(), atom()) -> no_return().
unexpected(Message, Stage) ->
    bad(Stage, unexpected_message, Message).

-spec statement_for_log(binary()) -> binary() | hidden.
statement_for_log(Sql) ->
    case minato_telemetry:statements() of
        true -> Sql;
        false -> hidden
    end.

-spec bad(term(), term(), term()) -> no_return().
bad(Message, Reason, Data) ->
    error({minato_query, #{message => Message, reason => Reason, data => Data}}).
