-module(minato_conn).
-moduledoc """
One connection to a PostgreSQL server, owned by the process that opened it.

`connect/1` performs the whole opening exchange - TCP, optionally TLS, the
`StartupMessage`, authentication through `m:minato_auth`, and then the
parameters and the `BackendKeyData` the server volunteers - and hands back a
connection the calling process owns outright.

There is no connection process. The socket is `{active, false}` and belongs to
the caller, so a query is a send and a read on the caller's own scheduler slot
rather than a message to a `gen_server` that puts every caller behind the
slowest one. The PostgreSQL protocol is FIFO per connection, so a single owning
process is an unpreemptable queue: one slow query stalls every other caller of
that process, and no timeout on the caller's side can take the connection back.
Caller ownership also gives session pinning, which transactions, advisory locks,
`SET ROLE` and `LISTEN` all need to be correct rather than merely fast.

That is why `t:conn/0` is threaded through `next/1` rather than being a handle
with hidden state: bytes that have arrived but have not been read yet live in
the connection, so a caller that drops the returned connection drops the buffer
with it.

## Reading

`next/1` answers with the next message, reading from the socket only when
nothing already decoded is waiting. A read frames everything that arrived, so
one `recv` yields as many messages as the server sent - which is the whole point
of `minato_protocol:frame/1` - without the caller ever seeing the buffer.

Every read passes an explicit timeout. A read that times out leaves the
connection with an unknown number of bytes still to come, so the connection is
no longer usable and `next/1` says so with `{error, {socket, timeout}}`; the
owner closes it. Recovering the stream would mean knowing how far through a
message the far end was, which is exactly what a timeout means we do not know.

## TLS

`ssl => true` upgrades the socket before the startup message, and refuses to
continue when the server answers that it will not do TLS. There is no `prefer`
mode. A mode that continues in the clear when the server declines is a mode the
man in the middle chooses, because declining is the one message an attacker
sitting on the connection can always produce.

Verification is on by default: `verify_peer` against the OS trust store, with
the hostname checked and `server_name_indication` set, which OTP needs to be
told explicitly on a socket upgrade. Anything passed in `ssl_options` replaces
the default for that option and nothing else, so turning verification off is
possible and has to be written down.

Under TLS the SCRAM exchange is bound to the session by default:
`SCRAM-SHA-256-PLUS` with `tls-server-end-point`, which puts the hash of the
server's certificate inside the material the client proof covers. A man in the
middle holding a certificate the client accepts can otherwise relay the whole
exchange and keep the session; with binding, the hash it bound to is not the one
the real server sees, and the proof is refused. `channel_binding => require`
refuses to connect without it.

## A refusal that arrives as a closed socket

A server that refuses the startup exchange writes why and then the backend
exits. On Windows a socket closed with anything still unread is reset rather
than shut down, and a reset discards what the far end had already received, so
the reason can be gone before it can be read: `connect/1` answers
`{error, {socket, closed}}` or `{error, {socket, econnreset}}` where the same
call on Linux answers `{error, {pgsql_error, #{code := <<"3D000">>}}}`. The
connection is refused either way, and the server's log has the reason. Nothing
on this side can recover a message the kernel threw away.

## Cleartext passwords

A server may ask for the password in the clear. minato answers only when the
transport is TLS, and refuses otherwise with `{error, cleartext_password_refused}`.
The password is the credential for every future connection too, so handing it to
whoever is on the wire is worse than failing to connect. `auth => [Method]`
narrows what is acceptable further, down to SCRAM alone.

## Cancelling

`cancel/1` opens a second connection and sends `CancelRequest` with the
`BackendKeyData` from this one, because that is the only way the protocol offers
to interrupt a running query: the connection running it is busy. Cancellation is
a request. The server may finish first, and a caller still has to read whatever
the query produced.

The password is not kept after the exchange that used it, so `cancel/1` works
without one, which is what `CancelRequest` documents: possession of the secret
the server issued is the whole of the authorisation.
""".

-export([
    connect/1,
    close/1,
    cancel/1,
    give_away/2,
    send/2,
    next/1,
    next/2,
    decoding/2,
    decoding_opts/2,
    usable/1,
    activate/1,
    deactivate/1,
    handle_message/2,
    parameters/1,
    parameter/2,
    channel_binding/1,
    age/1,
    recall/2,
    remember/3,
    forget/2,
    claim/1,
    statements/1,
    transaction_status/1,
    backend_key/1,
    timeout/1,
    with_timeout/2,
    deadline/2
]).

-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, 5432).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_TIMEOUT, 15000).
-define(DEFAULT_TLS_DEPTH, 3).
-define(DEFAULT_STATEMENTS, 64).
-define(DEFAULT_CANCEL_TIMEOUT, 5000).

-include_lib("public_key/include/public_key.hrl").

%% eqWAlizer cannot see that the transport field decides what the socket field
%% holds, and `ssl:connect/3` is specified for the sockets that existed before
%% it learned to take a handle from `m:socket`. Both are true at run time and
%% neither is expressible, so the two crossings live here rather than spread
%% through the module.
-eqwalizer({nowarn_function, handle/1}).
-eqwalizer({nowarn_function, upgraded/3}).

-record(conn, {
    transport :: transport(),
    socket :: socket(),
    binding :: binary() | undefined,
    buffer = ~"" :: binary(),
    pending = [] :: [minato_protocol:backend()],
    parameters = #{} :: #{binary() => binary()},
    status = idle :: minato_protocol:transaction_status(),
    key :: key() | undefined,
    timeout :: timeout(),
    deadline = infinity :: integer() | infinity,
    cancelled = false :: boolean(),
    grace :: timeout(),
    frame_opts :: minato_protocol:frame_opts(),
    waiting :: minato_socket:waiting() | undefined,
    opened :: integer(),
    statements = #{} :: #{binary() => term()},
    prefix = ~"" :: binary(),
    prepared = 0 :: non_neg_integer(),
    limit :: non_neg_integer(),
    opts :: opts()
}).

