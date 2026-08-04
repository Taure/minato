-module(minato_auth_tests).
-moduledoc """
The authentication exchange driven message by message, without a socket.

`m:minato_auth` is a fold over what the server says, so a test can feed it the
decoded messages in order and read the replies. The SASL cases run against
`m:minato_scram_server`, which means the whole four message exchange is checked
here and not only the reply to each message in isolation.

The MD5 digest is checked against the formula PostgreSQL documents, spelled out
again in `documented_md5/3` rather than borrowed from the module under test, so
that a swap of the two concatenated halves fails.
""".

-include_lib("eunit/include/eunit.hrl").

-define(USER, ~"minato").
-define(PASSWORD, ~"pencil").
-define(SALT, <<1, 2, 3, 4>>).

%%----------------------------------------------------------------------
%% The end of the cycle
%%----------------------------------------------------------------------

authentication_ok_ends_the_cycle_test() ->
    ?assertEqual(authenticated, minato_auth:step(authentication_ok, state())).

authentication_ok_ends_the_cycle_without_a_password_test() ->
    State = minato_auth:init(#{user => ?USER}),
    ?assertEqual(authenticated, minato_auth:step(authentication_ok, State)).

%%----------------------------------------------------------------------
%% Cleartext
%%----------------------------------------------------------------------

cleartext_sends_the_password_test() ->
    {send, Reply, _State} = minato_auth:step(authentication_cleartext_password, state()),
    ?assertEqual({password, ?PASSWORD}, Reply).

cleartext_encodes_to_a_password_message_test() ->
    {send, Reply, _State} = minato_auth:step(authentication_cleartext_password, state()),
    ?assertEqual(
        <<$p, 11:32, "pencil", 0>>, iolist_to_binary(minato_protocol:encode(Reply))
    ).

cleartext_without_a_password_is_refused_test() ->
    State = minato_auth:init(#{user => ?USER}),
    ?assertError(
        {minato_auth, #{reason := password_required}},
        minato_auth:step(authentication_cleartext_password, State)
    ).

%%----------------------------------------------------------------------
%% MD5
%%----------------------------------------------------------------------

md5_matches_the_documented_formula_test() ->
    {send, {password, Digest}, _State} = md5_reply(),
    ?assertEqual(documented_md5(?USER, ?PASSWORD, ?SALT), Digest).

md5_matches_a_fixed_digest_test() ->
    {send, {password, Digest}, _State} = md5_reply(),
    ?assertEqual(~"md5943c7a0ac9df24a949ccc0ff5fc486d5", Digest).

md5_is_thirty_five_lowercase_bytes_test() ->
    {send, {password, <<"md5", Hex/binary>>}, _State} = md5_reply(),
    ?assertEqual(32, byte_size(Hex)),
    ?assertEqual(Hex, string:lowercase(Hex)).

md5_puts_the_password_before_the_user_name_test() ->
    Swapped = documented_md5(?PASSWORD, ?USER, ?SALT),
    {send, {password, Digest}, _State} = md5_reply(),
    ?assertNotEqual(Swapped, Digest).

md5_depends_on_the_salt_test() ->
    {send, {password, Digest}, _State} = md5_reply(),
    {send, {password, Other}, _Next} = minato_auth:step(
        {authentication_md5_password, <<5, 6, 7, 8>>}, state()
    ),
    ?assertNotEqual(Digest, Other).

md5_without_a_password_is_refused_test() ->
    State = minato_auth:init(#{user => ?USER}),
    ?assertError(
        {minato_auth, #{reason := password_required}},
        minato_auth:step({authentication_md5_password, ?SALT}, State)
    ).

%%----------------------------------------------------------------------
%% Choosing a SASL mechanism
%%----------------------------------------------------------------------

scram_is_chosen_when_it_is_the_only_offer_test() ->
    {send, {sasl_initial_response, Mechanism, _Data}, _State} = offer([~"SCRAM-SHA-256"]),
    ?assertEqual(~"SCRAM-SHA-256", Mechanism).

scram_is_chosen_over_the_channel_binding_variant_test() ->
    {send, {sasl_initial_response, Mechanism, _Data}, _State} = offer([
        ~"SCRAM-SHA-256-PLUS", ~"SCRAM-SHA-256"
    ]),
    ?assertEqual(~"SCRAM-SHA-256", Mechanism).

only_channel_binding_on_offer_is_refused_test() ->
    ?assertError(
        {minato_auth, #{reason := {no_supported_mechanism, [~"SCRAM-SHA-256-PLUS"]}}},
        offer([~"SCRAM-SHA-256-PLUS"])
    ).

no_mechanisms_on_offer_is_refused_test() ->
    ?assertError(
        {minato_auth, #{reason := {no_supported_mechanism, []}}},
        offer([])
    ).

an_unknown_mechanism_on_offer_is_refused_test() ->
    ?assertError(
        {minato_auth, #{reason := {no_supported_mechanism, [~"SCRAM-SHA-1"]}}},
        offer([~"SCRAM-SHA-1"])
    ).

the_initial_response_carries_the_client_first_message_test() ->
    {send, {sasl_initial_response, _Mechanism, Data}, _State} = offer([~"SCRAM-SHA-256"]),
    ?assertMatch(<<"n,,n=minato,r=", _Nonce/binary>>, iolist_to_binary(Data)).

%%----------------------------------------------------------------------
%% The whole SASL exchange
%%----------------------------------------------------------------------

a_scram_exchange_authenticates_test() ->
    ?assertEqual(authenticated, sasl_exchange(?PASSWORD, ?PASSWORD)).

a_scram_exchange_with_the_wrong_password_is_refused_by_the_server_test() ->
    ?assertEqual({error, invalid_proof}, sasl_exchange(?PASSWORD, ~"not the password")).

a_scram_exchange_survives_a_password_needing_preparation_test() ->
    Password = <<"pen", 16#C2, 16#A0, "cil">>,
    ?assertEqual(authenticated, sasl_exchange(Password, Password)).

a_scram_exchange_survives_a_password_that_is_not_utf8_test() ->
    ?assertEqual(authenticated, sasl_exchange(<<"pen", 16#FF, "cil">>, <<"pen", 16#FF, "cil">>)).

the_sasl_final_message_needs_no_reply_test() ->
    {Check, ServerFinal} = exchange_to_final(),
    ?assertMatch(
        {continue, _State}, minato_auth:step({authentication_sasl_final, ServerFinal}, Check)
    ).

a_forged_sasl_final_message_is_refused_test() ->
    {Check, _ServerFinal} = exchange_to_final(),
    Forged = <<"v=", (base64:encode(crypto:strong_rand_bytes(32)))/binary>>,
    ?assertError(
        {minato_scram, #{reason := server_signature_mismatch}},
        minato_auth:step({authentication_sasl_final, Forged}, Check)
    ).

%%----------------------------------------------------------------------
%% A server that tries to skip proving itself
%%----------------------------------------------------------------------

authentication_ok_instead_of_the_sasl_final_message_is_refused_test() ->
    {Check, _ServerFinal} = exchange_to_final(),
    ?assertError(
        {minato_auth, #{reason := sasl_exchange_unfinished}},
        minato_auth:step(authentication_ok, Check)
    ).

authentication_ok_straight_after_the_challenge_is_refused_test() ->
    {send, {sasl_initial_response, _Mechanism, _Data}, Started} = offer([~"SCRAM-SHA-256"]),
    ?assertError(
        {minato_auth, #{reason := sasl_exchange_unfinished}},
        minato_auth:step(authentication_ok, Started)
    ).

authentication_ok_is_accepted_once_the_server_has_proved_itself_test() ->
    {Check, ServerFinal} = exchange_to_final(),
    {continue, Done} = minato_auth:step({authentication_sasl_final, ServerFinal}, Check),
    ?assertEqual(authenticated, minato_auth:step(authentication_ok, Done)).

a_cleartext_demand_part_way_through_a_scram_exchange_is_refused_test() ->
    {send, {sasl_initial_response, _Mechanism, _Data}, Started} = offer([~"SCRAM-SHA-256"]),
    ?assertError(
        {minato_auth, #{reason := method_changed_mid_exchange}},
        minato_auth:step(authentication_cleartext_password, Started)
    ).

an_md5_demand_part_way_through_a_scram_exchange_is_refused_test() ->
    {Check, _ServerFinal} = exchange_to_final(),
    ?assertError(
        {minato_auth, #{reason := method_changed_mid_exchange}},
        minato_auth:step({authentication_md5_password, ?SALT}, Check)
    ).

restarting_the_sasl_exchange_part_way_through_is_refused_test() ->
    {send, {sasl_initial_response, _Mechanism, _Data}, Started} = offer([~"SCRAM-SHA-256"]),
    ?assertError(
        {minato_auth, #{reason := method_changed_mid_exchange}},
        minato_auth:step({authentication_sasl, [~"SCRAM-SHA-256"]}, Started)
    ).

a_refused_server_signature_leaves_the_exchange_unfinished_test() ->
    {Check, _ServerFinal} = exchange_to_final(),
    Forged = <<"v=", (base64:encode(crypto:strong_rand_bytes(32)))/binary>>,
    ?assertError(
        {minato_scram, #{reason := server_signature_mismatch}},
        minato_auth:step({authentication_sasl_final, Forged}, Check)
    ),
    ?assertError(
        {minato_auth, #{reason := sasl_exchange_unfinished}},
        minato_auth:step(authentication_ok, Check)
    ).

%%----------------------------------------------------------------------
%% SASL messages out of order
%%----------------------------------------------------------------------

a_sasl_continue_outside_an_exchange_is_refused_test() ->
    ?assertError(
        {minato_auth, #{reason := no_sasl_exchange_in_progress}},
        minato_auth:step({authentication_sasl_continue, ~"r=x,s=x,i=4096"}, state())
    ).

a_sasl_final_outside_an_exchange_is_refused_test() ->
    ?assertError(
        {minato_auth, #{reason := no_sasl_exchange_in_progress}},
        minato_auth:step({authentication_sasl_final, ~"v=x"}, state())
    ).

a_sasl_final_after_the_exchange_has_ended_is_refused_test() ->
    {Check, ServerFinal} = exchange_to_final(),
    {continue, Done} = minato_auth:step({authentication_sasl_final, ServerFinal}, Check),
    ?assertError(
        {minato_auth, #{reason := no_sasl_exchange_in_progress}},
        minato_auth:step({authentication_sasl_final, ServerFinal}, Done)
    ).

%%----------------------------------------------------------------------
%% Messages this module does not answer
%%----------------------------------------------------------------------

a_message_that_is_not_an_authentication_message_is_refused_test() ->
    ?assertError(
        {minato_auth, #{reason := unsupported_method}},
        minato_auth:step({ready_for_query, idle}, state())
    ).

an_error_response_is_the_callers_to_handle_test() ->
    ?assertError(
        {minato_auth, #{reason := unsupported_method}},
        minato_auth:step({error_response, #{code => ~"28P01", message => ~"failed"}}, state())
    ).

an_authentication_method_the_protocol_layer_does_not_model_never_arrives_test() ->
    ?assertError(
        {minato_protocol, #{reason := {unsupported_method, 7}}},
        minato_protocol:decode(<<$R, 8:32, 7:32>>)
    ).

%%----------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------

state() ->
    minato_auth:init(#{user => ?USER, password => ?PASSWORD}).

md5_reply() ->
    minato_auth:step({authentication_md5_password, ?SALT}, state()).

offer(Mechanisms) ->
    minato_auth:step({authentication_sasl, Mechanisms}, state()).

documented_md5(User, Password, Salt) ->
    Inner = hex(crypto:hash(md5, <<Password/binary, User/binary>>)),
    <<"md5", (hex(crypto:hash(md5, <<Inner/binary, Salt/binary>>)))/binary>>.

hex(Digest) ->
    binary:encode_hex(Digest, lowercase).

bytes(Data) when is_binary(Data) -> Data;
bytes(Data) when is_list(Data) -> iolist_to_binary(Data).

sasl_exchange(Stored, Offered) ->
    State = minato_auth:init(#{user => ?USER, password => Offered}),
    Server = minato_scram_server:new(Stored),
    {send, {sasl_initial_response, _Mechanism, First}, Started} = minato_auth:step(
        {authentication_sasl, [~"SCRAM-SHA-256"]}, State
    ),
    {ServerFirst, Ready} = minato_scram_server:first(bytes(First), Server),
    {send, {sasl_response, Final}, Check} = minato_auth:step(
        {authentication_sasl_continue, ServerFirst}, Started
    ),
    case minato_scram_server:final(bytes(Final), Ready) of
        {ok, ServerFinal} ->
            {continue, Done} = minato_auth:step({authentication_sasl_final, ServerFinal}, Check),
            minato_auth:step(authentication_ok, Done);
        Error ->
            Error
    end.

exchange_to_final() ->
    Server = minato_scram_server:new(?PASSWORD),
    {send, {sasl_initial_response, _Mechanism, First}, Started} = minato_auth:step(
        {authentication_sasl, [~"SCRAM-SHA-256"]}, state()
    ),
    {ServerFirst, Ready} = minato_scram_server:first(bytes(First), Server),
    {send, {sasl_response, Final}, Check} = minato_auth:step(
        {authentication_sasl_continue, ServerFirst}, Started
    ),
    {ok, ServerFinal} = minato_scram_server:final(bytes(Final), Ready),
    {Check, ServerFinal}.
