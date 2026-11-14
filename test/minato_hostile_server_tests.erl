-module(minato_hostile_server_tests).
-moduledoc """
A server that is trying, against a client that has to stay standing.

`m:minato_conn_tests` covers a server that is awkward. These cover one that is
hostile, or one with somebody in the middle: it answers within the protocol and
chooses every answer to cost the client something. Each test states what the
client must still have afterwards.
""".

-include_lib("eunit/include/eunit.hrl").

-define(READY, [
    authentication_ok,
    {parameter_status, ~"server_version", ~"17.4"},
    {backend_key_data, 4242, 777},
    {ready_for_query, idle}
]).

%%----------------------------------------------------------------------
%% Command tags
%%----------------------------------------------------------------------

command_tags_a_server_invents_make_no_atoms_test() ->
    Warm = [{command_complete, ~"WARM UP"}, {ready_for_query, idle}],
    {Server, {ok, Conn}} = connects([?READY, Warm, invented_tags(1000)], #{}),
    {ok, [_Warm], Warmed} = minato_query:simple(Conn, ~"first"),
    Before = erlang:system_info(atom_count),
    {ok, Results, Read} = minato_query:simple(Warmed, ~"second"),
    After = erlang:system_info(atom_count),
    ok = minato_conn:close(Read),
    minato_backend_server:stop(Server),
    ?assertEqual(1000, length(Results)),
    ?assertMatch(#{command := ~"VERB1", num_rows := ~"NOUN1 OTHER1"}, hd(Results)),
    ?assertEqual(Before, After).

invented_tags(Count) ->
    [
        {command_complete, <<"VERB", N/binary, " NOUN", N/binary, " OTHER", N/binary>>}
     || N <- [integer_to_binary(I) || I <- lists:seq(1, Count)]
    ] ++ [{ready_for_query, idle}].

%%----------------------------------------------------------------------
%% Talking to the server
%%----------------------------------------------------------------------

connects(Script, Opts) ->
    Server = minato_backend_server:start(Script),
    Port = minato_backend_server:port(Server),
    {Server, minato_conn:connect(opts(Port, Opts))}.

opts(Port, Opts) ->
    maps:merge(
        #{host => "127.0.0.1", port => Port, user => ~"minato", timeout => 5000},
        Opts
    ).
