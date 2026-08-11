-module(minato_socket).
-moduledoc """
The `m:socket` module behind the same calls `m:gen_tcp` answers.

The default transport. `m:minato_conn` speaks to its transport through
`connect/4`, `send/2`, `recv/3`, `close/1`, `controlling_process/2` and
`setopts/2`, and this module answers all six on top of the socket NIFs so that
the transport can be chosen per connection with nothing else changing.
`transport => inet` goes back to `m:gen_tcp`.

## Why

A send and a read through the inet driver cost about 323 reductions a round
trip: the driver's own layer monitors the port, serialises a reference, hands
the bytes over and waits for a reply message. The same round trip through
`m:socket` costs about 97, because a NIF call is a function call.

The other half is the pool. A driver port has a connected process and only that
process may use it, so lending a connection out and taking it back is two
`controlling_process/2` calls, which cost about 389 reductions a query - more
than the query itself. A socket handle has an owner too, but only for how long
it lives; any process holding the handle can send and receive on it. Moving that
ownership is a NIF call rather than a port reassignment, and a pool that decided
a borrower's death should cost a reset rather than a connection could stop
moving it at all.

## Waiting for bytes without reading

`m:socket` has no active mode, so `setopts/2` refuses `{active, once}` rather
than pretending. What it has instead is `activate/1`: a read that either hands
back what is already here or arranges one message for when there is something.
That is the same arrangement `{active, once}` is - exactly one message, and the
owner asks again - and it costs no process, because the message goes to whoever
made the call rather than to a reader spawned to forward it.

Windows completes reads rather than selecting on them: the wait answers with the
bytes in the message rather than with permission to go and read them. Both
shapes are here and `t:waiting/0` is either, because the difference belongs to
whoever reads the message, not to whoever waits.

## TLS

`ssl:connect/3` takes one of these handles, so a connection that asks for TLS
sends its `SSLRequest` through this module and hands the upgraded socket to
`m:ssl` exactly as the driver transport does. What comes back is an ordinary
`t:ssl:sslsocket/0`, so nothing below TLS is this module's business afterwards -
including the certificate hash SCRAM binds to.
""".

-export([connect/4, send/2, send/3, recv/3, close/1, controlling_process/2, setopts/2]).
-export([activate/1, cancel/2]).

%% eqWAlizer reads the eight words of an `inet:ip6_address()` as `integer()` and
%% the eight of a `socket:in6_addr()` as `0..65535`, so a v6 address that came
%% from `inet:getaddr/2` cannot be written into a `socket:sockaddr()` without
%% this. The v4 half of the same function checks.
-eqwalizer({nowarn_function, target/2}).

%% `socket:send/3` answers `{ok, RestData}` where `RestData` is the tail of the
%% `iodata()` that went in, but its spec says `term()`, so eqWAlizer reads a
%% list tail as a bare list rather than as an iolist.
-eqwalizer({nowarn_function, sending/3}).

-doc """
A socket handle.

Unlike a port it is not owned for the purpose of using it: any process holding
one can read and write. It is owned for the purpose of living, and is closed
when that process terminates.
""".
-type socket() :: socket:socket().

-doc """
What `activate/1` is waiting on, which is what `cancel/2` drops.

A select token where the machine says the socket is readable, a completion token
where it hands over the bytes.
""".
-type waiting() :: socket:select_info() | socket:completion_info().

-export_type([socket/0, waiting/0]).

