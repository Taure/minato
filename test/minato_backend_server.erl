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
A `Terminate` is never answered, as no server would, and ends the conversation.

Connections are served concurrently, each with its own copy of the script,
because `cancel/1` opens a second connection while the first is still waiting
for an answer: a server that accepted one at a time would leave the cancel
sitting in a backlog nobody reads, which is exactly the case a cancel test needs
to observe.
""".

-export([start/1, port/1, received/1, stop/1]).

-define(ACCEPT_TIMEOUT, 5000).
-define(DRAIN_TIMEOUT, 200).

-doc "What to answer one frontend message with.".
-type answer() :: [minato_backend_writer:message()] | {raw, iodata()}.

-doc "A running server.".
-opaque server() :: #{pid := pid(), port := inet:port_number()}.

-export_type([answer/0, server/0]).

-doc "Listen on an ephemeral port and answer the script.".
-spec start([answer()]) -> server().
start(Script) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Owner = self(),
    Pid = spawn_link(fun() -> accept(Listen, Owner, Script) end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    #{pid => Pid, port => Port}.

-doc "Where it is listening.".
-spec port(server()) -> inet:port_number().
port(#{port := Port}) ->
    Port.

-doc """
Every frontend message the server has read and not yet handed over, in order.

Read from the calling process's own mailbox, so it has to be the process that
called `start/1`.
""".
-spec received(server()) -> [minato_protocol:frontend() | {password_message, binary()}].
received(#{pid := Pid}) ->
    drain(Pid).

-spec drain(pid()) -> [minato_protocol:frontend() | {password_message, binary()}].
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

-spec accept(gen_tcp:socket(), pid(), [answer()]) -> no_return().
accept(Listen, Owner, Script) ->
    case gen_tcp:accept(Listen, ?ACCEPT_TIMEOUT) of
        {ok, Socket} ->
            Acceptor = self(),
            Served = spawn_link(fun() -> served(Socket, Owner, Acceptor, Script) end),
            ok = gen_tcp:controlling_process(Socket, Served),
            Served ! {?MODULE, yours},
            accept(Listen, Owner, Script);
        {error, timeout} ->
            accept(Listen, Owner, Script)
    end.

-spec served(gen_tcp:socket(), pid(), pid(), [answer()]) -> ok.
served(Socket, Owner, Acceptor, Script) ->
    receive
        {?MODULE, yours} ->
            _ = serve(Socket, Owner, Acceptor, ~"", false, Script),
            gen_tcp:close(Socket)
    after ?ACCEPT_TIMEOUT ->
        gen_tcp:close(Socket)
    end.

-spec serve(gen_tcp:socket(), pid(), pid(), binary(), boolean(), [answer()]) -> [answer()].
serve(Socket, Owner, Acceptor, Buffer, StartedUp, Script) ->
    case read(Socket, Buffer, StartedUp) of
        {ok, terminate, _Rest} ->
            Owner ! {?MODULE, Acceptor, terminate},
            Script;
        {ok, Message, Rest} ->
            Owner ! {?MODULE, Acceptor, Message},
            answer(Socket, Owner, Acceptor, Rest, started_up(Message, StartedUp), Script);
        closed ->
            Script
    end.

-spec answer(gen_tcp:socket(), pid(), pid(), binary(), boolean(), [answer()]) -> [answer()].
answer(Socket, Owner, Acceptor, Rest, StartedUp, [Answer | Script]) ->
    ok = gen_tcp:send(Socket, bytes(Answer)),
    serve(Socket, Owner, Acceptor, Rest, StartedUp, Script);
answer(Socket, Owner, Acceptor, Rest, StartedUp, []) ->
    serve(Socket, Owner, Acceptor, Rest, StartedUp, []).

-spec bytes(answer()) -> iodata().
bytes({raw, Bytes}) -> Bytes;
bytes(Messages) -> minato_backend_writer:write_all(Messages).

-spec started_up(term(), boolean()) -> boolean().
started_up({startup, _Parameters}, _StartedUp) -> true;
started_up(_Message, StartedUp) -> StartedUp.

-spec read(gen_tcp:socket(), binary(), boolean()) -> {ok, term(), binary()} | closed.
read(Socket, Buffer, StartedUp) ->
    case frontend(Buffer, StartedUp) of
        {ok, Message, Rest} ->
            {ok, minato_frontend_reader:read(Message), Rest};
        incomplete ->
            case gen_tcp:recv(Socket, 0, ?ACCEPT_TIMEOUT) of
                {ok, Bytes} when is_binary(Bytes) ->
                    read(Socket, <<Buffer/binary, Bytes/binary>>, StartedUp);
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
