-module(minato_scram_tests).
-moduledoc """
SCRAM-SHA-256 against the published vectors, and against a hostile server.

The RFC 7677 vectors fix every input including the client nonce, so they check
the derivation and the exact bytes of all three client messages at once. They
exist to be used verbatim and they are used verbatim here.

The rest of the file is mostly rejection. A client that authenticates correctly
and also authenticates against a server that failed to prove itself has gained
nothing, so every check `m:minato_scram` makes has a test that the check
fires, asserting the exception and its reason rather than the absence of a
success.
""".

-include_lib("eunit/include/eunit.hrl").

-define(USERNAME, ~"user").
-define(PASSWORD, ~"pencil").
-define(CLIENT_NONCE, ~"rOprNGfwEbeRWgbNEkqO").
-define(NONCE, ~"rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0").
-define(SALT, ~"W22ZaJ0SNY7soEsUEjb6gQ==").
-define(CLIENT_FIRST, ~"n,,n=user,r=rOprNGfwEbeRWgbNEkqO").
-define(SERVER_FIRST,
    ~"r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
).
-define(CLIENT_FINAL,
    ~"c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
).
-define(SERVER_FINAL, ~"v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=").

%%----------------------------------------------------------------------
%% RFC 7677 section 3
%%----------------------------------------------------------------------

rfc_7677_client_first_test() ->
    {Message, _Client} = vector_client(),
    ?assertEqual(?CLIENT_FIRST, iolist_to_binary(Message)).

rfc_7677_client_final_test() ->
    {_First, Client} = vector_client(),
    {Message, _Check} = minato_scram:client_final(?SERVER_FIRST, ?PASSWORD, Client),
    ?assertEqual(?CLIENT_FINAL, iolist_to_binary(Message)).

rfc_7677_server_final_test() ->
    ?assertEqual(ok, minato_scram:server_final(?SERVER_FINAL, vector_check())).

rfc_7677_gs2_header_is_no_channel_binding_test() ->
    {Message, _Client} = vector_client(),
    ?assertMatch(<<"n,,", _/binary>>, iolist_to_binary(Message)).

rfc_7677_channel_binding_attribute_is_the_bare_header_test() ->
    {_First, Client} = vector_client(),
    {Message, _Check} = minato_scram:client_final(?SERVER_FIRST, ?PASSWORD, Client),
    ?assertMatch(<<"c=biws,", _/binary>>, iolist_to_binary(Message)),
    ?assertEqual(~"n,,", base64:decode(~"biws")).

%%----------------------------------------------------------------------
%% The client nonce
%%----------------------------------------------------------------------

generated_nonce_is_thirty_two_printable_characters_test() ->
    Nonce = generated_nonce(),
    ?assertEqual(32, byte_size(Nonce)),
    ?assert(lists:all(fun printable/1, binary_to_list(Nonce))).

generated_nonce_differs_every_time_test() ->
    Nonces = [generated_nonce() || _ <- lists:seq(1, 64)],
    ?assertEqual(64, length(lists:usort(Nonces))).

generated_nonce_carries_no_comma_test() ->
    Nonces = [generated_nonce() || _ <- lists:seq(1, 64)],
    ?assertEqual([], [Nonce || Nonce <- Nonces, binary:match(Nonce, ~",") =/= nomatch]).

%%----------------------------------------------------------------------
%% The user name
%%----------------------------------------------------------------------

username_escapes_the_separator_and_the_delimiter_test() ->
    {Message, _Client} = minato_scram:client_first(~"a=b,c", ?CLIENT_NONCE, #{}),
    ?assertEqual(
        <<"n,,n=a=3Db=2Cc,r=", (?CLIENT_NONCE)/binary>>, iolist_to_binary(Message)
    ).

username_escaping_does_not_escape_its_own_escapes_test() ->
    {Message, _Client} = minato_scram:client_first(~",", ~"n", #{}),
    ?assertEqual(~"n,,n==2C,r=n", iolist_to_binary(Message)).

%%----------------------------------------------------------------------
%% The server nonce must extend the client nonce
%%----------------------------------------------------------------------

server_nonce_that_replaces_the_client_nonce_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := server_nonce_does_not_extend_client_nonce}},
        answer(challenge(~"totallyDifferentNonce", ?SALT, 4096))
    ).

server_nonce_equal_to_the_client_nonce_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := server_nonce_does_not_extend_client_nonce}},
        answer(challenge(?CLIENT_NONCE, ?SALT, 4096))
    ).