-doc """
Open a connection.

Takes the option list `m:gen_tcp` would take, so a caller does not have to know
which transport it got.

Three kinds of option, and the difference is what the option decides.

**Read before connecting**, because that is the only time they can be honoured:
`inet` and `inet6` choose which address a hostname resolves to; `{ip, _}` and
`{port, _}` choose the local end to bind, which is how a multi homed host picks
the interface the server sees.

**Set on the socket**: `{nodelay, _}`, `{keepalive, _}`, `{recbuf, _}`,
`{sndbuf, _}`, `{priority, _}`, `{reuseaddr, _}`, `{tos, _}`,
`{bind_to_device, _}` and `{linger, _}`. `{send_timeout, _}` and
`{send_timeout_close, _}` belong here in spirit but are read by `m:minato_conn`
and applied to `send/3`, because there is no driver underneath to hold them.

**Accepted and ignored**, because this module already does them or the thing
they configure does not exist here: `binary`, `{mode, binary}`,
`{active, false}`, `{packet, raw}`, `{buffer, _}`, `{delay_send, _}`,
`{high_watermark, _}`, `{low_watermark, _}`, `{exit_on_close, _}` and
`{show_econnreset, _}`. The last five configure a port's send queue and a
port's reporting, and there is no port here.

Anything else is refused rather than silently dropped: this is the default
transport, and an option that did something through the driver must not quietly
stop doing it here.

The lists above are what callers pass, not what a socket happens to be settable
to. Getting that backwards is how `inet` came to be refused, which broke every
deployment that names its address family - so when a real caller passes
something missing, the answer is to add it here rather than to tell them to
stop.
""".
-spec connect(
    inet:socket_address() | inet:hostname(),
    inet:port_number(),
    [gen_tcp:connect_option()],
    timeout()
) -> {ok, socket()} | {error, term()}.
connect(Host, Port, Opts, Timeout) ->
    case address(Host, Port, family(Opts)) of
        {ok, {Domain, Address}} -> opened(Domain, Address, Opts, Timeout);
        {error, Reason} -> {error, Reason}
    end.

-doc false.
-spec family([gen_tcp:connect_option()]) -> inet | inet6 | any.
%% `inet` and `inet6` are not options a socket is set to, which is why asking
%% `setopt/2` about them was the wrong question: they choose which address a
%% name resolves to, and the driver reads them before it connects. `any` is
%% both, in the order `resolved/3` tries them.
family([inet | _Rest]) -> inet;
family([inet6 | _Rest]) -> inet6;
family([_Other | Rest]) -> family(Rest);
family([]) -> any.

-doc """
Send every byte, or say why not.

A send with no deadline blocks until the whole of it has gone, but the call can
still answer with what is left rather than with `ok`, so what is left is sent.
""".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send(Socket, Data) ->
    send(Socket, Data, infinity).

-doc """
Send every byte, or say why not, within `Timeout`.

The deadline is for the whole of it rather than for each attempt, because a
peer that accepts one byte per attempt would otherwise never time out. What is
left when the deadline passes is not sent and not retried: a `Query` the server
has half of is a connection that has to be given up on, which is what
`send_timeout` is for.
""".
-spec send(socket(), iodata(), timeout()) -> ok | {error, term()}.
send(Socket, Data, infinity) ->
    sent(Socket, Data, infinity);
send(Socket, Data, Timeout) ->
    sent(Socket, Data, erlang:monotonic_time(millisecond) + Timeout).

-type written() :: ok | {ok, iodata()} | {error, term() | {term(), iodata()}}.

%% `socket:send/3` answers more shapes than its spec narrows to, so the union
%% this module matches on is stated here rather than inferred. What comes back
%% as `RestData` is the tail of the `iodata()` that went in, which eqWAlizer
%% reads as a bare list because the spec says `term()`.
-spec sending(socket(), iodata(), timeout()) -> written().
sending(Socket, Data, Timeout) ->
    case socket:send(Socket, Data, Timeout) of
        ok -> ok;
        {ok, Rest} when is_binary(Rest); is_list(Rest) -> {ok, Rest};
        {error, Reason} -> {error, Reason}
    end.

-spec sent(socket(), iodata(), integer() | infinity) -> ok | {error, term()}.
sent(Socket, Data, Deadline) ->
    case remaining(Deadline) of
        0 -> {error, timeout};
        Left -> written(Socket, Data, Deadline, sending(Socket, Data, Left))
    end.

-spec written(socket(), iodata(), integer() | infinity, written()) -> ok | {error, term()}.
written(_Socket, _Data, _Deadline, ok) -> ok;
written(Socket, _Data, Deadline, {ok, Rest}) -> sent(Socket, Rest, Deadline);
written(_Socket, _Data, _Deadline, {error, {timeout, _Rest}}) -> {error, timeout};
written(_Socket, _Data, _Deadline, {error, {Reason, _Rest}}) -> {error, Reason};
written(_Socket, _Data, _Deadline, {error, Reason}) -> {error, Reason}.