-doc """
How to reach a server and who to be.

```erlang
#{host => inet:socket_address() | inet:hostname(),
  port => inet:port_number(),
  user := binary(),
  password => binary() | fun(() -> binary()),
  database => binary(),
  parameters => #{binary() => binary()},
  ssl => boolean(),
  ssl_options => [ssl:tls_client_option()],
  channel_binding => minato_auth:channel_binding(),
  auth => [method()],
  connect_timeout => timeout(),
  timeout => timeout(),
  socket_options => [gen_tcp:connect_option()],
  transport => inet | socket,
  prepared_statements => non_neg_integer(),
  cancel_timeout => timeout(),
  frame_opts => minato_protocol:frame_opts()}
```

`user` is the only one that has to be given. `database` defaults to `user`, as
PostgreSQL itself does.

`password` may be a fun, which is called once per connection attempt and never
stored. That is what a rotating credential needs: a password read at start up
and held in a pool's configuration for a month is a password that expires while
the pool holds it.

`parameters` are added to the `StartupMessage` and are how `application_name`
gets set. Two are sent unless they are given here: `client_encoding` is `UTF8`,
because the codecs decode text as UTF-8 and a server sending LATIN1 would put
mojibake in a binary rather than raise; and `DateStyle` is `ISO, MDY`, because
the text format for dates and timestamps is only unambiguous under ISO. Neither
affects the binary format.

`channel_binding` decides whether SCRAM is tied to the TLS session. It defaults
to `prefer` under `ssl => true` and `disable` without it, since there is nothing
to bind to on a plain socket. `require` refuses to connect at all unless the
server offers `SCRAM-SHA-256-PLUS`.

`transport` is `socket`, which is `m:minato_socket` over the socket NIFs, or
`inet`, the driver every BEAM program uses. `socket` is the default: it does
everything the driver does on every machine minato runs on, costs about a
quarter less per query and about half less per pooled one, and holds more
throughput at the same CPU once a pool is deep enough for per-operation cost to
show. `inet` is there for a machine or a workload that disagrees. See
`m:minato_socket`.

`prepared_statements` is how many statements this connection will keep parsed on
the server for `minato_query:cached/4`. It defaults to 64, and 0 turns caching
off. See `m:minato_query` for what fills it.

`timeout` is the per read timeout and applies for the life of the connection.
`connect_timeout` covers the TCP connect and the TLS handshake. `cancel_timeout`
is how long a cancelled statement is given to come back before the connection is
given up on; see `deadline/2`.
""".
-type opts() :: #{
    host => inet:socket_address() | inet:hostname(),
    port => inet:port_number(),
    user := binary(),
    password => binary() | fun(() -> binary()),
    database => binary(),
    parameters => #{binary() => binary()},
    ssl => boolean(),
    ssl_options => [ssl:tls_client_option()],
    channel_binding => minato_auth:channel_binding(),
    auth => [method()],
    connect_timeout => timeout(),
    timeout => timeout(),
    socket_options => [gen_tcp:connect_option()],
    transport => inet | socket,
    prepared_statements => non_neg_integer(),
    cancel_timeout => timeout(),
    frame_opts => minato_protocol:frame_opts()
}.

-doc """
An authentication method the server may ask for.

`none` is a server that asks for nothing, which is `trust` in `pg_hba.conf`.
""".
-type method() :: scram_sha_256 | md5 | cleartext | none.

-doc "An open connection. Owned by the process that called `connect/1`.".
-opaque conn() :: #conn{}.

-doc "What `CancelRequest` needs: the process id and secret the server issued.".
-type key() :: {Pid :: integer(), Secret :: integer()}.

-doc "What went wrong. `pgsql_error` is the server refusing, everything else is local.".
-type error() ::
    {pgsql_error, minato_protocol:fields()}
    | {socket, term()}
    | {tls, term()}
    | tls_refused
    | cleartext_password_refused
    | {auth_method_refused, method()}.

-doc "The map carried by an `error({minato_conn, Report})` exception.".
-type report() :: #{message := term(), reason := term(), data := term()}.

-export_type([conn/0, opts/0, method/0, key/0, error/0, report/0]).

-type transport() :: plain() | ssl.
-type plain() :: gen_tcp | minato_socket.
-type socket() :: gen_tcp:socket() | ssl:sslsocket() | minato_socket:socket().

-doc """
Open a connection and complete the opening exchange.

Answers once the server has sent `ReadyForQuery`, so a connection that is
returned is one that can be used, not merely one that is open.

Raises `error({minato_auth, _})` for a server that asks for something it cannot
be answered with, and `error({minato_scram, _})` for a server that fails to
prove itself. The socket is closed before either is re-raised.

```erlang
{ok, Conn} = minato_conn:connect(#{user => ~"minato", password => ~"minato",
                                   database => ~"minato_test"}).
```
""".
-spec connect(opts()) -> {ok, conn()} | {error, error()}.
connect(#{user := _} = Opts) ->
    minato_telemetry:span(
        [minato, connect],
        #{
            host => maps:get(host, Opts, ?DEFAULT_HOST),
            port => maps:get(port, Opts, ?DEFAULT_PORT),
            database => maps:get(database, Opts, maps:get(user, Opts)),
            user => maps:get(user, Opts),
            ssl => maps:get(ssl, Opts, false)
        },
        fun() -> connected(opening(Opts)) end
    ).

-spec connected({ok, conn()} | {error, error()}) ->
    {{ok, conn()} | {error, error()}, minato_telemetry:metadata()}.