server_nonce_that_is_a_prefix_of_the_client_nonce_is_rejected_test() ->
    Short = binary:part(?CLIENT_NONCE, 0, byte_size(?CLIENT_NONCE) - 1),
    ?assertError(
        {minato_scram, #{reason := server_nonce_does_not_extend_client_nonce}},
        answer(challenge(Short, ?SALT, 4096))
    ).

server_nonce_that_only_contains_the_client_nonce_is_rejected_test() ->
    Buried = <<"xx", (?CLIENT_NONCE)/binary, "yy">>,
    ?assertError(
        {minato_scram, #{reason := server_nonce_does_not_extend_client_nonce}},
        answer(challenge(Buried, ?SALT, 4096))
    ).

empty_server_nonce_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := server_nonce_does_not_extend_client_nonce}},
        answer(challenge(~"", ?SALT, 4096))
    ).

server_nonce_extended_by_one_byte_is_accepted_test() ->
    Extended = <<(?CLIENT_NONCE)/binary, "x">>,
    ?assertMatch({_Message, _Check}, answer(challenge(Extended, ?SALT, 4096))).

%%----------------------------------------------------------------------
%% The iteration count
%%----------------------------------------------------------------------

iteration_count_below_the_floor_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {iteration_count_below_minimum, 1, 4096}}},
        answer(challenge(?NONCE, ?SALT, 1))
    ).

iteration_count_just_below_the_floor_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {iteration_count_below_minimum, 4095, 4096}}},
        answer(challenge(?NONCE, ?SALT, 4095))
    ).

iteration_count_at_the_floor_is_accepted_test() ->
    ?assertMatch({_Message, _Check}, answer(challenge(?NONCE, ?SALT, 4096))).

iteration_count_above_the_ceiling_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {iteration_count_above_maximum, 1000001, 1000000}}},
        answer(challenge(?NONCE, ?SALT, 1000001))
    ).

absurd_iteration_count_is_rejected_without_running_it_test() ->
    {Time, Reason} = timer:tc(fun() ->
        try
            answer(challenge(?NONCE, ?SALT, 2000000000)),
            never_rejected
        catch
            error:{minato_scram, #{reason := Rejected}} -> Rejected
        end
    end),
    ?assertMatch({iteration_count_above_maximum, 2000000000, 1000000}, Reason),
    ?assert(Time < 1000000).

negative_iteration_count_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {iteration_count_not_a_number, ~"-1"}}},
        answer(<<"r=", (?NONCE)/binary, ",s=", (?SALT)/binary, ",i=-1">>)
    ).

non_numeric_iteration_count_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {iteration_count_not_a_number, ~"lots"}}},
        answer(<<"r=", (?NONCE)/binary, ",s=", (?SALT)/binary, ",i=lots">>)
    ).

an_iteration_count_of_absurdly_many_digits_is_rejected_unparsed_test() ->
    Digits = binary:copy(~"9", 1000000),
    {Time, Reason} = timer:tc(fun() ->
        try
            answer(<<"r=", (?NONCE)/binary, ",s=", (?SALT)/binary, ",i=", Digits/binary>>),
            never_rejected
        catch
            error:{minato_scram, #{reason := Rejected}} -> Rejected
        end
    end),
    ?assertMatch({iteration_count_too_long, 1000000}, Reason),
    ?assert(Time < 1000000).

an_iteration_count_of_twenty_digits_is_still_read_test() ->
    Digits = binary:copy(~"9", 20),
    ?assertError(
        {minato_scram, #{reason := {iteration_count_above_maximum, _Count, 1000000}}},
        answer(<<"r=", (?NONCE)/binary, ",s=", (?SALT)/binary, ",i=", Digits/binary>>)
    ).

empty_iteration_count_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {iteration_count_not_a_number, ~""}}},
        answer(<<"r=", (?NONCE)/binary, ",s=", (?SALT)/binary, ",i=">>)
    ).