-spec remaining(integer() | infinity) -> timeout().
remaining(Deadline) when is_integer(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 -> Left;
        _Passed -> 0
    end;
remaining(infinity) ->
    infinity.

-doc """
Read `Length` bytes, or whatever has arrived when `Length` is 0.

A timeout of 0 is the non-blocking probe `minato_conn:usable/1` makes, and
answers `{error, timeout}` when nothing is waiting.
""".
-spec recv(socket(), non_neg_integer(), timeout()) -> {ok, binary()} | {error, term()}.
recv(Socket, Length, Timeout) ->
    case socket:recv(Socket, Length, Timeout) of
        {ok, Data} -> {ok, Data};
        {error, {timeout, _Partial}} -> {error, timeout};
        {error, Reason} -> {error, Reason}
    end.

-doc "Close the socket.".
-spec close(socket()) -> ok.
close(Socket) ->
    _ = socket:close(Socket),
    ok.

-doc """
Hand the socket's lifetime to another process.

A socket handle has an owner, but only for how long it lives: it is closed when
that process terminates. Reading and writing need no ownership at all, which a
port does, so lending a connection out could stop moving ownership entirely and
let the lender keep it - a borrower that dies would then cost a connection reset
rather than a connection. That belongs to whoever lends, so this answers the
call `m:gen_tcp` answers, and answers it with one NIF rather than a port
reassignment.
""".
-spec controlling_process(socket(), pid()) -> ok | {error, term()}.
controlling_process(Socket, Pid) ->
    socket:setopt(Socket, {otp, controlling_process}, Pid).

-doc """
Take the bytes that are here, or arrange for a message when there are some.

`{waiting, Waiting}` means one message will be sent to the caller, and which
message depends on how the machine waits:

- `{'$socket', Socket, select, Handle}` says the socket is readable and the
  bytes are still in it, so reading is this call again. A wakeup with nothing
  behind it therefore re-arms rather than being mistaken for data, which is why
  there is one function here and not an arm and a take.
- `{'$socket', Socket, completion, {Handle, {ok, Data}}}` carries the bytes,
  and calling again would ask for the next ones.

The `Handle` is the one inside `Waiting` either way. The waiting is registered
for the calling process, so whoever wants the message has to make the call.
""".
-spec activate(socket()) -> {ok, binary()} | {waiting, waiting()} | {error, term()}.
activate(Socket) ->
    try socket:recv(Socket, 0, nowait) of
        {ok, Data} -> {ok, Data};
        {select, Select} -> {waiting, Select};
        {completion, Completion} -> {waiting, Completion};
        {error, Reason} -> {error, Reason}
    catch
        %% A socket whose read was aborted from under it has no state left to
        %% read in, and Windows raises rather than answering. It is closed, and
        %% the caller asked a question that has an answer.
        error:{invalid, state} -> {error, closed}
    end.

-doc """
Drop a waiting arranged by `activate/1`.

`pending` means it was too late and the message is on its way, which matters
where the message carries the bytes: dropping it there would drop them. `ok`
means nothing is coming.

Bytes still in the socket are not lost either way. The next `recv/3` reads them.
""".
-spec cancel(socket(), waiting()) -> ok | pending.
cancel(Socket, Waiting) ->
    case socket:cancel(Socket, Waiting) of
        ok -> ok;
        {error, _Too_late} -> pending
    end.

-doc """
Set what can be set.

`{active, _}` is refused; see the module note. So is an option this module has
no answer for, because the alternative is a connection that was configured and
silently was not.
""".
-spec setopts(socket(), [term()]) -> ok | {error, term()}.
setopts(Socket, [Option | Rest]) ->
    case setopt(Socket, Option) of
        ok -> setopts(Socket, Rest);
        {error, Reason} -> {error, Reason}
    end;
setopts(_Socket, []) ->
    ok.

-spec setopt(socket(), term()) -> ok | {error, term()}.
setopt(_Socket, {active, false}) ->
    ok;
setopt(_Socket, {active, _Mode}) ->
    {error, active_mode_unsupported};
setopt(Socket, {nodelay, Value}) ->
    socket:setopt(Socket, {tcp, nodelay}, Value);
setopt(Socket, {keepalive, Value}) ->
    socket:setopt(Socket, {socket, keepalive}, Value);
setopt(Socket, {recbuf, Value}) ->
    socket:setopt(Socket, {socket, rcvbuf}, Value);
setopt(Socket, {sndbuf, Value}) ->
    socket:setopt(Socket, {socket, sndbuf}, Value);
setopt(Socket, {priority, Value}) ->
    socket:setopt(Socket, {socket, priority}, Value);
setopt(Socket, {reuseaddr, Value}) ->
    socket:setopt(Socket, {socket, reuseaddr}, Value);
setopt(Socket, {tos, Value}) ->
    socket:setopt(Socket, {ip, tos}, Value);
setopt(Socket, {bind_to_device, Value}) ->
    socket:setopt(Socket, {socket, bindtodevice}, Value);
setopt(Socket, {linger, {OnOff, Seconds}}) ->
    socket:setopt(Socket, {socket, linger}, #{onoff => OnOff, linger => Seconds});
setopt(_Socket, binary) ->
    ok;
setopt(_Socket, {mode, binary}) ->
    ok;
setopt(_Socket, {packet, raw}) ->
    ok;
setopt(_Socket, {packet, 0}) ->
    ok;
setopt(_Socket, {buffer, _Driver_side}) ->
    ok;
setopt(_Socket, inet) ->
    ok;
setopt(_Socket, inet6) ->
    ok;
setopt(_Socket, {ip, _Bound_before_connecting}) ->
    ok;
setopt(_Socket, {port, _Bound_before_connecting}) ->
    ok;
setopt(_Socket, {delay_send, _No_send_queue_here}) ->
    ok;
setopt(_Socket, {high_watermark, _No_send_queue_here}) ->
    ok;
setopt(_Socket, {low_watermark, _No_send_queue_here}) ->
    ok;
setopt(_Socket, {exit_on_close, _Not_a_port}) ->
    ok;
setopt(_Socket, {show_econnreset, _Driver_reporting}) ->
    ok;
setopt(_Socket, {send_timeout, _Read_by_the_connection}) ->
    ok;
setopt(_Socket, {send_timeout_close, _Read_by_the_connection}) ->
    ok;
setopt(_Socket, Option) ->
    {error, {unsupported_socket_option, Option}}.

%%----------------------------------------------------------------------
%% Opening
%%----------------------------------------------------------------------

-spec opened(socket:domain(), socket:sockaddr(), [gen_tcp:connect_option()], timeout()) ->
    {ok, socket()} | {error, term()}.
opened(Domain, Address, Opts, Timeout) ->
    case socket:open(Domain, stream, tcp) of
        {ok, Socket} -> started(Socket, Address, Opts, Timeout);
        {error, Reason} -> {error, Reason}
    end.

-spec started(socket(), socket:sockaddr(), [gen_tcp:connect_option()], timeout()) ->
    {ok, socket()} | {error, term()}.
started(Socket, Address, Opts, Timeout) ->
    case bound(Socket, Address, local(Opts)) of
        ok -> connecting(Socket, Address, Opts, Timeout);
        {error, Reason} -> failed(Socket, Reason)
    end.

-doc false.
-spec bound(socket(), socket:sockaddr(), socket:sockaddr() | any | loopback) ->
    ok | {error, term()}.
%% Windows refuses to connect a socket that was never bound, and answers
%% `not_bound` rather than binding it for you. Binding to the wildcard is what
%% the driver does on every machine, and costs nothing where it was not needed.
%%
%% `{ip, _}` and `{port, _}` are the caller asking for a particular local end
%% instead, which a multi homed host uses to choose which interface the server
%% sees. They are read before the connect because that is when a bind is
%% possible at all.
bound(Socket, #{family := Family}, Local) when Family =:= inet; Family =:= inet6 ->
    socket:bind(Socket, Local);
bound(_Socket, _Address, _Local) ->
    ok.

-spec local([gen_tcp:connect_option()]) -> socket:sockaddr() | any | loopback.
local(Opts) ->
    bound_to(local(ip, Opts), local(port, Opts)).

-spec bound_to(inet:socket_address() | undefined, inet:port_number() | undefined) ->
    socket:sockaddr() | any | loopback.
bound_to(undefined, undefined) ->
    any;
bound_to(undefined, Port) ->
    #{family => inet, addr => any, port => Port};
bound_to(Address, undefined) ->
    local_address(Address, 0);
bound_to(Address, Port) ->
    local_address(Address, Port).

-spec local_address(inet:socket_address(), inet:port_number()) ->
    socket:sockaddr() | any | loopback.
local_address({local, Path}, _Port) ->
    #{family => local, path => iolist_to_binary(Path)};
local_address(any, Port) ->
    #{family => inet, addr => any, port => Port};
local_address(loopback, Port) ->
    #{family => inet, addr => loopback, port => Port};
local_address(Address, Port) ->
    {_Domain, Sockaddr} = target(Address, Port),
    Sockaddr.

-spec local
    (ip, [gen_tcp:connect_option()]) -> inet:socket_address() | undefined;
    (port, [gen_tcp:connect_option()]) -> inet:port_number() | undefined.
local(ip, [{ip, Address} | _Rest]) -> Address;
local(port, [{port, Port} | _Rest]) -> Port;
local(Name, [_Other | Rest]) -> local(Name, Rest);
local(_Name, []) -> undefined.

-spec connecting(socket(), socket:sockaddr(), [gen_tcp:connect_option()], timeout()) ->
    {ok, socket()} | {error, term()}.
connecting(Socket, Address, Opts, Timeout) ->
    case socket:connect(Socket, Address, Timeout) of
        ok -> tuned(Socket, Opts);
        {error, Reason} -> failed(Socket, Reason)
    end.

-spec tuned(socket(), [gen_tcp:connect_option()]) -> {ok, socket()} | {error, term()}.
tuned(Socket, Opts) ->
    case setopts(Socket, Opts) of
        ok -> {ok, Socket};
        {error, Reason} -> failed(Socket, Reason)
    end.

-spec failed(socket(), term()) -> {error, term()}.
failed(Socket, Reason) ->
    ok = close(Socket),
    {error, Reason}.

-spec address(inet:socket_address() | inet:hostname(), inet:port_number(), inet | inet6 | any) ->
    {ok, {socket:domain(), socket:sockaddr()}} | {error, term()}.
address({local, Path}, _Port, _Family) ->
    {ok, {local, #{family => local, path => iolist_to_binary(Path)}}};
address(Host, Port, Family) when is_list(Host); is_atom(Host) ->
    resolved(Host, Port, Family);
address(Address, Port, _Family) ->
    {ok, target(Address, Port)}.

-spec resolved(inet:hostname(), inet:port_number(), inet | inet6 | any) ->
    {ok, {socket:domain(), socket:sockaddr()}} | {error, term()}.
%% A name that has both an A and a AAAA record resolves to the v4 address unless
%% the caller said otherwise, which is what the driver does. A caller that said
%% `inet6` gets v6 or an error, never a quiet v4: a host reachable both ways is
%% exactly where a silent fallback would hide the fact that the option did
%% nothing.
resolved(Host, Port, inet6) ->
    resolved(Host, Port, inet6, fun(Reason) -> {error, Reason} end);
resolved(Host, Port, inet) ->
    resolved(Host, Port, inet, fun(Reason) -> {error, Reason} end);
resolved(Host, Port, any) ->
    resolved(Host, Port, inet, fun(_Not_a_v4_address) -> resolved(Host, Port, inet6) end).

-type resolution() :: {ok, {socket:domain(), socket:sockaddr()}} | {error, term()}.

-spec resolved(
    inet:hostname(), inet:port_number(), inet | inet6, fun((term()) -> resolution())
) -> resolution().
resolved(Host, Port, Family, Otherwise) ->
    case inet:getaddr(Host, Family) of
        {ok, Address} -> {ok, target(Address, Port)};
        {error, Reason} -> Otherwise(Reason)
    end.

-spec target(inet:ip_address(), inet:port_number()) ->
    {socket:domain(), socket:sockaddr()}.
target({A, B, C, D}, Port) ->
    {inet, #{family => inet, addr => {A, B, C, D}, port => Port}};
target({A, B, C, D, E, F, G, H}, Port) ->
    {inet6, #{family => inet6, addr => {A, B, C, D, E, F, G, H}, port => Port}}.
