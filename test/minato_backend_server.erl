-module(minato_backend_server).
-moduledoc """
A PostgreSQL server as far as the opening exchange goes, and no further.

`m:minato_conn` decides what to answer a server with, and most of those
decisions are about servers a test cannot ask a real PostgreSQL to be: one that
demands a cleartext password on a plain socket, one that declines TLS, one that
sends a message that does not belong in a startup exchange, one that says
nothing at all. This is that server. It reads frontend messages with
`m:minato_frontend_reader`, answers each with the next batch of bytes it was
given at start up, and forwards everything the client sent to the process that
started it.

The script is a list of answers, one per frontend message read. `{raw, Bytes}`
writes bytes as they are, which is how the single byte answer to `SSLRequest`
is given; anything else is a list of `m:minato_backend_writer` messages. When
the script runs out the server keeps reading and answers nothing, which is what
a client waiting on a message it will never get has to cope with.
A `Terminate` is never answered, as no server would, and ends the conversation,
and so does a `CancelRequest`.

Connections are served concurrently, each with its own copy of the script,
because `cancel/1` opens a second connection while the first is still waiting
for an answer: a server that accepted one at a time would leave the cancel
sitting in a backlog nobody reads, which is exactly the case a cancel test needs
to observe.
""".

-export([start/1, start/2, port/1, client_tls/1, received/1, stop/1]).

-include_lib("public_key/include/public_key.hrl").

-define(ACCEPT_TIMEOUT, 5000).
-define(DRAIN_TIMEOUT, 200).
-define(CHATTER_INTERVAL, 50).

-doc "What to answer one frontend message with.".
-type answer() :: [minato_backend_writer:message()] | {raw, iodata()}.

-doc """
How the server behaves beyond the script.

`tls` answers `SSLRequest` with `S` and completes a handshake with a certificate
made for the server, which `client_tls/1` hands the client the trust for.
`after_terminate` is what happens once `Terminate` or `CancelRequest` is read:
`close` is what a PostgreSQL does, `hold` keeps the session open and silent until the client
closes it, and `chatter` keeps writing to it, so a client waiting for the close
never waits on a quiet socket.
""".
-type opts() :: #{tls => boolean(), after_terminate => close | hold | chatter}.

-doc "A running server.".
-opaque server() :: #{pid := pid(), port := inet:port_number(), tls := [ssl:tls_client_option()]}.

-export_type([answer/0, opts/0, server/0]).

-type identity() :: #{
    cert := public_key:der_encoded(), key := {'ECPrivateKey', public_key:der_encoded()}
}.

-type peer() :: #{
    transport := gen_tcp | ssl,
    tcp := gen_tcp:socket(),
    socket := gen_tcp:socket() | ssl:sslsocket(),
    owner := pid(),
    acceptor := pid(),
    tls := identity() | undefined,
    after_terminate := close | hold | chatter
}.