iteration_bounds_are_configurable_test() ->
    Opts = #{minimum_iterations => 1024, maximum_iterations => 2048},
    {_First, Client} = minato_scram:client_first(?USERNAME, ?CLIENT_NONCE, Opts),
    ?assertMatch(
        {_Message, _Check},
        minato_scram:client_final(challenge(?NONCE, ?SALT, 1024), ?PASSWORD, Client)
    ),
    ?assertError(
        {minato_scram, #{reason := {iteration_count_below_minimum, 1023, 1024}}},
        minato_scram:client_final(challenge(?NONCE, ?SALT, 1023), ?PASSWORD, Client)
    ).

%%----------------------------------------------------------------------
%% A malformed server-first-message
%%----------------------------------------------------------------------

malformed_server_first_test_() ->
    [
        {"empty", ?_assertError({minato_scram, #{reason := malformed}}, answer(~""))},
        {"no attributes at all",
            ?_assertError({minato_scram, #{reason := malformed}}, answer(~"nonsense"))},
        {"no salt or iteration count",
            ?_assertError(
                {minato_scram, #{reason := malformed}}, answer(<<"r=", (?NONCE)/binary>>)
            )},
        {"no iteration count",
            ?_assertError(
                {minato_scram, #{reason := malformed}},
                answer(<<"r=", (?NONCE)/binary, ",s=", (?SALT)/binary>>)
            )},
        {"attributes out of order",
            ?_assertError(
                {minato_scram, #{reason := malformed}},
                answer(<<"s=", (?SALT)/binary, ",r=", (?NONCE)/binary, ",i=4096">>)
            )},
        {"an unknown attribute in place of the nonce",
            ?_assertError(
                {minato_scram, #{reason := malformed}},
                answer(<<"x=", (?NONCE)/binary, ",s=", (?SALT)/binary, ",i=4096">>)
            )}
    ].

mandatory_extension_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {mandatory_extension, ~"future"}}},
        answer(
            <<"m=future,r=", (?NONCE)/binary, ",s=", (?SALT)/binary, ",i=4096">>
        )
    ).

salt_that_is_not_base64_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {not_base64, ~"not base64"}}},
        answer(<<"r=", (?NONCE)/binary, ",s=not base64,i=4096">>)
    ).

trailing_extensions_are_ignored_test() ->
    Extended = <<(?SERVER_FIRST)/binary, ",future=whatever">>,
    ?assertMatch({_Message, _Check}, answer(Extended)).

%%----------------------------------------------------------------------
%% The server signature
%%----------------------------------------------------------------------

wrong_server_signature_is_rejected_test() ->
    Forged = base64:encode(crypto:strong_rand_bytes(32)),
    ?assertError(
        {minato_scram, #{reason := server_signature_mismatch}},
        minato_scram:server_final(<<"v=", Forged/binary>>, vector_check())
    ).

server_signature_off_by_one_bit_is_rejected_test() ->
    Signature = base64:decode(~"6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="),
    <<First, Rest/binary>> = Signature,
    Flipped = base64:encode(<<(First bxor 1), Rest/binary>>),
    ?assertError(
        {minato_scram, #{reason := server_signature_mismatch}},
        minato_scram:server_final(<<"v=", Flipped/binary>>, vector_check())
    ).

truncated_server_signature_is_rejected_test() ->
    Signature = base64:decode(~"6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="),
    Short = base64:encode(binary:part(Signature, 0, 16)),
    ?assertError(
        {minato_scram, #{reason := server_signature_mismatch}},
        minato_scram:server_final(<<"v=", Short/binary>>, vector_check())
    ).

empty_server_signature_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := server_signature_mismatch}},
        minato_scram:server_final(~"v=", vector_check())
    ).

server_signature_that_is_not_base64_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {not_base64, ~"not base64"}}},
        minato_scram:server_final(~"v=not base64", vector_check())
    ).

server_error_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := {server_error, ~"invalid-proof"}}},
        minato_scram:server_final(~"e=invalid-proof", vector_check())
    ).

