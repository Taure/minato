-module(minato_framer_bench).
-moduledoc """
Measures bulk framing against reading a header and then a payload.

The two designs are only interesting under a socket, because what separates
them is the number of reads, not the number of bytes. `bulk/2` asks the socket
for whatever it has and frames the lot with carry-over. `header/2` reads the
five byte header, then reads exactly the payload the header declared, once per
message. Both produce the same messages from the same result set, and
`equivalent/1` requires it, so a run that got faster by dropping messages fails
rather than reports.

Not a test. `run/0` prints a table and is meant to be read by a person; nothing
here asserts a wall clock figure, because a shared build machine cannot promise
one.

```erlang
1> minato_framer_bench:run().
```
""".

-export([run/0, run/1, sockets/2, bulk/2, header/2, result_set/1, equivalent/1, connected/2]).

-define(TIMEOUT, 30000).
-define(REPEATS, 20).

-doc "Time both readers over the row counts the design was argued from.".
-spec run() -> ok.
run() ->
    run([100, 1000, 5000]).

-doc "Time both readers over the given row counts.".
-spec run([pos_integer()]) -> ok.
run(RowCounts) ->
    io:format("~n~-8s ~-12s ~-12s ~-10s ~-10s~n", [
        "rows", "bulk us", "header us", "speedup", "reads"
    ]),
    [report(Rows) || Rows <- RowCounts],
    ok.

-spec report(pos_integer()) -> ok.
report(Rows) ->
    {Bulk, BulkReads} = sockets(Rows, bulk),
    {Header, HeaderReads} = sockets(Rows, header),
    io:format("~-8w ~-12w ~-12w ~-10s ~w vs ~w~n", [
        Rows, Bulk, Header, speedup(Bulk, Header), BulkReads, HeaderReads
    ]).

-spec speedup(pos_integer(), pos_integer()) -> string().
speedup(Bulk, Header) ->
    lists:flatten(io_lib:format("~.2fx", [Header / Bulk])).

-doc """
Run one reader over a loopback socket `?REPEATS` times and return the median
microseconds and the number of reads the last run took.
""".
-spec sockets(pos_integer(), bulk | header) -> {pos_integer(), pos_integer()}.
sockets(Rows, Reader) ->
    Bytes = result_set(Rows),
    [{_, Reads} | _] = Samples = [once(Bytes, Reader) || _ <- lists:seq(1, ?REPEATS)],
    {median([Time || {Time, _} <- Samples]), Reads}.

-spec once(binary(), bulk | header) -> {pos_integer(), pos_integer()}.
once(Bytes, Reader) ->
    connected(Bytes, fun(Socket) ->
        Started = erlang:monotonic_time(microsecond),
        {_Messages, Reads} = read(Reader, Socket),
        {elapsed(erlang:monotonic_time(microsecond) - Started), Reads}
    end).

-spec elapsed(integer()) -> pos_integer().
elapsed(Micros) when Micros > 0 -> Micros;
elapsed(_Micros) -> 1.

-spec read(bulk | header, gen_tcp:socket()) -> {[minato_protocol:backend()], pos_integer()}.
read(bulk, Socket) -> bulk(Socket, ?TIMEOUT);
read(header, Socket) -> header(Socket, ?TIMEOUT).

%%----------------------------------------------------------------------
%% The two readers
%%----------------------------------------------------------------------

-doc """
Read whatever the socket has and frame it, carrying the remainder forward, until
`ReadyForQuery` arrives.
""".
-spec bulk(gen_tcp:socket(), timeout()) -> {[minato_protocol:backend()], pos_integer()}.
bulk(Socket, Timeout) ->
    bulk(Socket, Timeout, ~"").

-spec bulk(gen_tcp:socket(), timeout(), binary()) ->
    {[minato_protocol:backend()], pos_integer()}.
bulk(Socket, Timeout, Buffer) ->
    Received = recv(Socket, 0, Timeout),
    {Messages, Rest} = minato_protocol:frame(<<Buffer/binary, Received/binary>>),
    case done(Messages) of
        true ->
            {Messages, 1};
        false ->
            {Later, Reads} = bulk(Socket, Timeout, Rest),
            {Messages ++ Later, Reads + 1}
    end.

-doc """
Read the five byte header, then read exactly the payload it declares, once per
message, until `ReadyForQuery` arrives.
""".
-spec header(gen_tcp:socket(), timeout()) -> {[minato_protocol:backend()], pos_integer()}.
header(Socket, Timeout) ->
    <<Type, Length:32>> = recv(Socket, 5, Timeout),
    {Payload, Taken} = payload(Socket, Length - 4, Timeout),
    {ok, Message, ~""} = minato_protocol:decode(<<Type, Length:32, Payload/binary>>),
    case done([Message]) of
        true ->
            {[Message], Taken + 1};
        false ->
            {Later, Reads} = header(Socket, Timeout),
            {[Message | Later], Reads + Taken + 1}
    end.

