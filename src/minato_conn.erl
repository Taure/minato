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
    activate/1,
    deactivate/1,
    handle_message/2,
    parameters/1,
    parameter/2,
    channel_binding/1,
    transaction_status/1,
    backend_key/1,
    timeout/1
]).

-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, 5432).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).
-define(DEFAULT_TIMEOUT, 15000).
-define(DEFAULT_TLS_DEPTH, 3).

-include_lib("public_key/include/public_key.hrl").

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
    frame_opts :: minato_protocol:frame_opts(),
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

`timeout` is the per read timeout and applies for the life of the connection.
`connect_timeout` covers the TCP connect and the TLS handshake.
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

-type transport() :: gen_tcp | ssl.
-type socket() :: gen_tcp:socket() | ssl:sslsocket().

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
    Host = maps:get(host, Opts, ?DEFAULT_HOST),
    Port = maps:get(port, Opts, ?DEFAULT_PORT),
    Timeout = maps:get(connect_timeout, Opts, ?DEFAULT_CONNECT_TIMEOUT),
    case gen_tcp:connect(Host, Port, socket_options(Opts), Timeout) of
        {ok, Socket} -> secure(Socket, Host, Timeout, Opts);
        {error, Reason} -> {error, {socket, Reason}}
    end.

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
    case gen_tcp:connect(Host, Port, socket_options(Opts), Timeout) of
        {ok, Socket} -> cancel(Socket, Host, Timeout, {Pid, Secret}, Opts);
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
            case fill(Conn, Timeout) of
                {ok, Filled} -> next(Filled, Timeout);
                {error, Reason} -> {error, Reason}
            end;
        {[Message | Rest], Remainder} ->
            Read = Conn#conn{buffer = Remainder, pending = Rest},
            {ok, Message, noted(Message, Read)}
    end.

-spec noted(minato_protocol:backend(), conn()) -> conn().
noted({ready_for_query, Status}, Conn) -> Conn#conn{status = Status};
noted(_Message, Conn) -> Conn.