malformed_server_final_test_() ->
    [
        {"empty", ?_assertError({minato_scram, #{reason := malformed}}, verify(~""))},
        {"no attribute",
            ?_assertError({minato_scram, #{reason := malformed}}, verify(~"nonsense"))},
        {"the proof attribute instead of the verifier",
            ?_assertError({minato_scram, #{reason := malformed}}, verify(~"p=whatever"))},
        {"the verifier second",
            ?_assertError(
                {minato_scram, #{reason := malformed}}, verify(~"x=1,v=6rriTRBi23WpRR/wtup")
            )}
    ].

server_final_extensions_after_the_verifier_are_ignored_test() ->
    ?assertEqual(
        ok,
        minato_scram:server_final(<<(?SERVER_FINAL)/binary, ",future=whatever">>, vector_check())
    ).

%%----------------------------------------------------------------------
%% Calling the exchange out of order
%%----------------------------------------------------------------------

verifying_before_the_client_final_message_is_rejected_test() ->
    {_First, Client} = vector_client(),
    ?assertError(
        {minato_scram, #{reason := out_of_order}}, minato_scram:server_final(?SERVER_FINAL, Client)
    ).

answering_the_server_first_message_twice_is_rejected_test() ->
    ?assertError(
        {minato_scram, #{reason := out_of_order}},
        minato_scram:client_final(?SERVER_FIRST, ?PASSWORD, vector_check())
    ).

%%----------------------------------------------------------------------
%% Against the server half
%%----------------------------------------------------------------------

a_full_exchange_with_a_matching_verifier_succeeds_test() ->
    ?assertEqual(ok, exchange(?PASSWORD, ?PASSWORD)).

a_full_exchange_with_a_different_password_is_refused_by_the_server_test() ->
    ?assertEqual({error, invalid_proof}, exchange(?PASSWORD, ~"not the password")).

a_generated_nonce_survives_the_exchange_test() ->
    Server = minato_scram_server:new(?PASSWORD),
    {ClientFirst, Client} = minato_scram:client_first(?USERNAME, #{}),
    {ServerFirst, Ready} = minato_scram_server:first(iolist_to_binary(ClientFirst), Server),
    {ClientFinal, Check} = minato_scram:client_final(ServerFirst, ?PASSWORD, Client),
    {ok, ServerFinal} = minato_scram_server:final(iolist_to_binary(ClientFinal), Ready),
    ?assertEqual(ok, minato_scram:server_final(ServerFinal, Check)).

the_server_half_agrees_with_the_published_vector_test() ->
    Offset = byte_size(?CLIENT_NONCE),
    ServerPart = binary:part(?NONCE, Offset, byte_size(?NONCE) - Offset),
    Server = minato_scram_server:new(?PASSWORD, #{
        salt => base64:decode(?SALT), iterations => 4096, nonce => ServerPart
    }),
    {ServerFirst, Ready} = minato_scram_server:first(?CLIENT_FIRST, Server),
    ?assertEqual(?SERVER_FIRST, ServerFirst),
    ?assertEqual({ok, ?SERVER_FINAL}, minato_scram_server:final(?CLIENT_FINAL, Ready)).

a_server_signature_from_another_exchange_is_rejected_test() ->
    {_First, Client} = vector_client(),
    {_Final, Check} = minato_scram:client_final(?SERVER_FIRST, ?PASSWORD, Client),
    Other = minato_scram_server:new(?PASSWORD),
    {ClientFirst, OtherClient} = minato_scram:client_first(?USERNAME, #{}),
    {ServerFirst, Ready} = minato_scram_server:first(iolist_to_binary(ClientFirst), Other),
    {ClientFinal, _Check} = minato_scram:client_final(ServerFirst, ?PASSWORD, OtherClient),
    {ok, ServerFinal} = minato_scram_server:final(iolist_to_binary(ClientFinal), Ready),
    ?assertError(
        {minato_scram, #{reason := server_signature_mismatch}},
        minato_scram:server_final(ServerFinal, Check)
    ).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

vector_client() ->
    minato_scram:client_first(?USERNAME, ?CLIENT_NONCE, #{}).

vector_check() ->
    {_First, Client} = vector_client(),
    {_Final, Check} = minato_scram:client_final(?SERVER_FIRST, ?PASSWORD, Client),
    Check.

answer(ServerFirst) ->
    {_First, Client} = vector_client(),
    minato_scram:client_final(ServerFirst, ?PASSWORD, Client).

verify(ServerFinal) ->
    minato_scram:server_final(ServerFinal, vector_check()).

challenge(Nonce, Salt, Iterations) ->
    minato_scram_server:challenge(Nonce, base64:decode(Salt), Iterations).

generated_nonce() ->
    {Message, _Client} = minato_scram:client_first(?USERNAME, #{}),
    [_Header, Nonce] = binary:split(iolist_to_binary(Message), ~",r="),
    Nonce.

printable(Character) ->
    Character >= 16#21 andalso Character =< 16#7E andalso Character =/= $,.

exchange(Stored, Offered) ->
    Server = minato_scram_server:new(Stored),
    {ClientFirst, Client} = minato_scram:client_first(?USERNAME, #{}),
    {ServerFirst, Ready} = minato_scram_server:first(iolist_to_binary(ClientFirst), Server),
    {ClientFinal, Check} = minato_scram:client_final(ServerFirst, Offered, Client),
    case minato_scram_server:final(iolist_to_binary(ClientFinal), Ready) of
        {ok, ServerFinal} -> minato_scram:server_final(ServerFinal, Check);
        Error -> Error
    end.
