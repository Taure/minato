-module(minato_socket).
-moduledoc """
The `m:socket` module behind the same calls `m:gen_tcp` answers.

Experimental, and not the default. `m:minato_conn` speaks to its transport
through `connect/4`, `send/2`, `recv/3`, `close/1`, `controlling_process/2` and
`setopts/2`, and this module answers all six on top of the socket NIFs so that
the transport can be chosen per connection with nothing else changing.

## Why

A send and a read through the inet driver cost about 323 reductions a round
trip: `m:prim_inet` monitors the port, serialises a reference, hands the bytes
to the driver and waits for a reply message. The same round trip through
`m:socket` costs about 97, because a NIF call is a function call.

The other half is the pool. A driver port has a connected process and only that
process may use it, so lending a connection out and taking it back is two
`controlling_process/2` calls, which cost about 389 reductions a query - more
than the query itself. A socket handle has an owner too, but only for how long
it lives; any process holding the handle can send and receive on it. Moving that
ownership is a NIF call rather than a port reassignment, and a pool that decided
a borrower's death should cost a reset rather than a connection could stop
moving it at all.

## What is different

`{active, once}` is not implemented. `m:socket` has no active mode; it has
`nowait` and a select token, which is a different shape and belongs with the
listener that needs it rather than in a compatibility shim. `setopts/2` refuses
it rather than pretending.

TLS is not here either. `m:ssl` wants an inet socket, so a connection asking
for both TLS and this transport is refused by `m:minato_conn` rather than
quietly getting one of the two.
""".

-export([connect/4, send/2, recv/3, close/1, controlling_process/2, setopts/2]).

%% eqWAlizer reads the eight words of an `inet:ip6_address()` as `integer()` and
%% the eight of a `socket:in6_addr()` as `0..65535`, so a v6 address that came
%% from `inet:getaddr/2` cannot be written into a `socket:sockaddr()` without
%% this. The v4 half of the same function checks.
-eqwalizer({nowarn_function, target/2}).

-doc "A socket handle. Unlike a port, it belongs to nobody.".
-type socket() :: socket:socket().

-export_type([socket/0]).

-doc """
Open a connection.

Takes the option list `m:gen_tcp` would take, so a caller does not have to know
which transport it got. `binary`, `{active, false}` and `{packet, raw}` are what
this module always does and are accepted and ignored; `{nodelay, Boolean}` and
`{buffer, _}` are the two that mean anything here, and anything else is refused
rather than silently dropped.
""".
-spec connect(
    inet:socket_address() | inet:hostname(), inet:port_number(), [term()], timeout()
) -> {ok, socket()} | {error, term()}.
connect(Host, Port, Opts, Timeout) ->
    case address(Host, Port) of
        {ok, {Domain, Address}} -> opened(Domain, Address, Opts, Timeout);
        {error, Reason} -> {error, Reason}
    end.

-doc """
Send every byte, or say why not.

A send with no deadline blocks until the whole of it has gone, but the call can
still answer with what is left rather than with `ok`, so what is left is sent.
""".
-spec send(socket(), iodata()) -> ok | {error, term()}.
send(Socket, Data) ->
    case socket:send(Socket, Data) of
        ok -> ok;
        {ok, Rest} -> send(Socket, Rest);
        {error, Reason} -> {error, Reason}
    end.

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

-doc "Set what can be set. `{active, _}` is refused; see the module note.".
-spec setopts(socket(), [term()]) -> ok | {error, term()}.
setopts(Socket, [{active, false} | Rest]) ->
    setopts(Socket, Rest);
setopts(_Socket, [{active, _Mode} | _Rest]) ->
    {error, active_mode_unsupported};
setopts(Socket, [{nodelay, Value} | Rest]) ->
    case socket:setopt(Socket, {tcp, nodelay}, Value) of
        ok -> setopts(Socket, Rest);
        {error, Reason} -> {error, Reason}
    end;
setopts(Socket, [_Ignored | Rest]) ->
    setopts(Socket, Rest);
setopts(_Socket, []) ->
    ok.

%%----------------------------------------------------------------------
%% Opening
%%----------------------------------------------------------------------

-spec opened(socket:domain(), socket:sockaddr(), [term()], timeout()) ->
    {ok, socket()} | {error, term()}.
opened(Domain, Address, Opts, Timeout) ->
    case socket:open(Domain, stream, tcp) of
        {ok, Socket} -> started(Socket, Address, Opts, Timeout);
        {error, Reason} -> {error, Reason}
    end.

-spec started(socket(), socket:sockaddr(), [term()], timeout()) ->
    {ok, socket()} | {error, term()}.
started(Socket, Address, Opts, Timeout) ->
    case socket:connect(Socket, Address, Timeout) of
        ok -> tuned(Socket, Opts);
        {error, Reason} -> failed(Socket, Reason)
    end.

-spec tuned(socket(), [term()]) -> {ok, socket()} | {error, term()}.
tuned(Socket, Opts) ->
    case setopts(Socket, Opts) of
        ok -> {ok, Socket};
        {error, Reason} -> failed(Socket, Reason)
    end.

-spec failed(socket(), term()) -> {error, term()}.
failed(Socket, Reason) ->
    ok = close(Socket),
    {error, Reason}.

-spec address(inet:socket_address() | inet:hostname(), inet:port_number()) ->
    {ok, {socket:domain(), socket:sockaddr()}} | {error, term()}.
address({local, Path}, _Port) ->
    {ok, {local, #{family => local, path => iolist_to_binary(Path)}}};
address(Host, Port) when is_list(Host); is_atom(Host) ->
    resolved(Host, Port);
address(Address, Port) ->
    {ok, target(Address, Port)}.

-spec resolved(inet:hostname(), inet:port_number()) ->
    {ok, {socket:domain(), socket:sockaddr()}} | {error, term()}.
resolved(Host, Port) ->
    case inet:getaddr(Host, inet) of
        {ok, Address} -> {ok, target(Address, Port)};
        {error, _Not_a_v4_address} -> resolved6(Host, Port)
    end.

-spec resolved6(inet:hostname(), inet:port_number()) ->
    {ok, {socket:domain(), socket:sockaddr()}} | {error, term()}.
resolved6(Host, Port) ->
    case inet:getaddr(Host, inet6) of
        {ok, Address} -> {ok, target(Address, Port)};
        {error, Reason} -> {error, Reason}
    end.

-spec target(inet:ip_address(), inet:port_number()) ->
    {socket:domain(), socket:sockaddr()}.
target({A, B, C, D}, Port) ->
    {inet, #{family => inet, addr => {A, B, C, D}, port => Port}};
target({A, B, C, D, E, F, G, H}, Port) ->
    {inet6, #{family => inet6, addr => {A, B, C, D, E, F, G, H}, port => Port}}.