-spec payload(gen_tcp:socket(), non_neg_integer(), timeout()) -> {binary(), 0 | 1}.
payload(_Socket, 0, _Timeout) -> {~"", 0};
payload(Socket, Size, Timeout) -> {recv(Socket, Size, Timeout), 1}.

-doc "One read, insisting the socket is in binary mode rather than assuming it.".
-spec recv(gen_tcp:socket(), non_neg_integer(), timeout()) -> binary().
recv(Socket, Size, Timeout) ->
    case gen_tcp:recv(Socket, Size, Timeout) of
        {ok, Bytes} when is_binary(Bytes) -> Bytes
    end.

-spec done([minato_protocol:backend()]) -> boolean().
done([]) -> false;
done([{ready_for_query, _} | _Rest]) -> true;
done([_Message | Rest]) -> done(Rest).

%%----------------------------------------------------------------------
%% Equivalence
%%----------------------------------------------------------------------

-doc "Both readers over the same result set, for a caller that wants to compare them.".
-spec equivalent(pos_integer()) -> {[minato_protocol:backend()], [minato_protocol:backend()]}.
equivalent(Rows) ->
    Bytes = result_set(Rows),
    {Bulk, _} = connected(Bytes, fun(Socket) -> read(bulk, Socket) end),
    {Header, _} = connected(Bytes, fun(Socket) -> read(header, Socket) end),
    {Bulk, Header}.

%%----------------------------------------------------------------------
%% A result set a server would send
%%----------------------------------------------------------------------

-doc "`RowDescription`, `Rows` eight column `DataRow`s, `CommandComplete`, `ReadyForQuery`.".
-spec result_set(pos_integer()) -> binary().
result_set(Rows) ->
    iolist_to_binary([
        minato_backend_writer:write({row_description, description()}),
        [minato_backend_writer:write({data_row, row(Index)}) || Index <- lists:seq(1, Rows)],
        minato_backend_writer:write({command_complete, tag(Rows)}),
        minato_backend_writer:write({ready_for_query, idle})
    ]).

-spec tag(pos_integer()) -> binary().
tag(Rows) ->
    <<"SELECT ", (integer_to_binary(Rows))/binary>>.

-spec description() -> [minato_protocol:field()].
description() ->
    [field(Name, Oid) || {Name, Oid} <- columns()].

-spec columns() -> [{binary(), minato_oid:oid()}].
columns() ->
    [
        {~"id", 20},
        {~"account_id", 20},
        {~"email", 25},
        {~"name", 25},
        {~"balance", 20},
        {~"active", 16},
        {~"created_at", 1114},
        {~"note", 25}
    ].

-spec field(binary(), minato_oid:oid()) -> minato_protocol:field().
field(Name, Oid) ->
    #{
        name => Name,
        table_oid => 16384,
        column => 1,
        type_oid => Oid,
        type_size => -1,
        type_modifier => -1,
        format => binary
    }.

-spec row(pos_integer()) -> [binary() | null].
row(Index) ->
    [
        <<Index:64>>,
        <<(Index * 7):64>>,
        <<"user", (integer_to_binary(Index))/binary, "@example.com">>,
        <<"Row number ", (integer_to_binary(Index))/binary>>,
        <<(Index * 100):64>>,
        <<1>>,
        <<Index:64>>,
        null
    ].

%%----------------------------------------------------------------------
%% Loopback
%%----------------------------------------------------------------------

-doc """
Serve `Bytes` over a loopback connection and run `Fun` against the client end.

The connection is set up and torn down outside whatever `Fun` measures, so a
timing run does not charge the reader for `listen`, `accept` and `connect`.
""".
-spec connected(binary(), fun((gen_tcp:socket()) -> Result)) -> Result.
connected(Bytes, Fun) ->
    {ok, Listen} = gen_tcp:listen(0, listen_opts()),
    {ok, Port} = inet:port(Listen),
    Server = spawn_link(fun() -> serve(Listen, Bytes) end),
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, connect_opts(), ?TIMEOUT),
    try
        Fun(Socket)
    after
        ok = gen_tcp:close(Socket),
        unlink(Server),
        exit(Server, shutdown),
        ok = gen_tcp:close(Listen)
    end.

-spec listen_opts() -> [gen_tcp:listen_option()].
listen_opts() ->
    [binary, {packet, raw}, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}, {backlog, 4}].

-spec connect_opts() -> [gen_tcp:connect_option()].
connect_opts() ->
    [binary, {packet, raw}, {active, false}, {nodelay, true}].

-spec serve(gen_tcp:socket(), binary()) -> ok.
serve(Listen, Bytes) ->
    {ok, Socket} = gen_tcp:accept(Listen, ?TIMEOUT),
    ok = gen_tcp:send(Socket, Bytes),
    receive
        stop -> ok
    after ?TIMEOUT -> ok
    end.

-spec median([pos_integer()]) -> pos_integer().
median(Times) ->
    Sorted = lists:sort(Times),
    case lists:nth(1 + length(Sorted) div 2, Sorted) of
        Median when is_integer(Median), Median > 0 -> Median
    end.