connected({ok, Conn}) ->
    {{ok, Conn}, #{outcome => ok}};
connected({error, Reason}) ->
    {{error, Reason}, #{outcome => error, reason => Reason}}.

-spec opening(opts()) -> {ok, conn()} | {error, error()}.
opening(Opts) ->
    Host = maps:get(host, Opts, ?DEFAULT_HOST),
    Port = maps:get(port, Opts, ?DEFAULT_PORT),
    Timeout = maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT),
    Transport = transport(Opts),
    case Transport:connect(Host, Port, socket_options(Opts), Timeout) of
        {ok, Socket} -> secure(Transport, Socket, Host, Timeout, Opts);
        {error, Reason} -> {error, {socket, Reason}}
    end.

-spec transport(opts()) -> plain().
transport(#{transport := inet}) -> gen_tcp;
transport(_Opts) -> minato_socket.

-doc """
Close a connection.

`Terminate` is sent first so the server tears the backend down rather than
discovering a closed socket, and a failure to send it is not reported: the
socket is being closed either way.
""".
-spec close(conn()) -> ok.
close(#conn{transport = Transport, socket = Socket}) ->
    _ = Transport:send(Socket, minato_protocol:encode(terminate)),
    Transport:close(Socket).

-doc """
Ask the server to cancel whatever this connection is running.

Opens a second connection to the same server, sends `CancelRequest` and closes
it. No answer is defined by the protocol: the server either cancels the query or
does not, and this connection finds out by reading what its query returned.
""".
-spec cancel(conn()) -> ok | {error, error()}.
cancel(#conn{key = undefined}) ->
    {error, {socket, no_backend_key}};
cancel(#conn{key = {Pid, Secret}, opts = Opts}) ->
    Host = maps:get(host, Opts, ?DEFAULT_HOST),
    Port = maps:get(port, Opts, ?DEFAULT_PORT),
    Timeout = maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT),
    Transport = transport(Opts),
    case Transport:connect(Host, Port, socket_options(Opts), Timeout) of
        {ok, Socket} -> cancel(Transport, Socket, Host, Timeout, {Pid, Secret}, Opts);
        {error, Reason} -> {error, {socket, Reason}}
    end.

-doc """
Write one frontend message, or a list of them in order.

A list is written as a single send, which is what the extended query protocol
wants: `Parse`, `Bind`, `Execute` and `Sync` in one write is one round trip
rather than four.
""".
-spec send(conn(), minato_protocol:frontend() | [minato_protocol:frontend()]) ->
    ok | {error, error()}.
send(#conn{transport = Transport, socket = Socket}, Messages) when is_list(Messages) ->
    write(Transport, Socket, [minato_protocol:encode(Message) || Message <- Messages]);
send(#conn{transport = Transport, socket = Socket}, Message) ->
    write(Transport, Socket, minato_protocol:encode(Message)).

-doc """
Hand the socket to another process.

The connection term is data and can be sent anywhere; the socket underneath it
cannot. It belongs to one process, and a process that is handed a connection
without being handed the socket gets `{error, {socket, einval}}` on its first
read. A pool checking a connection out has to call this, and so does the
borrower checking it back in.
""".
-spec give_away(conn(), pid()) -> ok | {error, error()}.
give_away(#conn{transport = Transport, socket = Socket}, Pid) ->
    case Transport:controlling_process(Socket, Pid) of
        ok -> ok;
        {error, Reason} -> {error, {socket, Reason}}
    end.

-doc "`next/2` with the connection's own timeout.".
-spec next(conn()) -> {ok, minato_protocol:backend(), conn()} | {error, error()}.
next(#conn{timeout = Timeout} = Conn) ->
    next(Conn, Timeout).

-doc """
Read the next message the server sent.

Reads from the socket only when no already decoded message is waiting, so a
result set of five thousand rows costs as many reads as the network chose to
split it into rather than one per row.

`ParameterStatus` is not handled here even though the server may send it at any
time. It is a message like any other and the layer above decides what to do with
it, because a connection that quietly swallowed `SET TIME ZONE` taking effect
would be hiding the one thing the message exists to announce.
""".
-spec next(conn(), timeout()) -> {ok, minato_protocol:backend(), conn()} | {error, error()}.
next(#conn{pending = [Message | Rest]} = Conn, _Timeout) ->
    {ok, Message, noted(Message, Conn#conn{pending = Rest})};
next(#conn{buffer = Buffer, frame_opts = FrameOpts} = Conn, Timeout) ->
    case minato_protocol:frame(Buffer, FrameOpts) of
        {[], _Rest} ->
            case fill(Conn, budget(Conn, Timeout)) of
                {ok, Filled} -> next(Filled, Timeout);
                {error, {socket, timeout}} -> expired(Conn, Timeout);
                {error, Reason} -> {error, Reason}
            end;
        {[Message | Rest], Remainder} ->
            Read = Conn#conn{buffer = Remainder, pending = Rest},
            {ok, Message, noted(Message, Read)}
    end.

-doc """
Decode data rows as they are framed, with `Decoder`, or stop doing so.

A result set arrives as a run of `DataRow` messages, and framing them into a
list only for the layer above to walk that list again costs an allocation and a
traversal per row. With a decoder set, a contiguous run comes back as one
`{rows, Rows}` message with the rows already decoded.

The decoder belongs to one statement's result, so it must be cleared before the
connection is used for anything else. A decoder left behind would be applied to
the next statement's rows, which is wrong data rather than an error.
""".
-spec decoding(conn(), minato_protocol:decoder() | undefined) -> conn().
decoding(#conn{frame_opts = Opts} = Conn, undefined) ->
    Conn#conn{frame_opts = maps:remove(decoder, Opts)};
decoding(#conn{frame_opts = Opts} = Conn, Decoder) ->
    Conn#conn{frame_opts = Opts#{decoder => Decoder}}.

-doc """
Build a decoder from each `RowDescription` that arrives, with `Opts`, or stop.

`decoding/2` is for a statement whose columns are known before its rows are
read. A simple query is not that: it may carry several statements, each
describing its own columns partway through the stream. Setting a decoder from
the layer above cannot work there, because the rows of the next statement may
already have been framed by the time that layer sees the description. Framing
therefore rebuilds the decoder itself as it passes each one, and drops it at
the `CommandComplete` that ends the statement.
""".
-spec decoding_opts(conn(), minato_protocol:opts() | undefined) -> conn().
decoding_opts(#conn{frame_opts = Opts} = Conn, undefined) ->
    Conn#conn{frame_opts = maps:remove(decode_opts, maps:remove(decoder, Opts))};
decoding_opts(#conn{frame_opts = Opts} = Conn, DecodeOpts) ->
    Conn#conn{frame_opts = Opts#{decode_opts => DecodeOpts}}.

-doc """
Whether this connection is still worth handing to a caller.

A pooled connection can die while nobody is holding it: the server restarts,
an administrator ends the backend, a failover moves the database. Nothing tells
the pool, so without asking it lends a connection that is already gone and the
caller gets a socket error for a statement that never reached a server.

Asking costs one non-blocking read. No bytes waiting means the connection is
idle and healthy, which is the answer for a pooled connection. A closed socket
is the case this exists for. Bytes waiting means the server said something
nobody read, so the session is not in the state a caller would assume, and it
is cheaper to open a new connection than to work out what it said.
""".
-spec usable(conn()) -> boolean().
usable(#conn{transport = Transport, socket = Socket}) ->
    case Transport:recv(Socket, 0, 0) of
        {error, timeout} -> true;
        _Closed_or_unread -> false
    end.

-spec noted(minato_protocol:backend(), conn()) -> conn().
noted({ready_for_query, Status}, #conn{frame_opts = Opts} = Conn) ->
    Conn#conn{status = Status, frame_opts = maps:remove(decoder, Opts)};
noted({row_description, Fields}, #conn{frame_opts = Opts} = Conn) ->
    described(Fields, maps:get(decode_opts, Opts, undefined), Conn);
noted({command_complete, _Tag}, #conn{frame_opts = #{decode_opts := _} = Opts} = Conn) ->
    Conn#conn{frame_opts = maps:remove(decoder, Opts)};
noted(_Message, Conn) ->
    Conn.

-spec described(
    [minato_protocol:field()], minato_protocol:opts() | undefined, conn()
) -> conn().
described(_Fields, undefined, Conn) ->
    Conn;
described(Fields, DecodeOpts, #conn{frame_opts = Opts} = Conn) ->
    Conn#conn{frame_opts = Opts#{decoder => minato_protocol:decoder(Fields, DecodeOpts)}}.

-spec budget(conn(), timeout()) -> timeout().
budget(#conn{deadline = infinity}, Timeout) ->
    Timeout;
budget(#conn{deadline = Deadline}, Timeout) ->
    remaining(Deadline - erlang:monotonic_time(millisecond), Timeout).

-spec remaining(integer(), timeout()) -> timeout().
remaining(Left, _Timeout) when Left =< 0 -> 0;
remaining(Left, infinity) -> Left;
remaining(Left, Timeout) when Left < Timeout -> Left;
remaining(_Left, Timeout) -> Timeout.

-spec expired(conn(), timeout()) -> {ok, minato_protocol:backend(), conn()} | {error, error()}.
expired(#conn{deadline = infinity}, _Timeout) ->
    {error, {socket, timeout}};
expired(#conn{cancelled = true}, _Timeout) ->
    {error, {socket, timeout}};
expired(#conn{grace = infinity} = Conn, Timeout) ->
    cancelling(Conn, infinity, Timeout);
expired(#conn{grace = Grace} = Conn, Timeout) ->
    cancelling(Conn, erlang:monotonic_time(millisecond) + Grace, Timeout).

-spec cancelling(conn(), integer() | infinity, timeout()) ->
    {ok, minato_protocol:backend(), conn()} | {error, error()}.
cancelling(Conn, Deadline, Timeout) ->
    _ = cancel(Conn),
    next(Conn#conn{cancelled = true, deadline = Deadline}, Timeout).

-doc """
Ask for the next bytes to arrive as a message instead of a read.

Exactly one message arrives and the owner asks again. That is the arrangement a
process which has to wait for the server without a query outstanding needs -
`LISTEN` is the only one there is - because `next/1` blocks, and a process
blocked in a read answers nothing else.

`{active, once}` on the driver transport; on the socket transport a read that
either hands back what is already here, in which case the message is sent from
here, or registers this process for one `select`. Either way it is one message
to whoever called, which is why the connection comes back: what it is waiting
for is part of it.

The connection is unusable for `next/1` until the messages stop coming, and the
two must not be mixed on one connection.
""".
-spec activate(conn()) -> {ok, conn()} | {error, error()}.
%% Asking twice is asking for the same thing: one message. `{active, once}`
%% twice is harmless on the driver, but a second read on a socket handle is a
%% second operation on the same handle, which a completion system refuses
%% outright. A caller that re-activates on every subscriber - which is what a
%% listener does - would otherwise work on POSIX and not on Windows.
activate(#conn{transport = minato_socket, waiting = Waiting} = Conn) when Waiting =/= undefined ->
    {ok, Conn};
activate(#conn{transport = minato_socket} = Conn) ->
    case minato_socket:activate(handle(Conn)) of
        {ok, Data} -> {ok, delivered(Conn, Data)};
        {waiting, Waiting} -> {ok, Conn#conn{waiting = Waiting}};
        {error, Reason} -> {error, {socket, Reason}}
    end;
activate(#conn{transport = Transport, socket = Socket} = Conn) ->
    case options(Transport, Socket, [{active, once}]) of
        ok -> {ok, Conn};
        {error, Reason} -> {error, Reason}
    end.

-spec delivered(conn(), binary()) -> conn().
delivered(#conn{socket = Socket} = Conn, Data) ->
    self() ! {minato_socket, Socket, Data},
    Conn#conn{waiting = undefined}.

-doc """
Go back to reading, after `activate/1`.

Whatever the socket already delivered to the mailbox is taken back into the
buffer, because those bytes have left the socket and `next/1` would otherwise
wait for bytes it already has. A connection that has been switched back can be
read with `next/1` as usual.

Bytes that were waited for but never arrived are not lost on the socket
transport: cancelling the wait drops the message, not the socket's own buffer,
so the next `next/1` reads them.
""".
-spec deactivate(conn()) -> {ok, conn()} | {error, error()}.
deactivate(#conn{transport = minato_socket, waiting = undefined} = Conn) ->
    {ok, flushed(Conn)};
deactivate(#conn{transport = minato_socket, waiting = Waiting} = Conn) ->
    Settled = settled(Conn, minato_socket:cancel(handle(Conn), Waiting)),
    {ok, flushed(Settled#conn{waiting = undefined})};
deactivate(#conn{transport = Transport, socket = Socket} = Conn) ->
    case options(Transport, Socket, [{active, false}]) of
        ok -> {ok, flushed(Conn)};
        {error, Reason} -> {error, Reason}
    end.

-spec settled(conn(), ok | pending) -> conn().
settled(Conn, ok) ->
    Conn;
settled(#conn{socket = Socket, timeout = Timeout} = Conn, pending) ->
    receive
        {'$socket', Delivered, _Kind, _What} = Message when Delivered =:= Socket ->
            absorbed(Conn, Message)
    after Timeout ->
        Conn
    end.

-spec flushed(conn()) -> conn().
flushed(#conn{transport = Transport, socket = Socket, buffer = Buffer} = Conn) ->
    receive
        {Tag, Delivered, Data} when
            Tag =:= Transport, Delivered =:= Socket, is_binary(Data)
        ->
            flushed(Conn#conn{buffer = <<Buffer/binary, Data/binary>>});
        {'$socket', Delivered, _Kind, _What} = Message when Delivered =:= Socket ->
            flushed(absorbed(Conn, Message))
    after 0 ->
        Conn
    end.

-spec absorbed(conn(), term()) -> conn().
absorbed(
    #conn{buffer = Buffer} = Conn, {'$socket', _Socket, completion, {_Handle, {ok, Data}}}
) when
    is_binary(Data)
->
    Conn#conn{buffer = <<Buffer/binary, Data/binary>>};
absorbed(Conn, _Nothing_to_take) ->
    Conn.

-doc """
Turn a socket message into the protocol messages it carried.

For a connection under `activate/1`. Anything that is not this connection's
socket answers `ignore`, so an owner with other messages of its own can pass
everything through.

`{closed, Reason}` is the socket going away, and there is no connection in it:
the socket is gone, and what is left of the buffer belongs to a message that
will never finish arriving.
""".
-spec handle_message(conn(), term()) ->
    {messages, [minato_protocol:backend()], conn()} | {closed, term()} | ignore.
handle_message(#conn{transport = gen_tcp, socket = Socket} = Conn, {tcp, Socket, Data}) when
    is_binary(Data)
->
    arrived(Conn, Data);
handle_message(#conn{transport = ssl, socket = Socket} = Conn, {ssl, Socket, Data}) when
    is_binary(Data)
->
    arrived(Conn, Data);
handle_message(#conn{transport = minato_socket, socket = Socket} = Conn, {Tag, Socket, Data}) when
    Tag =:= minato_socket, is_binary(Data)
->
    arrived(Conn#conn{waiting = undefined}, Data);
handle_message(
    #conn{transport = minato_socket, socket = Socket, waiting = {select_info, _Tag, Handle}} = Conn,
    {'$socket', Socket, select, Handle}
) ->
    readable(Conn#conn{waiting = undefined});
handle_message(
    #conn{
        transport = minato_socket, socket = Socket, waiting = {completion_info, _Tag, Handle}
    } = Conn,
    {'$socket', Socket, completion, {Handle, {ok, Data}}}
) when is_binary(Data) ->
    arrived(Conn#conn{waiting = undefined}, Data);
handle_message(
    #conn{transport = minato_socket, socket = Socket, waiting = {completion_info, _Tag, Handle}},
    {'$socket', Socket, completion, {Handle, {error, Reason}}}
) ->
    {closed, Reason};
%% The wait can also end with the machine taking it away rather than answering
%% it: a peer that closes while a read is outstanding aborts it on Windows
%% instead of completing it with an error. Ignoring that leaves an owner waiting
%% on a socket that will never speak again, which is a listener that never
%% reconnects.
handle_message(
    #conn{transport = minato_socket, socket = Socket, waiting = {completion_info, _Tag, Handle}},
    {'$socket', Socket, abort, {Handle, Reason}}
) ->
    {closed, Reason};
handle_message(
    #conn{transport = minato_socket, socket = Socket, waiting = {select_info, _Tag, Handle}},
    {'$socket', Socket, abort, {Handle, Reason}}
) ->
    {closed, Reason};
handle_message(#conn{transport = gen_tcp, socket = Socket}, {tcp_closed, Socket}) ->
    {closed, closed};
handle_message(#conn{transport = gen_tcp, socket = Socket}, {tcp_error, Socket, Reason}) ->
    {closed, Reason};
handle_message(#conn{transport = ssl, socket = Socket}, {ssl_closed, Socket}) ->
    {closed, closed};
handle_message(#conn{transport = ssl, socket = Socket}, {ssl_error, Socket, Reason}) ->
    {closed, Reason};
handle_message(_Conn, _Message) ->
    ignore.

-spec readable(conn()) ->
    {messages, [minato_protocol:backend()], conn()} | {closed, term()}.
readable(Conn) ->
    case minato_socket:activate(handle(Conn)) of
        {ok, Data} -> arrived(Conn, Data);
        {waiting, Waiting} -> {messages, [], Conn#conn{waiting = Waiting}};
        {error, closed} -> {closed, closed};
        {error, Reason} -> {closed, Reason}
    end.

-spec arrived(conn(), binary()) -> {messages, [minato_protocol:backend()], conn()}.
arrived(#conn{buffer = Buffer, pending = Pending, frame_opts = FrameOpts} = Conn, Data) ->
    {Messages, Rest} = minato_protocol:frame(<<Buffer/binary, Data/binary>>, FrameOpts),
    Read = Conn#conn{buffer = Rest, pending = []},
    {messages, Pending ++ Messages, noticed(Pending ++ Messages, Read)}.

-spec noticed([minato_protocol:backend()], conn()) -> conn().
noticed([], Conn) -> Conn;
noticed([Message | Rest], Conn) -> noticed(Rest, noted(Message, Conn)).

-spec options(transport(), socket(), [{atom(), term()}]) -> ok | {error, error()}.
options(Transport, Socket, Opts) ->
    Module = options_module(Transport),
    case Module:setopts(Socket, Opts) of
        ok -> ok;
        {error, Reason} -> {error, {socket, Reason}}
    end.

-spec options_module(transport()) -> inet | ssl | minato_socket.
options_module(gen_tcp) -> inet;
options_module(minato_socket) -> minato_socket;
options_module(ssl) -> ssl.

-doc """
What this connection has parsed on the server under this SQL, or `undefined`.

The value is whatever the query layer put there, which is why it is untyped
here: the connection keeps statements without knowing what a statement is.

The cache belongs to the connection because the statement does: a name is
meaningful only to the session that parsed it, so a cache anywhere else would
hand out names another session does not have.
""".
-spec recall(conn(), binary()) -> dynamic().
recall(#conn{statements = Statements}, Sql) ->
    maps:get(Sql, Statements, undefined).

-doc """
Keep a parsed statement under its SQL, if there is room.

Room is `claim/1`'s to give: a connection that has handed out every name it is
allowed answers `undefined` there, and the caller runs the statement unnamed. An
unbounded workload therefore gets the uncached path rather than an unbounded
pile of parsed statements in the backend.
""".
-spec remember(conn(), binary(), term()) -> conn().
remember(#conn{statements = Statements} = Conn, Sql, Statement) ->
    Conn#conn{statements = Statements#{Sql => Statement}}.

-doc """
Take the next statement name this connection has room for, or `undefined`.

Names never repeat, even after `forget/2`, because the statement a forgotten
name refers to may still be parsed on the server, and parsing a second one under
the same name is an error rather than a replacement.

The name carries a random per-connection prefix, so it is unique to this
connection rather than to a position in a sequence. A bare counter is only
unique *within* one connection, which is enough exactly as long as one
connection means one backend - and behind a transaction pooler it does not.
PgBouncer and friends multiplex many connections onto few backends, so two
connections both counting from zero hand the same backend `minato_30` twice and
the second one is refused with `42P05`, `prepared statement already exists`.

That failure is vicious in the field: which query dies depends on which server
connection the pooler handed out, so it looks random, it moves between
deployments sharing a pooler, and it clears and returns on its own. It cost a
real production investigation (Taure/minato#40, widgrensit/asobi#419). Eight
random bytes make it impossible instead of unlikely - a counter that only has
to be unique per connection stays a counter, and the prefix does the rest.
""".
-spec claim(conn()) -> {binary() | undefined, conn()}.
claim(#conn{prepared = Prepared, limit = Limit} = Conn) when Prepared >= Limit ->
    {undefined, Conn};
claim(#conn{prefix = Prefix, prepared = Prepared} = Conn) ->
    Name = <<"minato_", Prefix/binary, "_", (integer_to_binary(Prepared))/binary>>,
    {Name, Conn#conn{prepared = Prepared + 1}}.

-doc """
Drop what was kept under this SQL.

For a statement the server has stopped accepting, which is what a schema change
under a cached plan looks like.
""".
-spec forget(conn(), binary()) -> conn().
forget(#conn{statements = Statements} = Conn, Sql) ->
    Conn#conn{statements = maps:remove(Sql, Statements)}.

-doc "How many statements this connection is keeping, and how many names it may claim.".
-spec statements(conn()) -> {non_neg_integer(), non_neg_integer()}.
statements(#conn{statements = Statements, limit = Limit}) ->
    {map_size(Statements), Limit}.

-doc "Every parameter the server has reported, by name.".
-spec parameters(conn()) -> #{binary() => binary()}.
parameters(#conn{parameters = Parameters}) ->
    Parameters.

-doc """
One reported parameter, or `undefined`.

`server_version`, `client_encoding` and `integer_datetimes` are always among
them; which others a server volunteers is the server's choice.
""".
-spec parameter(conn(), binary()) -> binary() | undefined.
parameter(#conn{parameters = Parameters}, Name) ->
    maps:get(Name, Parameters, undefined).

-doc """
What the server last said about the transaction on this connection.

Taken from the status byte of every `ReadyForQuery` as it is read, so it is only
as current as the last message the caller read. `failed` is a transaction in
which a statement has already errored, and everything further is rejected until
it is rolled back.
""".
-spec transaction_status(conn()) -> minato_protocol:transaction_status().
transaction_status(#conn{status = Status}) ->
    Status.

-doc "The key `cancel/1` needs, for a caller that wants to cancel from elsewhere.".
-spec backend_key(conn()) -> key() | undefined.
backend_key(#conn{key = Key}) ->
    Key.

-doc """
How long this connection has been open, in milliseconds.

For a pool deciding whether to keep lending it. A connection to PostgreSQL
itself can live for months; one that goes through a proxy, a load balancer or a
NAT is on a clock somebody else set, and finding out where that clock ran out
by having a query fail is the expensive way.
""".
-spec age(conn()) -> non_neg_integer().
age(#conn{opened = Opened}) ->
    erlang:monotonic_time(millisecond) - Opened.

-doc """
Give the statement that runs next this long, then cancel it.

A read timeout on its own can only end the wait, not the statement: the server
carries on running the query, and the connection is left with an answer coming
that nobody is reading, which makes it fit for closing and nothing else. A
deadline sends `CancelRequest` when it expires and then goes on reading, so what
arrives is the server's own `57014` and the `ReadyForQuery` after it. A
cancelled statement therefore comes back as an ordinary failed statement with
the connection still usable, which is the difference between a slow query
costing one query and costing a connection.

The cancelled statement gets `cancel_timeout` to acknowledge it. A server that
does not answer even that has stopped talking, and the connection really is
finished: `{error, {socket, timeout}}`, with no connection handed back.

It lasts until it is cleared with `infinity`, which the query layer does before
handing a connection back, so a deadline belongs to one call rather than to the
connection. It covers everything that call does, including the `Describe` round
trip a first-time statement needs, because a caller asking for 300 milliseconds
means the answer, not one leg of it.
""".
-spec deadline(conn(), timeout()) -> conn().
deadline(Conn, infinity) ->
    Conn#conn{deadline = infinity, cancelled = false};
deadline(Conn, Timeout) ->
    Conn#conn{deadline = erlang:monotonic_time(millisecond) + Timeout, cancelled = false}.

-doc "The per read timeout this connection was opened with.".
-spec timeout(conn()) -> timeout().
timeout(#conn{timeout = Timeout}) ->
    Timeout.

-doc """
The same connection with a different read timeout.

For work that should be given less time than the connection's own budget - a
health check that has to answer inside a probe interval - or more, for a query
that is known to be slow. The change lasts as long as the connection term the
caller keeps.
""".
-spec with_timeout(conn(), timeout()) -> conn().
with_timeout(Conn, Timeout) ->
    Conn#conn{timeout = Timeout}.

%%----------------------------------------------------------------------
%% Opening
%%----------------------------------------------------------------------

-spec secure(plain(), socket(), inet:socket_address() | inet:hostname(), timeout(), opts()) ->
    {ok, conn()} | {error, error()}.
secure(Transport, Socket, Host, Timeout, Opts) ->
    case maps:get(ssl, Opts, false) of
        false ->
            start(new(Transport, Socket, Opts), Opts);
        true ->
            case upgrade(Transport, Socket, Host, Timeout, Opts) of
                {ok, Upgraded} -> start(new(ssl, Upgraded, Opts), Opts);
                {error, Reason} -> {error, Reason}
            end
    end.

-spec upgrade(plain(), socket(), inet:socket_address() | inet:hostname(), timeout(), opts()) ->
    {ok, ssl:sslsocket()} | {error, error()}.
upgrade(Transport, Socket, Host, Timeout, Opts) ->
    case Transport:send(Socket, minato_protocol:encode(ssl_request)) of
        ok -> negotiate(Transport, Socket, Host, Timeout, Opts);
        {error, Reason} -> closing(Transport, Socket, {socket, Reason})
    end.

-spec negotiate(plain(), socket(), inet:socket_address() | inet:hostname(), timeout(), opts()) ->
    {ok, ssl:sslsocket()} | {error, error()}.
negotiate(Transport, Socket, Host, Timeout, Opts) ->
    case Transport:recv(Socket, 1, Timeout) of
        {ok, Answer} when is_binary(Answer) ->
            answered(minato_protocol:ssl_response(Answer), Transport, Socket, Host, Timeout, Opts);
        {error, Reason} ->
            closing(Transport, Socket, {socket, Reason})
    end.

-spec answered(
    {ok, accepted | rejected | error_response, binary()} | incomplete,
    plain(),
    socket(),
    inet:socket_address() | inet:hostname(),
    timeout(),
    opts()
) -> {ok, ssl:sslsocket()} | {error, error()}.
answered({ok, accepted, _Rest}, Transport, Socket, Host, Timeout, Opts) ->
    case upgraded(Socket, tls_options(Host, Opts), Timeout) of
        {ok, Upgraded} -> {ok, Upgraded};
        {error, Reason} -> closing(Transport, Socket, {tls, Reason})
    end;
answered({ok, _Refused, _Rest}, Transport, Socket, _Host, _Timeout, _Opts) ->
    closing(Transport, Socket, tls_refused);
answered(incomplete, Transport, Socket, _Host, _Timeout, _Opts) ->
    closing(Transport, Socket, {socket, closed}).

-spec handle(conn()) -> minato_socket:socket().
handle(#conn{socket = Socket}) ->
    Socket.

-spec upgraded(socket(), [ssl:tls_client_option()], timeout()) ->
    {ok, ssl:sslsocket()} | {error, term()}.
upgraded(Socket, Options, Timeout) ->
    ssl:connect(Socket, Options, Timeout).

-spec new(transport(), socket(), opts()) -> conn().
new(Transport, Socket, Opts) ->
    #conn{
        transport = Transport,
        socket = Socket,
        binding = binding(Transport, Socket),
        opened = erlang:monotonic_time(millisecond),
        timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
        grace = maps:get(cancel_timeout, Opts, ?DEFAULT_CANCEL_TIMEOUT),
        limit = maps:get(prepared_statements, Opts, ?DEFAULT_STATEMENTS),
        prefix = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
        frame_opts = maps:get(frame_opts, Opts, #{}),
        opts = maps:remove(password, Opts)
    }.

-spec start(conn(), opts()) -> {ok, conn()} | {error, error()}.
start(Conn, Opts) ->
    User = maps:get(user, Opts),
    Startup = {startup, startup_parameters(User, Opts)},
    case send(Conn, Startup) of
        ok -> guarded(Conn, credentials(Conn, User, Opts));
        {error, Reason} -> closing(Conn, Reason)
    end.

-spec startup_parameters(binary(), opts()) -> #{binary() => binary()}.
startup_parameters(User, Opts) ->
    Given = maps:get(parameters, Opts, #{}),
    Defaults = #{~"client_encoding" => ~"UTF8", ~"DateStyle" => ~"ISO, MDY"},
    Base = #{~"user" => User, ~"database" => maps:get(database, Opts, User)},
    maps:merge(maps:merge(Defaults, Given), Base).

-spec credentials(conn(), binary(), opts()) -> minato_auth:credentials().
credentials(#conn{transport = Transport, binding = Hash}, User, Opts) ->
    bound(secret(User, Opts), Hash, maps:get(channel_binding, Opts, prefer(Transport))).

-spec secret(binary(), opts()) -> minato_auth:credentials().
secret(User, Opts) ->
    case maps:get(password, Opts, undefined) of
        undefined -> #{user => User};
        Password when is_function(Password, 0) -> #{user => User, password => Password()};
        Password -> #{user => User, password => Password}
    end.

-spec bound(minato_auth:credentials(), binary() | undefined, minato_auth:channel_binding()) ->
    minato_auth:credentials().
bound(Credentials, undefined, Binding) ->
    Credentials#{channel_binding => Binding};
bound(Credentials, Hash, Binding) ->
    Credentials#{channel_binding => Binding, channel_binding_data => Hash}.

-spec prefer(transport()) -> minato_auth:channel_binding().
prefer(ssl) -> prefer;
prefer(gen_tcp) -> disable;
prefer(minato_socket) -> disable.

-doc """
The `tls-server-end-point` binding data for this connection, or `undefined`.

The hash of the server's certificate, taken with the hash the certificate was
signed with, which is what RFC 5929 defines and what PostgreSQL computes on its
side. SHA-1 and MD5 signatures are hashed with SHA-256 instead, because the
binding must not be weaker than the mechanism it is bound to.

There is nothing to bind to on a plain socket, so it is `undefined` there.
""".
-spec channel_binding(conn()) -> binary() | undefined.
channel_binding(#conn{binding = Hash}) ->
    Hash.

-spec binding(transport(), socket()) -> binary() | undefined.
binding(gen_tcp, _Socket) ->
    undefined;
binding(minato_socket, _Socket) ->
    undefined;
binding(ssl, Socket) ->
    case ssl:peercert(Socket) of
        {ok, Der} -> fingerprint(Der);
        {error, _Reason} -> undefined
    end.

-spec fingerprint(binary()) -> binary().
fingerprint(Der) ->
    Certificate = public_key:pkix_decode_cert(Der, otp),
    #'OTPCertificate'{signatureAlgorithm = #'SignatureAlgorithm'{algorithm = Oid}} = Certificate,
    {Digest, _Signature} = public_key:pkix_sign_types(Oid),
    crypto:hash(strengthened(Digest), Der).

-spec strengthened(atom()) -> crypto:sha2().
strengthened(sha224) -> sha224;
strengthened(sha384) -> sha384;
strengthened(sha512) -> sha512;
strengthened(_Weaker) -> sha256.

-spec guarded(conn(), minato_auth:credentials()) -> {ok, conn()} | {error, error()}.
guarded(Conn, Credentials) ->
    try
        authenticate(Conn, minato_auth:init(Credentials), false)
    catch
        Class:Reason:Stacktrace ->
            ok = close(Conn),
            reraise(Class, Reason, Stacktrace)
    end.

-spec reraise(error | exit | throw, term(), erlang:raise_stacktrace()) -> no_return().
reraise(Class, Reason, Stacktrace) ->
    erlang:raise(Class, Reason, Stacktrace),
    bad(Class, Reason, Stacktrace).

-spec authenticate(conn(), minato_auth:state(), boolean()) -> {ok, conn()} | {error, error()}.
authenticate(Conn, State, Asked) ->
    case next(Conn) of
        {ok, {error_response, Fields}, Read} ->
            closing(Read, {pgsql_error, Fields});
        {ok, {notice_response, _Fields}, Read} ->
            authenticate(Read, State, Asked);
        {ok, Message, Read} ->
            case permitted(Message, Read, Asked) of
                ok -> answer(Read, minato_auth:step(Message, State));
                {error, Reason} -> closing(Read, Reason)
            end;
        {error, Reason} ->
            closing(Conn, Reason)
    end.

-spec answer(conn(), minato_auth:step()) -> {ok, conn()} | {error, error()}.
answer(Conn, authenticated) ->
    settle(Conn);
answer(Conn, {continue, State}) ->
    authenticate(Conn, State, true);
answer(Conn, {send, Reply, State}) ->
    case send(Conn, Reply) of
        ok -> authenticate(Conn, State, true);
        {error, Reason} -> closing(Conn, Reason)
    end.

-spec settle(conn()) -> {ok, conn()} | {error, error()}.
settle(Conn) ->
    case next(Conn) of
        {ok, {parameter_status, Name, Value}, Read} ->
            settle(store(Read, Name, Value));
        {ok, {backend_key_data, Pid, Secret}, Read} ->
            settle(Read#conn{key = {Pid, Secret}});
        {ok, {notice_response, _Fields}, Read} ->
            settle(Read);
        {ok, {ready_for_query, _Status}, Read} ->
            {ok, Read};
        {ok, {error_response, Fields}, Read} ->
            closing(Read, {pgsql_error, Fields});
        {ok, Message, Read} ->
            ok = close(Read),
            bad(Message, unexpected_during_startup, undefined);
        {error, Reason} ->
            closing(Conn, Reason)
    end.

-spec store(conn(), binary(), binary()) -> conn().
store(#conn{parameters = Parameters} = Conn, Name, Value) ->
    Conn#conn{parameters = Parameters#{Name => Value}}.

%%----------------------------------------------------------------------
%% What the server is allowed to ask for
%%----------------------------------------------------------------------

-spec permitted(minato_protocol:backend(), conn(), boolean()) -> ok | {error, error()}.
permitted(Message, #conn{transport = Transport, opts = Opts}, Asked) ->
    case method(Message, Asked) of
        undefined -> ok;
        cleartext when Transport =/= ssl -> {error, cleartext_password_refused};
        Method -> allowed(Method, maps:get(auth, Opts, all_methods()))
    end.

-spec method(minato_protocol:backend(), boolean()) -> method() | undefined.
method(authentication_ok, false) -> none;
method(authentication_ok, true) -> undefined;
method(authentication_cleartext_password, _Asked) -> cleartext;
method({authentication_md5_password, _Salt}, _Asked) -> md5;
method({authentication_sasl, _Mechanisms}, _Asked) -> scram_sha_256;
method(_Message, _Asked) -> undefined.

-spec allowed(method(), [method()]) -> ok | {error, error()}.
allowed(Method, Methods) ->
    case lists:member(Method, Methods) of
        true -> ok;
        false -> {error, {auth_method_refused, Method}}
    end.

-spec all_methods() -> [method()].
all_methods() ->
    [scram_sha_256, md5, cleartext, none].

%%----------------------------------------------------------------------
%% Cancelling
%%----------------------------------------------------------------------

-spec cancel(
    plain(), socket(), inet:socket_address() | inet:hostname(), timeout(), key(), opts()
) -> ok | {error, error()}.
cancel(Transport, Socket, Host, Timeout, {Pid, Secret}, Opts) ->
    case secured(Transport, Socket, Host, Timeout, Opts) of
        {ok, Transport, Secured} ->
            Sent = write(Transport, Secured, minato_protocol:encode({cancel_request, Pid, Secret})),
            _ = Transport:close(Secured),
            Sent;
        {error, Reason} ->
            {error, Reason}
    end.

-spec secured(plain(), socket(), inet:socket_address() | inet:hostname(), timeout(), opts()) ->
    {ok, transport(), socket()} | {error, error()}.
secured(Transport, Socket, _Host, _Timeout, #{ssl := false}) ->
    {ok, Transport, Socket};
secured(Transport, Socket, Host, Timeout, #{ssl := true} = Opts) ->
    case upgrade(Transport, Socket, Host, Timeout, Opts) of
        {ok, Upgraded} -> {ok, ssl, Upgraded};
        {error, Reason} -> {error, Reason}
    end;
secured(Transport, Socket, _Host, _Timeout, _Opts) ->
    {ok, Transport, Socket}.

%%----------------------------------------------------------------------
%% The socket
%%----------------------------------------------------------------------

-spec socket_options(opts()) -> [gen_tcp:connect_option()].
socket_options(Opts) ->
    Given = maps:get(socket_options, Opts, []),
    Given ++
        [
            Option
         || Option <- [binary, {active, false}, {packet, raw}, {nodelay, true}],
            not given(Option, Given)
        ].

-spec given(term(), [term()]) -> boolean().
given(Option, Given) ->
    Key = key(Option),
    lists:any(fun(Candidate) -> key(Candidate) =:= Key end, Given).

-spec key(term()) -> term().
key(Option) when is_tuple(Option), tuple_size(Option) > 0 ->
    element(1, Option);
key(Option) ->
    Option.

-spec tls_options(inet:socket_address() | inet:hostname(), opts()) -> [ssl:tls_client_option()].
tls_options(Host, Opts) ->
    Given = maps:get(ssl_options, Opts, []),
    Given ++ [Option || Option <- tls_defaults(Host), not given(Option, Given)].

-spec tls_defaults(inet:socket_address() | inet:hostname()) -> [ssl:tls_client_option()].
tls_defaults(Host) ->
    Name = server_name(Host),
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {depth, ?DEFAULT_TLS_DEPTH},
        {server_name_indication, Name},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

-spec server_name(inet:socket_address() | inet:hostname()) -> string().
server_name(Host) when is_list(Host) ->
    Host;
server_name(Host) when is_atom(Host) ->
    atom_to_list(Host);
server_name({local, _Path} = Host) ->
    bad(server_name, tls_over_a_unix_socket, Host);
server_name(Host) ->
    case inet:ntoa(Host) of
        Name when is_list(Name) -> Name;
        {error, Reason} -> bad(server_name, Reason, Host)
    end.

-spec fill(conn(), timeout()) -> {ok, conn()} | {error, error()}.
fill(#conn{transport = Transport, socket = Socket, buffer = Buffer} = Conn, Timeout) ->
    case Transport:recv(Socket, 0, Timeout) of
        {ok, Bytes} -> {ok, Conn#conn{buffer = <<Buffer/binary, Bytes/binary>>}};
        {error, Reason} -> {error, {socket, Reason}}
    end.

-spec write(transport(), socket(), iodata()) -> ok | {error, error()}.
write(Transport, Socket, Bytes) ->
    case Transport:send(Socket, Bytes) of
        ok -> ok;
        {error, Reason} -> {error, {socket, Reason}}
    end.

-spec closing(conn(), error()) -> {error, error()}.
closing(Conn, Reason) ->
    ok = close(Conn),
    {error, Reason}.

-spec closing(transport(), socket(), error()) -> {error, error()}.
closing(Transport, Socket, Reason) ->
    _ = Transport:close(Socket),
    {error, Reason}.

-spec bad(term(), term(), term()) -> no_return().
bad(Message, Reason, Data) ->
    error({minato_conn, #{message => Message, reason => Reason, data => Data}}).