-doc "`start/2` with nothing beyond the script.".
-spec start([answer()]) -> server().
start(Script) ->
    start(Script, #{}).

-doc "Listen on an ephemeral port and answer the script.".
-spec start([answer()], opts()) -> server().
start(Script, Opts) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    {Server, Client} = credentials(maps:get(tls, Opts, false)),
    Owner = self(),
    After = maps:get(after_terminate, Opts, close),
    Pid = spawn_link(fun() -> accept(Listen, Owner, Script, {Server, After}) end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    #{pid => Pid, port => Port, tls => Client}.

-doc "Where it is listening.".
-spec port(server()) -> inet:port_number().
port(#{port := Port}) ->
    Port.

-doc "The `ssl_options` a client needs to verify this server, under `tls`.".
-spec client_tls(server()) -> [ssl:tls_client_option()].
client_tls(#{tls := Client}) ->
    Client.

-doc """
Every frontend message the server has read and not yet handed over, in order.

Read from the calling process's own mailbox, so it has to be the process that
called `start/1`. Under `hold` and `chatter`, `closed` follows `terminate` once
the client has closed.
""".
-spec received(server()) -> [minato_protocol:frontend() | {password_message, binary()} | closed].
received(#{pid := Pid}) ->
    drain(Pid).

-spec drain(pid()) -> [minato_protocol:frontend() | {password_message, binary()} | closed].
drain(Pid) ->
    receive
        {?MODULE, Pid, Message} -> [Message | drain(Pid)]
    after ?DRAIN_TIMEOUT -> []
    end.

-doc "Stop listening.".
-spec stop(server()) -> ok.
stop(#{pid := Pid}) ->
    unlink(Pid),
    exit(Pid, shutdown),
    ok.

-spec credentials(boolean()) ->
    {identity() | undefined, [ssl:tls_client_option()]}.
credentials(false) ->
    {undefined, []};
credentials(true) ->
    Key = [{key, {namedCurve, ?secp256r1}}, {digest, sha256}],
    Named = #'Extension'{
        extnID = ?'id-ce-subjectAltName', critical = false, extnValue = [{dNSName, "localhost"}]
    },
    #{server_config := Server, client_config := Client} = public_key:pkix_test_data(#{
        server_chain => #{root => Key, intermediates => [], peer => [{extensions, [Named]} | Key]},
        client_chain => #{root => Key, intermediates => [], peer => Key}
    }),
    {identity(Server), [{cacerts, trusted(Client)}, {server_name_indication, "localhost"}]}.

-spec trusted([public_key:conf_opt()]) -> [public_key:der_encoded()].
trusted([{cacerts, Ders} | _Rest]) -> Ders;
trusted([_Other | Rest]) -> trusted(Rest);
trusted([]) -> [].

-spec identity([public_key:conf_opt()]) -> identity().
identity(Server) ->
    #{cert => certificate(Server), key => private_key(Server)}.

-spec certificate([public_key:conf_opt()]) -> public_key:der_encoded().
certificate([{cert, Der} | _Rest]) -> Der;
certificate([_Other | Rest]) -> certificate(Rest).

%% `public_key:conf_opt()` says the key comes back decoded. It comes back DER
%% encoded with its type, which is what `m:ssl` takes.
-spec private_key(dynamic()) -> {'ECPrivateKey', public_key:der_encoded()}.
private_key([{key, {'ECPrivateKey', Der}} | _Rest]) when is_binary(Der) ->
    {'ECPrivateKey', Der};
private_key([_Other | Rest]) ->
    private_key(Rest).

-spec accept(
    gen_tcp:socket(),
    pid(),
    [answer()],
    {identity() | undefined, close | hold | chatter}
) -> no_return().
accept(Listen, Owner, Script, {Tls, After} = Opts) ->
    case gen_tcp:accept(Listen, ?ACCEPT_TIMEOUT) of
        {ok, Socket} ->
            Peer = #{
                transport => gen_tcp,
                tcp => Socket,
                socket => Socket,
                owner => Owner,
                acceptor => self(),
                tls => Tls,
                after_terminate => After
            },
            Served = spawn_link(fun() -> served(Peer, Script) end),
            ok = gen_tcp:controlling_process(Socket, Served),
            Served ! {?MODULE, yours},
            accept(Listen, Owner, Script, Opts);
        {error, timeout} ->
            accept(Listen, Owner, Script, Opts)
    end.

-spec served(peer(), [answer()]) -> ok.
served(Peer, Script) ->
    receive
        {?MODULE, yours} ->
            closed(serve(Peer, ~"", false, Script))
    after ?ACCEPT_TIMEOUT ->
        closed(Peer)
    end.

-spec closed(peer()) -> ok.
closed(#{transport := Transport, socket := Socket}) ->
    _ = Transport:close(Socket),
    ok.

-spec serve(peer(), binary(), boolean(), [answer()]) -> peer().
serve(#{tls := Tls, transport := gen_tcp} = Peer, Buffer, StartedUp, Script) when
    Tls =/= undefined
->
    case read(Peer, Buffer, StartedUp) of
        {ok, ssl_request, _Rest} ->
            told(Peer, ssl_request),
            secured(Peer, Tls, Script);
        Read ->
            served(Peer, Read, StartedUp, Script)
    end;
serve(Peer, Buffer, StartedUp, Script) ->
    served(Peer, read(Peer, Buffer, StartedUp), StartedUp, Script).

-spec secured(peer(), identity(), [answer()]) -> peer().
secured(#{tcp := Socket} = Peer, Identity, Script) ->
    ok = gen_tcp:send(Socket, ~"S"),
    case ssl:handshake(Socket, [{certs_keys, [Identity]}], ?ACCEPT_TIMEOUT) of
        {ok, Secure} -> serve(Peer#{transport => ssl, socket => Secure}, ~"", false, Script);
        {error, _Reason} -> Peer
    end.

-spec served(peer(), {ok, term(), binary()} | closed, boolean(), [answer()]) -> peer().
served(Peer, {ok, terminate, _Rest}, _StartedUp, _Script) ->
    told(Peer, terminate),
    terminated(Peer);
%% PostgreSQL closes a cancel connection once it has read the request.
served(Peer, {ok, {cancel_request, _Pid, _Secret} = Message, _Rest}, _StartedUp, _Script) ->
    told(Peer, Message),
    terminated(Peer);
served(Peer, {ok, Message, Rest}, StartedUp, Script) ->
    told(Peer, Message),
    answer(Peer, Rest, started_up(Message, StartedUp), Script);
served(Peer, closed, _StartedUp, _Script) ->
    Peer.

-spec told(peer(), term()) -> ok.
told(#{owner := Owner, acceptor := Acceptor}, Message) ->
    Owner ! {?MODULE, Acceptor, Message},
    ok.

-spec terminated(peer()) -> peer().
terminated(#{after_terminate := close} = Peer) ->
    Peer;
terminated(#{after_terminate := hold, transport := Transport, socket := Socket} = Peer) ->
    case Transport:recv(Socket, 0, infinity) of
        {ok, _Bytes} -> terminated(Peer);
        {error, _Closed} -> gone(Peer)
    end;
terminated(#{after_terminate := chatter, transport := Transport, socket := Socket} = Peer) ->
    case Transport:recv(Socket, 0, ?CHATTER_INTERVAL) of
        {error, timeout} ->
            _ = Transport:send(Socket, ~"x"),
            terminated(Peer);
        {ok, _Bytes} ->
            terminated(Peer);
        {error, _Closed} ->
            gone(Peer)
    end.

-spec gone(peer()) -> peer().
gone(Peer) ->
    told(Peer, closed),
    Peer.

-spec answer(peer(), binary(), boolean(), [answer()]) -> peer().
answer(#{transport := Transport, socket := Socket} = Peer, Rest, StartedUp, [Answer | Script]) ->
    ok = Transport:send(Socket, bytes(Answer)),
    serve(Peer, Rest, StartedUp, Script);
answer(Peer, Rest, StartedUp, []) ->
    serve(Peer, Rest, StartedUp, []).

-spec bytes(answer()) -> iodata().
bytes({raw, Bytes}) -> Bytes;
bytes(Messages) -> minato_backend_writer:write_all(Messages).

-spec started_up(term(), boolean()) -> boolean().
started_up({startup, _Parameters}, _StartedUp) -> true;
started_up(_Message, StartedUp) -> StartedUp.

-spec read(peer(), binary(), boolean()) -> {ok, term(), binary()} | closed.
read(#{transport := Transport, socket := Socket} = Peer, Buffer, StartedUp) ->
    case frontend(Buffer, StartedUp) of
        {ok, Message, Rest} ->
            {ok, minato_frontend_reader:read(Message), Rest};
        incomplete ->
            case Transport:recv(Socket, 0, ?ACCEPT_TIMEOUT) of
                {ok, Bytes} when is_binary(Bytes) ->
                    read(Peer, <<Buffer/binary, Bytes/binary>>, StartedUp);
                {error, _Reason} ->
                    closed
            end
    end.

-spec frontend(binary(), boolean()) -> {ok, binary(), binary()} | incomplete.
frontend(<<Length:32, _/binary>> = Buffer, false) when byte_size(Buffer) >= Length ->
    <<Message:Length/binary, Rest/binary>> = Buffer,
    {ok, Message, Rest};
frontend(<<_Type, Length:32, _/binary>> = Buffer, true) when byte_size(Buffer) >= Length + 1 ->
    Size = Length + 1,
    <<Message:Size/binary, Rest/binary>> = Buffer,
    {ok, Message, Rest};
frontend(_Buffer, _StartedUp) ->
    incomplete.
