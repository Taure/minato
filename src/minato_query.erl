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

## A value that does not fit is the caller's, not the connection's

A parameter that will not encode, the wrong number of parameters, and a value
from the server that will not decode all raise, `error({minato_codec, _})` or
`error({minato_query, _})`, because there is no result to return. None of them
costs the connection. Before the raise the exchange is ended with `Sync`, an
answer that was being read is read to its `ReadyForQuery`, and a statement
`cached/4` parsed for the call is closed again, so the connection that was
passed in is the one to carry on with. It is closed only if it could not be
put back, and then says so on its next use.

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
-export([left_ready/1]).

-include_lib("kernel/include/logger.hrl").

-define(UNNAMED, ~"").

-define(DEFAULT_DECODING, #{
    return_rows_as_maps => false,
    column_name_as_atom => false,
    uuid_format => string,
    datetime_format => datetime,
    numeric_format => binary
}).

-define(DEFAULT_CODEC, #{
    uuid_format => string,
    datetime_format => datetime,
    numeric_format => binary
}).

-record(statement, {
    name :: binary(),
    parameters :: [minato_oid:oid()],
    parameter_formats :: [minato_codec:format()],
    fields :: [minato_protocol:field()],
    formats :: [minato_codec:format()],
    decoder :: minato_protocol:decoder()
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
    observed(Bounded, simple, Sql, fun() ->
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
    observed(Bounded, unnamed, Sql, fun() -> unnamed(Bounded, Sql, Parameters, Decoding) end).

-spec unnamed(conn(), iodata(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
unnamed(Conn, Sql, Parameters, Opts) ->
    case describe(Conn, ?UNNAMED, Sql) of
        {ok, Statement, Described} -> run(Described, Statement, Parameters, Opts);
        Failed -> Failed
    end.

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

## A kept statement the server stops accepting

A statement is kept with what the server made of it when it was parsed: its
plan, the types of its parameters and the columns of its result. Changing a
table under it can make any of those wrong, and that is not an error the
caller can do anything with. So where the server's answer says the statement
may have gone stale, it is dropped from the cache, parsed again and run once
more, and only what the second run answers is returned:

- `0A000`, the result is not the one the plan was made for;
- `26000`, the server no longer has the statement, because something on the
  session ran `DEALLOCATE` or a pooler handed the call to another backend;
- `08P01` from the bind, which is a pooler having parsed the statement afresh
  where it has another number of columns;
- an error of class `42` for a statement with parameters, or a value that will
  not encode as the type kept here, when asking the server again shows the
  parameter types have changed. If they have not, the error or the raise was
  about the call and is what the caller gets, at the cost of that one question.

Never twice, and never inside a transaction the error has aborted, where
parsing again could only fail: there the statement is dropped and closed, and
the server's error is returned as it came.

A value that will not encode is raised at once inside any transaction, open or
aborted, and nothing is sent: the question would be a `Parse` in the caller's
transaction, and a statement that no longer parses would abort it over what is
usually a mistake in the call. A statement that has gone stale there is found
by the server at the next bind.

Only a refusal that arrives before `BindComplete` counts, which is where the
server checks the plan and before anything has run. A statement that fails
once it is running has failed, whatever code it fails with: it is returned and
not run a second time, since what it did outside its transaction, a `nextval`
or a `dblink` call, would be done twice.

What this cannot see is a statement that still runs and now answers with
other types in the same number of columns, which happens behind a pooler that
prepares statements itself. See "PgBouncer and connection poolers" in the
configuration guide.
""".
-spec cached(conn(), iodata(), [term()], opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
cached(Conn, Sql, Parameters, Opts) ->
    Key = iolist_to_binary(Sql),
    Bounded = bounded(Conn, Opts),
    Decoding = decoding(Opts),
    observed(Bounded, cached, Key, fun() ->
        case minato_conn:recall(Bounded, Key) of
            undefined -> parsed(Bounded, Key, Parameters, Decoding);
            Statement -> reused(Bounded, Key, Statement, Parameters, Decoding)
        end
    end).

-spec parsed(conn(), binary(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
parsed(Conn, Sql, Parameters, Opts) ->
    case minato_conn:claim(Conn) of
        {undefined, Full} -> unnamed(Full, Sql, Parameters, Opts);
        {Name, Claimed} -> kept(Claimed, Name, Sql, Parameters, Opts)
    end.

%% `Parse` and `Describe` go out behind a `Flush` and `Bind` and `Execute`
%% behind the `Sync`, so the statement is parsed, kept and run in one exchange:
%% two round trips, and one backend even behind a pooler that would hand the
%% next exchange to another. The server keeps a statement it has parsed
%% whatever becomes of the rest of the exchange.
-spec kept(conn(), binary(), binary(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
kept(Conn, Name, Sql, Parameters, Opts) ->
    case describe(Conn, Name, Sql) of
        {ok, Statement, Described} ->
            try
                run(minato_conn:remember(Described, Sql, Statement), Statement, Parameters, Opts)
            catch
                error:Reason:Stacktrace ->
                    _ = left_ready(Reason) andalso close(Described, Statement),
                    reraise(error, Reason, Stacktrace)
            end;
        Failed ->
            Failed
    end.

-doc false.
%% The raises this module makes for a mistake in the call, each of them only
%% once the connection that was passed in is ready again and holds nothing it
%% did not hold before: an exchange left open has been ended with `Sync`, an
%% answer partly read has been read to its end, and a statement parsed for the
%% call has been closed. A null byte is found in the text of a statement or in
%% a name, which is the first thing a call writes, so nothing was. The caller
%% never sees the connection the call had got to, so the one it still has must
%% be good. One that could not be brought back that far has been closed
%% instead, and a pool it is returned to finds that out when it writes the
%% reset and counts it as lost.
-spec left_ready(term()) -> boolean().
left_ready({minato_codec, _Report}) -> true;
left_ready({minato_protocol, #{reason := null_byte}}) -> true;
left_ready({minato_query, #{reason := parameter_count_mismatch}}) -> true;
left_ready(_Reason) -> false.

%% What says a kept statement has gone stale, and why it is run again once and
%% no more, is in the documentation of `cached/4`.
-spec reused(conn(), binary(), statement(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
reused(Conn, Sql, Statement, Parameters, Opts) ->
    try encoded(Statement, Parameters, Opts) of
        Encoded ->
            case bound(Conn, Statement, Encoded, Opts) of
                {unbound, {pgsql_error, #{code := Code}} = Reason, Read} ->
                    Doubt = doubt(Code, Statement),
                    Status = minato_conn:transaction_status(Read),
                    refused(Doubt, Status, Read, Sql, Statement, Parameters, Opts, Reason);
                Answer ->
                    begun(Answer)
            end
    catch
        error:{minato_codec, _Report} = Reason:Stacktrace ->
            case minato_conn:transaction_status(Conn) of
                idle ->
                    Unchanged = {raise, Reason, Stacktrace},
                    described_again(Conn, Sql, Statement, Parameters, Opts, Unchanged);
                _InATransaction ->
                    reraise(error, Reason, Stacktrace)
            end
    end.

-spec doubt(binary(), statement()) -> none | replanned | deallocated | retyped.
doubt(~"0A000", _Statement) -> replanned;
doubt(~"08P01", _Statement) -> replanned;
doubt(~"26000", _Statement) -> deallocated;
doubt(_Code, #statement{parameters = []}) -> none;
doubt(<<"42", _Condition:3/binary>>, _Statement) -> retyped;
doubt(_Code, _Statement) -> none.

-spec refused(
    none | replanned | deallocated | retyped,
    minato_protocol:transaction_status(),
    conn(),
    binary(),
    statement(),
    [term()],
    minato_protocol:opts(),
    error()
) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
refused(none, _Status, Conn, _Sql, _Statement, _Parameters, _Opts, Reason) ->
    {error, Reason, Conn};
refused(replanned, idle, Conn, Sql, Statement, Parameters, Opts, _Reason) ->
    replanned(Conn, Sql, Statement, Parameters, Opts);
refused(retyped, idle, Conn, Sql, Statement, Parameters, Opts, Reason) ->
    described_again(Conn, Sql, Statement, Parameters, Opts, {error, Reason});
refused(deallocated, Status, Conn, Sql, _Statement, Parameters, Opts, Reason) ->
    deallocated(minato_conn:forget(Conn, Sql), Sql, Parameters, Opts, Status, Reason);
refused(_Stale, _Open, Conn, Sql, Statement, _Parameters, _Opts, Reason) ->
    case close(minato_conn:forget(Conn, Sql), Statement) of
        {ok, Closed} -> {error, Reason, Closed};
        Failed -> Failed
    end.

-spec deallocated(
    conn(),
    binary(),
    [term()],
    minato_protocol:opts(),
    minato_protocol:transaction_status(),
    error()
) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
deallocated(Conn, Sql, Parameters, Opts, Status, Reason) ->
    ?LOG_INFO(
        #{event => cached_statement_deallocated, sql => statement_for_log(Sql)},
        #{domain => [minato]}
    ),
    case Status of
        idle -> parsed(Conn, Sql, Parameters, Opts);
        _Open -> {error, Reason, Conn}
    end.

-spec replanned(conn(), binary(), statement(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
replanned(Conn, Sql, Statement, Parameters, Opts) ->
    ?LOG_INFO(
        #{event => cached_plan_invalidated, sql => statement_for_log(Sql)},
        #{domain => [minato]}
    ),
    case close(minato_conn:forget(Conn, Sql), Statement) of
        {ok, Closed} -> parsed(Closed, Sql, Parameters, Opts);
        Failed -> Failed
    end.

%% Asks the server what it makes of the SQL now, unnamed and in one round
%% trip. Parameters of other types than the kept ones mean the kept statement
%% is stale and is replaced; the same types mean it was not the statement, and
%% the call ends the way it was going to.
-spec described_again(
    conn(),
    binary(),
    statement(),
    [term()],
    minato_protocol:opts(),
    {raise, term(), erlang:raise_stacktrace()} | {error, error()}
) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
described_again(Conn, Sql, #statement{parameters = Kept} = Statement, Parameters, Opts, Unchanged) ->
    case asked(Conn, ?UNNAMED, Sql, sync) of
        {ok, #statement{parameters = Kept}, Ready} -> unchanged(Unchanged, Ready);
        {ok, _Retyped, Ready} -> replanned(Ready, Sql, Statement, Parameters, Opts);
        Failed -> Failed
    end.

-spec unchanged({raise, term(), erlang:raise_stacktrace()} | {error, error()}, conn()) ->
    {error, error(), conn()}.
unchanged({raise, Reason, Stacktrace}, _Conn) -> reraise(error, Reason, Stacktrace);
unchanged({error, Reason}, Conn) -> {error, Reason, Conn}.

-doc """
Parse a statement under a name and keep it for the life of the connection.

The describe round trip happens here rather than on every `execute/3`, which is
the point: a statement run in a loop costs one round trip a time. Preparing is
one round trip itself: `Parse`, `Describe` and `Sync` in one write.

The name is the caller's. A name already in use is refused with `42P05`, so
`close/2` it first to parse something else under it.

The answer is given the connection's `timeout` as its deadline, as a statement
with no `timeout` of its own is. A server that has not finished it by then,
whatever it sends in the meantime, costs the connection:
`{error, {socket, timeout}}`.
""".
-spec prepare(conn(), binary(), iodata()) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
prepare(Conn, Name, Sql) ->
    cleared(asked(bounded(Conn, #{}), Name, Sql, sync)).

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
a heavy price for what is usually a typo. A parameter that will not encode
raises `error({minato_codec, _})` in the same way.
""".
-spec execute(conn(), statement(), [term()], opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
execute(Conn, Statement, Parameters, Opts) ->
    Bounded = bounded(Conn, Opts),
    Decoding = decoding(Opts),
    observed(Bounded, prepared, name(Statement), fun() ->
        run(Bounded, Statement, Parameters, Decoding)
    end).

-spec name(statement()) -> binary().
name(#statement{name = Name}) ->
    Name.

-spec bounded(conn(), opts()) -> conn().
bounded(Conn, Opts) ->
    minato_conn:deadline(Conn, maps:get(timeout, Opts, minato_conn:timeout(Conn))).

-spec decoding(opts()) -> minato_protocol:opts().
decoding(Opts) when map_size(Opts) =:= 0 ->
    ?DEFAULT_DECODING;
decoding(#{timeout := _} = Opts) when map_size(Opts) =:= 1 ->
    ?DEFAULT_DECODING;
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
    Bounded = bounded(Conn, #{}),
    case minato_conn:send(Bounded, [{close, statement, Name}, sync]) of
        ok -> cleared(closed(Bounded));
        {error, Reason} -> {error, Reason}
    end.

%%----------------------------------------------------------------------
%% Instrumentation
%%----------------------------------------------------------------------

-spec observed(conn(), atom(), iodata(), fun(() -> Answer)) -> Answer.
observed(Conn, Path, Sql, Fun) ->
    Origin = (minato_conn:origin(Conn))#{path => Path},
    Metadata = maps:merge(Origin, minato_telemetry:statements(Sql)),
    minato_telemetry:span([minato, query], Metadata, fun() ->
        try
            reported(cleared(Fun()), Origin)
        catch
            Class:Reason:Stacktrace ->
                reraise(
                    Class, minato_telemetry:reason(Reason), minato_telemetry:frames(Stacktrace)
                )
        end
    end).

-spec reraise(error | exit | throw, term(), erlang:raise_stacktrace()) -> no_return().
reraise(Class, Reason, Stacktrace) ->
    erlang:raise(Class, Reason, Stacktrace),
    error(badarg).

-spec cleared(dynamic()) -> dynamic().
cleared({ok, Answer, Conn}) -> {ok, Answer, minato_conn:deadline(Conn, infinity)};
cleared({error, Reason, Conn}) -> {error, Reason, minato_conn:deadline(Conn, infinity)};
cleared(Answer) -> Answer.

-spec reported(dynamic(), minato_telemetry:metadata()) ->
    {dynamic(), minato_telemetry:metadata()}.
reported({ok, #{command := Command, num_rows := Rows}, _Conn} = Answer, Origin) ->
    {Answer, Origin#{outcome => ok, command => Command, num_rows => Rows}};
reported({ok, Results, _Conn} = Answer, Origin) when is_list(Results) ->
    {Answer, Origin#{outcome => ok, statements => length(Results)}};
reported({error, Reason, _Conn} = Answer, Origin) ->
    {Answer, Origin#{outcome => error, reason => minato_telemetry:reason(Reason)}};
reported({error, Reason} = Answer, Origin) ->
    {Answer, Origin#{outcome => error, reason => minato_telemetry:reason(Reason)}}.

%%----------------------------------------------------------------------
%% The extended protocol
%%----------------------------------------------------------------------

%% Behind a `Flush` the exchange stays open for the `Bind` that follows, and
%% a refusal has to be ended with a `Sync` here. Behind a `Sync` it is over
%% either way, and what is left is to read to `ReadyForQuery`.
-spec describe(conn(), binary(), iodata()) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
describe(Conn, Name, Sql) ->
    asked(Conn, Name, Sql, flush).

-spec asked(conn(), binary(), iodata(), flush | sync) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
asked(Conn, Name, Sql, End) ->
    case minato_conn:send(Conn, [{parse, Name, Sql, []}, {describe, statement, Name}, End]) of
        ok -> described(Conn, Name, undefined, End);
        {error, Reason} -> {error, Reason}
    end.

-spec described(conn(), binary(), [minato_oid:oid()] | undefined, flush | sync) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
described(Conn, Name, Parameters, End) ->
    case minato_conn:next(Conn) of
        {ok, parse_complete, Read} ->
            described(Read, Name, Parameters, End);
        {ok, {parameter_description, Oids}, Read} ->
            described(Read, Name, Oids, End);
        {ok, {row_description, Described}, Read} ->
            ended(Read, statement(Name, Parameters, Described), End);
        {ok, no_data, Read} ->
            ended(Read, statement(Name, Parameters, []), End);
        {ok, {notice_response, _Fields}, Read} ->
            described(Read, Name, Parameters, End);
        {ok, {notification_response, _Pid, _Channel, _Payload}, Read} ->
            described(Read, Name, Parameters, End);
        {ok, {parameter_status, _Name, _Value}, Read} ->
            described(Read, Name, Parameters, End);
        {ok, {error_response, Reported}, Read} when End =:= flush ->
            abort(Read, {pgsql_error, Reported});
        {ok, {error_response, Reported}, Read} ->
            failed(Read, {pgsql_error, Reported});
        {ok, Message, _Read} ->
            unexpected(Message, describe);
        {error, Reason} ->
            {error, Reason}
    end.

-spec ended(conn(), statement(), flush | sync) ->
    {ok, statement(), conn()} | {error, error(), conn()} | {error, error()}.
ended(Conn, Statement, flush) ->
    {ok, Statement, Conn};
ended(Conn, Statement, sync) ->
    case drain(Conn) of
        {ok, Drained} -> {ok, Statement, Drained};
        {error, Reason} -> {error, Reason}
    end.

-spec statement(binary(), [minato_oid:oid()] | undefined, [minato_protocol:field()]) ->
    statement().
statement(Name, Parameters, Fields) ->
    Oids = parameters(Parameters),
    Described = [Field#{format => format(Field)} || Field <- Fields],
    #statement{
        name = Name,
        parameters = Oids,
        parameter_formats = [minato_codec:preferred_format(Oid) || Oid <- Oids],
        fields = Described,
        formats = [format(Field) || Field <- Fields],
        decoder = minato_protocol:decoder(Described, ?DEFAULT_DECODING)
    }.

-spec format(minato_protocol:field()) -> minato_codec:format().
format(#{type_oid := Oid}) ->
    minato_codec:preferred_format(Oid).

-spec parameters([minato_oid:oid()] | undefined) -> [minato_oid:oid()].
parameters(undefined) -> [];
parameters(Oids) -> Oids.

-spec closed(conn()) -> {ok, conn()} | {error, error(), conn()} | {error, error()}.
closed(Conn) ->
    drain(Conn).

-spec run(conn(), statement(), [term()], minato_protocol:opts()) ->
    {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
run(Conn, Statement, Parameters, Opts) ->
    begun(bound(Conn, Statement, encode(Conn, Statement, Parameters, Opts), Opts)).

%% A refusal that arrived before `BindComplete` is about the statement as the
%% server holds it and nothing has run. One that arrived after it is the
%% statement failing, and whatever it did outside its transaction is done.
-type ran() ::
    {ok, result(), conn()}
    | {error, error(), conn()}
    | {error, error()}
    | {unbound, error(), conn()}.

-spec begun(ran()) -> {ok, result(), conn()} | {error, error(), conn()} | {error, error()}.
begun({unbound, Reason, Conn}) -> {error, Reason, Conn};
begun(Answer) -> Answer.

-spec bound(conn(), statement(), [iodata() | null], minato_protocol:opts()) -> ran().
bound(Conn, #statement{} = Statement, Encoded, Opts) ->
    #statement{
        name = Name,
        parameter_formats = ParameterFormats,
        formats = Formats,
        fields = Fields
    } = Statement,
    Bind = {bind, ?UNNAMED, Name, ParameterFormats, Encoded, Formats},
    Decoder = decoder(Statement, Opts),
    case minato_conn:send(Conn, [Bind, {execute, ?UNNAMED, 0}, sync]) of
        ok -> executed(decoding(Conn, Fields, Decoder), Decoder, Opts);
        {error, Reason} -> {error, Reason}
    end.

-spec decoder(statement(), minato_protocol:opts()) -> minato_protocol:decoder().
decoder(#statement{decoder = Decoder}, #{
    return_rows_as_maps := false,
    column_name_as_atom := false,
    uuid_format := string,
    datetime_format := datetime,
    numeric_format := binary
}) ->
    Decoder;
decoder(#statement{fields = Fields}, Opts) ->
    minato_protocol:decoder(Fields, Opts).

-spec encode(conn(), statement(), [term()], minato_protocol:opts()) -> [iodata() | null].
encode(Conn, Statement, Parameters, Opts) ->
    try
        encoded(Statement, Parameters, Opts)
    catch
        Class:Reason:Stacktrace ->
            ok = resync(Conn),
            reraise(Class, Reason, Stacktrace)
    end.

-spec encoded(statement(), [term()], minato_protocol:opts()) -> [iodata() | null].
encoded(#statement{parameters = Oids, parameter_formats = Formats}, Parameters, Opts) when
    length(Oids) =:= length(Parameters)
->
    encoded(Oids, Formats, Parameters, codec_opts(Opts));
encoded(#statement{parameters = Oids}, Parameters, _Opts) ->
    bad(bind, parameter_count_mismatch, {length(Oids), length(Parameters)}).

-spec encoded([minato_oid:oid()], [minato_codec:format()], [term()], minato_codec:opts()) ->
    [iodata() | null].
encoded([], [], [], _Opts) ->
    [];
encoded([Oid | Oids], [Format | Formats], [Value | Values], Opts) ->
    [minato_codec:encode(Oid, Value, Format, Opts) | encoded(Oids, Formats, Values, Opts)].

-spec codec_opts(minato_protocol:opts()) -> minato_codec:opts().
codec_opts(#{uuid_format := string, datetime_format := datetime, numeric_format := binary}) ->
    ?DEFAULT_CODEC;
codec_opts(Opts) ->
    maps:with([uuid_format, datetime_format, numeric_format], Opts).

-spec executed(conn(), minato_protocol:decoder(), minato_protocol:opts()) -> ran().
executed(Conn, Decoder, _Opts) ->
    executed(Conn, Decoder, [], unbound).

-spec decoding(conn(), [minato_protocol:field()], minato_protocol:decoder()) -> conn().
decoding(Conn, [], _Decoder) ->
    Conn;
decoding(Conn, _Fields, Decoder) ->
    minato_conn:decoding(Conn, Decoder).

-spec executed(
    conn(), minato_protocol:decoder(), [[minato_protocol:row()]], unbound | minato_protocol:tag()
) -> ran().
executed(Conn, Decoder, Runs, unbound) ->
    case minato_conn:next(Conn) of
        {ok, bind_complete, Read} ->
            executed(Read, Decoder, Runs, {unknown, undefined});
        {ok, {error_response, Reported}, Read} ->
            unbound(failed(plain(Read), {pgsql_error, Reported}));
        {ok, Message, _Read} when
            Message =:= parse_complete;
            Message =:= no_data;
            element(1, Message) =:= parameter_description
        ->
            unexpected(Message, execute);
        {ok, Unasked, Read} when
            element(1, Unasked) =:= notice_response;
            element(1, Unasked) =:= parameter_status;
            element(1, Unasked) =:= notification_response
        ->
            executed(Read, Decoder, Runs, unbound);
        {ok, Message, _Read} ->
            unbound_answer(Message);
        {error, Reason} ->
            {error, Reason}
    end;
executed(Conn, Decoder, Runs, Tag) ->
    case minato_conn:next(Conn) of
        {ok, {rows, Run}, Read} ->
            executed(Read, Decoder, [Run | Runs], Tag);
        {ok, {data_row, Columns}, Read} ->
            Row = minato_protocol:decode_row(Decoder, Columns),
            executed(Read, Decoder, [[Row] | Runs], Tag);
        {ok, {command_complete, Complete}, Read} ->
            executed(Read, Decoder, Runs, Complete);
        {ok, empty_query_response, Read} ->
            executed(Read, Decoder, Runs, {empty, undefined});
        {ok, {ready_for_query, _Status}, Read} ->
            {ok, minato_protocol:result(Tag, joined(Runs, [])), plain(Read)};
        {ok, {error_response, Reported}, Read} ->
            failed(plain(Read), {pgsql_error, Reported});
        {ok, Message, _Read} when
            Message =:= parse_complete;
            Message =:= no_data;
            element(1, Message) =:= parameter_description
        ->
            unexpected(Message, execute);
        {ok, _Message, Read} ->
            executed(Read, Decoder, Runs, Tag);
        {error, Reason} ->
            {error, Reason}
    end.

-spec unbound({error, error(), conn()} | {error, error()}) ->
    {unbound, error(), conn()} | {error, error()}.
unbound({error, Reason, Conn}) -> {unbound, Reason, Conn};
unbound({error, Reason}) -> {error, Reason}.

%%----------------------------------------------------------------------
%% The simple protocol
%%----------------------------------------------------------------------

-spec collect(conn(), minato_protocol:opts(), minato_protocol:decoder()) ->
    {ok, [result()], conn()} | {error, error(), conn()} | {error, error()}.
collect(Conn, Opts, Decoder) ->
    collect(minato_conn:decoding_opts(plain(Conn), Opts), Opts, Decoder, [], [], undefined).

-spec collect(
    conn(),
    minato_protocol:opts(),
    minato_protocol:decoder(),
    [minato_protocol:row()],
    [result()],
    error() | undefined
) ->
    {ok, [result()], conn()} | {error, error(), conn()} | {error, error()}.
collect(Conn, Opts, Decoder, Rows, Results, Failure) ->
    case minato_conn:next(Conn) of
        {ok, {row_description, Described}, Read} ->
            collect(Read, Opts, minato_protocol:decoder(Described, Opts), Rows, Results, Failure);
        {ok, {rows, Run}, Read} ->
            collect(Read, Opts, Decoder, reversed(Run, Rows), Results, Failure);
        {ok, {data_row, Columns}, Read} ->
            Row = minato_protocol:decode_row(Decoder, Columns),
            collect(Read, Opts, Decoder, [Row | Rows], Results, Failure);
        {ok, {command_complete, Complete}, Read} ->
            collect(Read, Opts, Decoder, [], [completed(Complete, Rows) | Results], Failure);
        {ok, empty_query_response, Read} ->
            Empty = completed({empty, undefined}, Rows),
            collect(Read, Opts, Decoder, [], [Empty | Results], Failure);
        {ok, {ready_for_query, _Status}, Read} ->
            finished(Read, Results, Failure);
        {ok, {error_response, Reported}, Read} ->
            collect(Read, Opts, Decoder, Rows, Results, {pgsql_error, Reported});
        {ok, _Message, Read} ->
            collect(Read, Opts, Decoder, Rows, Results, Failure);
        {error, Reason} ->
            {error, Reason}
    end.

-spec completed(minato_protocol:tag(), [minato_protocol:row()]) -> result().
completed(Complete, Rows) ->
    minato_protocol:result(Complete, reversed(Rows, [])).

-spec finished(conn(), [result()], error() | undefined) ->
    {ok, [result()], conn()} | {error, error(), conn()}.
finished(Conn, Results, undefined) ->
    {ok, reversed(Results, []), settled(Conn)};
finished(Conn, _Results, Failure) ->
    {error, Failure, settled(Conn)}.

-spec settled(conn()) -> conn().
settled(Conn) ->
    minato_conn:decoding_opts(Conn, undefined).

-spec plain(conn()) -> conn().
plain(Conn) ->
    minato_conn:decoding(Conn, undefined).

-spec joined([[Item]], [Item]) -> [Item].
joined([], Rows) ->
    Rows;
joined([Run | Runs], Rows) ->
    joined(Runs, Run ++ Rows).

-spec reversed([Item], [Item]) -> [Item].
reversed([], Acc) ->
    Acc;
reversed([Item | Rest], Acc) ->
    reversed(Rest, [Item | Acc]).

%%----------------------------------------------------------------------
%% Getting back to a ready connection
%%----------------------------------------------------------------------

%% For a raise that is about the call and not the connection. Nothing of the
%% `Bind` has been written when a parameter turns out not to encode, but the
%% `Parse` before it may have been, and the server holds that exchange open
%% until it is told `Sync`. A connection that cannot be put back is closed, so
%% that the one the caller still holds fails instead of answering out of step.
-spec resync(conn()) -> ok.
resync(Conn) ->
    case minato_conn:send(Conn, sync) of
        ok -> ready_or_closed(Conn, drain(Conn));
        {error, _Reason} -> minato_conn:close(Conn)
    end.

-spec ready_or_closed(conn(), {ok, conn()} | {error, error(), conn()} | {error, error()}) -> ok.
ready_or_closed(_Conn, {ok, _Ready}) -> ok;
ready_or_closed(Conn, _Failed) -> minato_conn:close(Conn).

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

%% Named and not quoted: what arrived can be a row.
-spec unbound_answer(minato_protocol:backend()) -> no_return().
unbound_answer(Message) when is_atom(Message) ->
    bad(execute, unexpected_message, Message);
unbound_answer(Message) ->
    bad(execute, unexpected_message, element(1, Message)).

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