-doc """
Ask for the next bytes to arrive as a message instead of a read.

`{active, once}` on the socket, so exactly one message arrives and the owner
asks again. That is the arrangement a process which has to wait for the server
without a query outstanding needs - `LISTEN` is the only one there is - because
`next/1` blocks, and a process blocked in a read answers nothing else.

The connection is unusable for `next/1` until the messages stop coming, and the
two must not be mixed on one connection.
""".
-spec activate(conn()) -> ok | {error, error()}.
activate(#conn{transport = Transport, socket = Socket}) ->
    options(Transport, Socket, [{active, once}]).

-doc """
Go back to reading, after `activate/1`.

`{active, false}` on the socket, and then whatever the socket already delivered
to the mailbox is taken back into the buffer, because those bytes have left the
socket and `next/1` would otherwise wait for bytes it already has. A connection
that has been switched back can be read with `next/1` as usual.
""".
-spec deactivate(conn()) -> {ok, conn()} | {error, error()}.
deactivate(#conn{transport = Transport, socket = Socket} = Conn) ->
    case options(Transport, Socket, [{active, false}]) of
        ok -> {ok, flushed(Conn)};
        {error, Reason} -> {error, Reason}
    end.

-spec flushed(conn()) -> conn().
flushed(#conn{transport = Transport, socket = Socket, buffer = Buffer} = Conn) ->
    receive
        {Tag, Delivered, Data} when
            Tag =:= Transport, Delivered =:= Socket, is_binary(Data)
        ->
            flushed(Conn#conn{buffer = <<Buffer/binary, Data/binary>>})
    after 0 ->
        Conn
    end.

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

-spec options_module(transport()) -> inet | ssl.
options_module(gen_tcp) -> inet;
options_module(ssl) -> ssl.

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

-doc "The per read timeout this connection was opened with.".
-spec timeout(conn()) -> timeout().
timeout(#conn{timeout = Timeout}) ->
    Timeout.

%%----------------------------------------------------------------------
%% Opening
%%----------------------------------------------------------------------

-spec secure(gen_tcp:socket(), inet:socket_address() | inet:hostname(), timeout(), opts()) ->
    {ok, conn()} | {error, error()}.
secure(Socket, Host, Timeout, Opts) ->
    case maps:get(ssl, Opts, false) of
        false ->
            start(new(gen_tcp, Socket, Opts), Opts);
        true ->
            case upgrade(Socket, Host, Timeout, Opts) of
                {ok, Upgraded} -> start(new(ssl, Upgraded, Opts), Opts);
                {error, Reason} -> {error, Reason}
            end
    end.

-spec upgrade(gen_tcp:socket(), inet:socket_address() | inet:hostname(), timeout(), opts()) ->
    {ok, ssl:sslsocket()} | {error, error()}.
upgrade(Socket, Host, Timeout, Opts) ->
    case gen_tcp:send(Socket, minato_protocol:encode(ssl_request)) of
        ok -> negotiate(Socket, Host, Timeout, Opts);
        {error, Reason} -> closing(gen_tcp, Socket, {socket, Reason})
    end.

-spec negotiate(gen_tcp:socket(), inet:socket_address() | inet:hostname(), timeout(), opts()) ->
    {ok, ssl:sslsocket()} | {error, error()}.
negotiate(Socket, Host, Timeout, Opts) ->
    case gen_tcp:recv(Socket, 1, Timeout) of
        {ok, Answer} when is_binary(Answer) ->
            answered(minato_protocol:ssl_response(Answer), Socket, Host, Timeout, Opts);
        {error, Reason} ->
            closing(gen_tcp, Socket, {socket, Reason})
    end.

-spec answered(
    {ok, accepted | rejected | error_response, binary()} | incomplete,
    gen_tcp:socket(),
    inet:socket_address() | inet:hostname(),
    timeout(),
    opts()
) -> {ok, ssl:sslsocket()} | {error, error()}.
answered({ok, accepted, _Rest}, Socket, Host, Timeout, Opts) ->
    case ssl:connect(Socket, tls_options(Host, Opts), Timeout) of
        {ok, Upgraded} -> {ok, Upgraded};
        {error, Reason} -> closing(gen_tcp, Socket, {tls, Reason})
    end;
answered({ok, _Refused, _Rest}, Socket, _Host, _Timeout, _Opts) ->
    closing(gen_tcp, Socket, tls_refused);
answered(incomplete, Socket, _Host, _Timeout, _Opts) ->
    closing(gen_tcp, Socket, {socket, closed}).

-spec new(transport(), socket(), opts()) -> conn().
new(Transport, Socket, Opts) ->
    #conn{
        transport = Transport,
        socket = Socket,
        binding = binding(Transport, Socket),
        timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
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
prefer(gen_tcp) -> disable.

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
    gen_tcp:socket(), inet:socket_address() | inet:hostname(), timeout(), key(), opts()
) -> ok | {error, error()}.
cancel(Socket, Host, Timeout, {Pid, Secret}, Opts) ->
    case secured(Socket, Host, Timeout, Opts) of
        {ok, Transport, Secured} ->
            Sent = write(Transport, Secured, minato_protocol:encode({cancel_request, Pid, Secret})),
            _ = Transport:close(Secured),
            Sent;
        {error, Reason} ->
            {error, Reason}
    end.

-spec secured(gen_tcp:socket(), inet:socket_address() | inet:hostname(), timeout(), opts()) ->
    {ok, transport(), socket()} | {error, error()}.
secured(Socket, Host, Timeout, Opts) ->
    case maps:get(ssl, Opts, false) of
        false ->
            {ok, gen_tcp, Socket};
        true ->
            case upgrade(Socket, Host, Timeout, Opts) of
                {ok, Upgraded} -> {ok, ssl, Upgraded};
                {error, Reason} -> {error, Reason}
            end
    end.

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
