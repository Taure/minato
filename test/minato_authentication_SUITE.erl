-module(minato_authentication_SUITE).
-moduledoc """
Authentication against a real PostgreSQL, over a real socket.

The unit tests prove the derivation against the published vectors and against a
server written from the same RFC. Neither can show that PostgreSQL agrees, and
PostgreSQL is the only opinion that matters, so this suite completes the whole
exchange against `postgres:17` and then uses the session it opened.

Nothing here needs a connection layer, because there is not one yet.
`m:minato_protocol` frames what arrives, `m:minato_auth` decides what to answer,
and the suite owns the socket, which is the arrangement the finished client will
also have.

## What the server is asked

- **Can minato log in.** `authenticates/1` runs the four SASL messages and then
  reads on to `ReadyForQuery`, so the session is proved usable rather than
  merely opened.
- **Does the derivation match the verifier the server stored.** `pg_authid`
  holds `SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>`, which is
  the server's own PBKDF2 over the same password. Recomputing it is a check
  against PostgreSQL's implementation rather than against another reading of the
  RFC, and it covers `ServerKey`, which a successful login alone does not prove
  minato can derive.
- **Does the iteration count floor fire against a real server.** `scram_iterations`
  makes PostgreSQL announce whatever count it is told to, so the floor can be
  tested by a server that really does announce a weak one rather than by a
  hand written message.

The suite skips when no server answers, so `rebar3 ct` on a machine without
Docker is not a failure.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    the_server_offers_scram/1,
    scram_authenticates/1,
    scram_opens_a_usable_session/1,
    a_wrong_password_is_refused/1,
    an_unknown_user_is_refused/1,
    the_stored_verifier_matches_the_derivation/1,
    an_md5_verifier_matches_the_derivation/1,
    a_low_iteration_count_is_refused/1,
    a_high_iteration_count_authenticates/1
]).

-define(TIMEOUT, 10000).
-define(PASSWORD, ~"pencil").

-spec all() -> [atom()].
all() ->
    [
        the_server_offers_scram,
        scram_authenticates,
        scram_opens_a_usable_session,
        a_wrong_password_is_refused,
        an_unknown_user_is_refused,
        the_stored_verifier_matches_the_derivation,
        an_md5_verifier_matches_the_derivation,
        a_low_iteration_count_is_refused,
        a_high_iteration_count_authenticates
    ].

-spec init_per_suite([{atom(), term()}]) -> [{atom(), term()}] | {skip, term()}.
init_per_suite(Config) ->
    case gen_tcp:connect(host(), port(), [binary, {active, false}], ?TIMEOUT) of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            seed(),
            Config;
        {error, Reason} ->
            {skip, {no_server, host(), port(), Reason}}
    end.

-spec end_per_suite([{atom(), term()}]) -> ok.
end_per_suite(_Config) ->
    drop_roles(),
    ok.

%%----------------------------------------------------------------------
%% Cases
%%----------------------------------------------------------------------

-spec the_server_offers_scram([{atom(), term()}]) -> ok.
the_server_offers_scram(_Config) ->
    {ok, Socket} = open(user()),
    {authentication_sasl, Mechanisms} = first_message(Socket),
    ok = gen_tcp:close(Socket),
    ?assert(lists:member(~"SCRAM-SHA-256", Mechanisms)).

-spec scram_authenticates([{atom(), term()}]) -> ok.
scram_authenticates(_Config) ->
    {Socket, _Buffer} = authenticates(#{user => user(), password => password()}),
    ok = gen_tcp:close(Socket).

-spec scram_opens_a_usable_session([{atom(), term()}]) -> ok.
scram_opens_a_usable_session(_Config) ->
    ?assertEqual([[1, ~"ok"]], query(~"SELECT 1, 'ok'::text")).

-spec a_wrong_password_is_refused([{atom(), term()}]) -> ok.
a_wrong_password_is_refused(_Config) ->
    Refused = refused(#{user => user(), password => ~"not the password"}),
    ?assertMatch(#{code := ~"28P01"}, Refused).

-spec an_unknown_user_is_refused([{atom(), term()}]) -> ok.
an_unknown_user_is_refused(_Config) ->
    Refused = refused(#{user => ~"nobody_at_all", password => password()}),
    ?assertMatch(#{code := ~"28P01"}, Refused).

-spec the_stored_verifier_matches_the_derivation([{atom(), term()}]) -> ok.
the_stored_verifier_matches_the_derivation(_Config) ->
    [[Verifier]] = query(
        <<"SELECT rolpassword FROM pg_authid WHERE rolname = '", (user())/binary, "'">>
    ),
    #{iterations := Iterations, salt := Salt, stored_key := Stored, server_key := Server} =
        scram_verifier(Verifier),
    Held = minato_scram_server:new(password(), #{salt => Salt, iterations => Iterations}),
    ?assertEqual(Stored, minato_scram_server:stored_key(Held)),
    ?assertEqual(Server, minato_scram_server:server_key(Held)).

-spec an_md5_verifier_matches_the_derivation([{atom(), term()}]) -> ok.
an_md5_verifier_matches_the_derivation(_Config) ->
    [[Verifier]] = query(~"SELECT rolpassword FROM pg_authid WHERE rolname = 'minato_md5'"),
    Inner = binary:encode_hex(
        crypto:hash(md5, <<(?PASSWORD)/binary, "minato_md5">>), lowercase
    ),
    ?assertEqual(<<"md5", Inner/binary>>, Verifier).

-spec a_low_iteration_count_is_refused([{atom(), term()}]) -> ok.
a_low_iteration_count_is_refused(_Config) ->
    ?assertError(
        {minato_scram, #{reason := {iteration_count_below_minimum, 1, 4096}}},
        authenticates(#{user => ~"minato_weak", password => ?PASSWORD})
    ).

-spec a_high_iteration_count_authenticates([{atom(), term()}]) -> ok.
a_high_iteration_count_authenticates(_Config) ->
    {Socket, _Buffer} = authenticates(#{user => ~"minato_slow", password => ?PASSWORD}),
    ok = gen_tcp:close(Socket).

%%----------------------------------------------------------------------
%% Seeding
%%----------------------------------------------------------------------

seed() ->
    drop_roles(),
    execute(~"SET password_encryption = 'md5'; CREATE ROLE minato_md5 LOGIN PASSWORD 'pencil'"),
    execute(~"SET scram_iterations = 1; CREATE ROLE minato_weak LOGIN PASSWORD 'pencil'"),
    execute(~"SET scram_iterations = 8192; CREATE ROLE minato_slow LOGIN PASSWORD 'pencil'").

drop_roles() ->
    execute(~"DROP ROLE IF EXISTS minato_md5, minato_weak, minato_slow").

execute(Sql) ->
    case query(Sql) of
        [] -> ok;
        Reported -> error({statement_failed, Sql, Reported})
    end.

%%----------------------------------------------------------------------
%% Talking to the server
%%----------------------------------------------------------------------

authenticates(Credentials) ->
    #{user := User} = Credentials,
    {ok, Socket} = open(User),
    {Socket, ready(Socket, exchange(Socket, minato_auth:init(Credentials), ~""))}.

refused(Credentials) ->
    #{user := User} = Credentials,
    {ok, Socket} = open(User),
    Result = exchange(Socket, minato_auth:init(Credentials), ~""),
    ok = gen_tcp:close(Socket),
    case Result of
        {refused, Fields} -> Fields;
        Other -> {unexpectedly_authenticated, Other}
    end.

open(User) ->
    {ok, Socket} = gen_tcp:connect(host(), port(), [binary, {active, false}], ?TIMEOUT),
    Startup = minato_protocol:encode(
        {startup, #{~"user" => User, ~"database" => database()}}
    ),
    ok = gen_tcp:send(Socket, Startup),
    {ok, Socket}.

first_message(Socket) ->
    {Message, _Rest} = read(Socket, ~""),
    Message.

read(Socket, Buffer) ->
    case minato_protocol:decode(Buffer) of
        incomplete ->
            More = recv(Socket),
            read(Socket, <<Buffer/binary, More/binary>>);
        {ok, Message, Rest} ->
            {Message, Rest}
    end.

recv(Socket) ->
    case gen_tcp:recv(Socket, 0, ?TIMEOUT) of
        {ok, Bytes} when is_binary(Bytes) -> Bytes
    end.

exchange(Socket, State, Buffer) ->
    case read(Socket, Buffer) of
        {{error_response, Fields}, _Rest} ->
            {refused, Fields};
        {Message, Rest} ->
            answer(Socket, minato_auth:step(Message, State), Rest)
    end.

answer(_Socket, authenticated, Rest) ->
    Rest;
answer(Socket, {continue, State}, Rest) ->
    exchange(Socket, State, Rest);
answer(Socket, {send, Reply, State}, Rest) ->
    ok = gen_tcp:send(Socket, minato_protocol:encode(Reply)),
    exchange(Socket, State, Rest).

ready(Socket, Buffer) ->
    case read(Socket, Buffer) of
        {{ready_for_query, idle}, Rest} -> Rest;
        {{error_response, Fields}, _Rest} -> error({startup_failed, Fields});
        {_Message, Rest} -> ready(Socket, Rest)
    end.

query(Sql) ->
    {Socket, Buffer} = authenticates(#{user => user(), password => password()}),
    ok = gen_tcp:send(Socket, minato_protocol:encode({query, Sql})),
    Rows = collect(Socket, Buffer, [], []),
    ok = gen_tcp:close(Socket),
    Rows.

collect(Socket, Buffer, Fields, Rows) ->
    case read(Socket, Buffer) of
        {{row_description, Described}, Rest} ->
            collect(Socket, Rest, Described, Rows);
        {{data_row, Columns}, Rest} ->
            collect(Socket, Rest, Fields, [columns(Fields, Columns) | Rows]);
        {{error_response, Reported}, Rest} ->
            collect(Socket, Rest, Fields, [{error, Reported} | Rows]);
        {{ready_for_query, _Status}, _Rest} ->
            lists:reverse(Rows);
        {_Message, Rest} ->
            collect(Socket, Rest, Fields, Rows)
    end.

columns(Fields, Columns) ->
    case minato_protocol:row(Fields, Columns, #{}) of
        Row when is_tuple(Row) -> tuple_to_list(Row)
    end.

%%----------------------------------------------------------------------
%% The stored verifier
%%----------------------------------------------------------------------

scram_verifier(<<"SCRAM-SHA-256$", Rest/binary>>) ->
    [Iterations, Salt, Stored, Server] = binary:split(Rest, [~"$", ~":"], [global]),
    #{
        iterations => binary_to_integer(Iterations),
        salt => base64:decode(Salt),
        stored_key => base64:decode(Stored),
        server_key => base64:decode(Server)
    }.

%%----------------------------------------------------------------------
%% Where the server is
%%----------------------------------------------------------------------

host() ->
    env("MINATO_PG_HOST", "127.0.0.1").

port() ->
    list_to_integer(env("MINATO_PG_PORT", "55432")).

database() ->
    list_to_binary(env("MINATO_PG_DATABASE", "minato_test")).

user() ->
    list_to_binary(env("MINATO_PG_USER", "minato")).

password() ->
    list_to_binary(env("MINATO_PG_PASSWORD", "minato")).

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.
