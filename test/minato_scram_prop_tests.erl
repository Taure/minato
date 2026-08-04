-module(minato_scram_prop_tests).
-moduledoc """
Properties of the SCRAM derivation and of what tampering with it does.

The exchange properties run `m:minato_scram` against `m:minato_scram_server`,
which is a separate reading of the same RFC from the other side. Agreement over
generated user names, passwords, salts and iteration counts is worth more than
the single published vector, because the vector fixes every input and cannot
show that a field was read rather than assumed.

The tampering properties are the point of the file. SCRAM's claim is that
neither side can be impersonated by anybody who does not hold the verifier, and
that reduces to a claim about the `AuthMessage`: it covers all three of the
earlier messages, so changing any byte of any of them has to break the
signatures computed over it. Those are stated here as properties over every
single byte position rather than as a handful of examples.

Two of them tamper with a decoded value and re-encode it rather than editing the
base64 text in place. Base64 leaves spare bits in its last character when the
value it carries is not a multiple of three bytes, so a text edit there can
decode to the byte for byte identical value, and a property phrased over the
text would be asserting that a message which did not really change still breaks.
The `p=` proof is also the one field the `AuthMessage` deliberately does not
cover, since it is the thing being proved, so it is tampered with separately
from the part that is covered.
""".

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% eqWAlizer: the PropEr macros expand to term(), so the functions that use them
%% cannot be given a useful type.
-eqwalizer({nowarn_function, prop_wrong_password_never_authenticates/0}).
-eqwalizer({nowarn_function, prop_tampered_server_first_never_authenticates/0}).
-eqwalizer({nowarn_function, prop_tampered_client_final_never_authenticates/0}).
-eqwalizer({nowarn_function, prop_tampered_server_final_never_verifies/0}).
-eqwalizer({nowarn_function, prop_server_nonce_must_extend_the_client_nonce/0}).
-eqwalizer({nowarn_function, prop_iteration_count_outside_the_bounds_is_rejected/0}).
-eqwalizer({nowarn_function, prop_client_first_is_well_formed/0}).
-eqwalizer({nowarn_function, prop_printable_ascii_is_prepared_unchanged/0}).
-eqwalizer({nowarn_function, prop_prepare_never_raises/0}).
-eqwalizer({nowarn_function, gen_password/0}).
-eqwalizer({nowarn_function, gen_username/0}).
-eqwalizer({nowarn_function, gen_salt/0}).
-eqwalizer({nowarn_function, gen_binary/0}).
-eqwalizer({nowarn_function, gen_printable_ascii/0}).

-define(NUMTESTS, 100).
-define(CHEAP_NUMTESTS, 500).
%% Every byte position of the server first message costs one PBKDF2 run.
-define(DERIVING_NUMTESTS, 20).

exchange_property_test_() ->
    {timeout, 300, [
        {"an exchange with a matching verifier authenticates", fun() ->
            check(prop_exchange_authenticates())
        end},
        {"an exchange with any other password does not", fun() ->
            check(prop_wrong_password_never_authenticates())
        end},
        {"the client first message is well formed", fun() ->
            check(prop_client_first_is_well_formed(), ?CHEAP_NUMTESTS)
        end}
    ]}.

tampering_property_test_() ->
    {timeout, 600, [
        {"changing any byte of the server first message breaks the exchange", fun() ->
            check(prop_tampered_server_first_never_authenticates(), ?DERIVING_NUMTESTS)
        end},
        {"changing any byte of the client final message breaks the exchange", fun() ->
            check(prop_tampered_client_final_never_authenticates())
        end},
        {"changing any byte of the server final message fails verification", fun() ->
            check(prop_tampered_server_final_never_verifies())
        end},
        {"a server nonce that does not extend the client nonce is rejected", fun() ->
            check(prop_server_nonce_must_extend_the_client_nonce())
        end},
        {"an iteration count outside the bounds is rejected", fun() ->
            check(prop_iteration_count_outside_the_bounds_is_rejected(), ?CHEAP_NUMTESTS)
        end}
    ]}.

saslprep_property_test_() ->
    {timeout, 300, [
        {"printable ASCII is prepared unchanged", fun() ->
            check(prop_printable_ascii_is_prepared_unchanged(), ?CHEAP_NUMTESTS)
        end},
        {"preparing arbitrary bytes never raises", fun() ->
            check(prop_prepare_never_raises(), ?CHEAP_NUMTESTS)
        end}
    ]}.

check(Prop) ->
    check(Prop, ?NUMTESTS).

check(Prop, Tests) ->
    ?assert(proper:quickcheck(Prop, [Tests, {to_file, user}])).

%%----------------------------------------------------------------------
%% The exchange
%%----------------------------------------------------------------------

prop_exchange_authenticates() ->
    ?FORALL(
        {Username, Password, Salt, Iterations},
        {gen_username(), gen_password(), gen_salt(), gen_iterations()},
        ok =:= exchange(Username, Password, Password, Salt, Iterations)
    ).

prop_wrong_password_never_authenticates() ->
    ?FORALL(
        {Username, Stored, Offered, Salt, Iterations},
        {gen_username(), gen_password(), gen_password(), gen_salt(), gen_iterations()},
        begin
            Same = minato_saslprep:prepare(Stored) =:= minato_saslprep:prepare(Offered),
            Result = exchange(Username, Stored, Offered, Salt, Iterations),
            case Same of
                true -> Result =:= ok;
                false -> Result =:= {error, invalid_proof}
            end
        end
    ).

prop_client_first_is_well_formed() ->
    ?FORALL(
        Username,
        gen_username(),
        begin
            {Message, _Client} = minato_scram:client_first(Username, #{}),
            <<"n,,n=", Rest/binary>> = iolist_to_binary(Message),
            [Name, Nonce] = binary:split(Rest, ~",r="),
            binary:match(Name, ~",") =:= nomatch andalso
                byte_size(Nonce) =:= 32 andalso
                binary:match(Nonce, ~",") =:= nomatch
        end
    ).

%%----------------------------------------------------------------------
%% Tampering
%%----------------------------------------------------------------------

prop_tampered_server_first_never_authenticates() ->
    ?FORALL(
        {Password, Salt, Iterations},
        {gen_password(), gen_salt(), gen_iterations()},
        begin
            Server = minato_scram_server:new(Password, #{salt => Salt, iterations => Iterations}),
            {ClientFirst, Client} = minato_scram:client_first(~"minato", #{}),
            {ServerFirst, Ready} = minato_scram_server:first(iolist_to_binary(ClientFirst), Server),
            every_flip(ServerFirst, fun(Tampered) ->
                ok =/= finish(Tampered, Password, Client, Ready)
            end)
        end
    ).

prop_tampered_client_final_never_authenticates() ->
    ?FORALL(
        {Password, Salt, Iterations},
        {gen_password(), gen_salt(), gen_iterations()},
        begin
            Server = minato_scram_server:new(Password, #{salt => Salt, iterations => Iterations}),
            {ClientFirst, Client} = minato_scram:client_first(~"minato", #{}),
            {ServerFirst, Ready} = minato_scram_server:first(iolist_to_binary(ClientFirst), Server),
            {ClientFinal, _Check} = minato_scram:client_final(ServerFirst, Password, Client),
            [WithoutProof, Encoded] = binary:split(iolist_to_binary(ClientFinal), ~",p="),
            every_flip(WithoutProof, fun(Tampered) ->
                not authenticates(refuses(<<Tampered/binary, ",p=", Encoded/binary>>, Ready))
            end) andalso
                every_flip(base64:decode(Encoded), fun(Tampered) ->
                    Forged = base64:encode(Tampered),
                    not authenticates(refuses(<<WithoutProof/binary, ",p=", Forged/binary>>, Ready))
                end)
        end
    ).

prop_tampered_server_final_never_verifies() ->
    ?FORALL(
        {Password, Salt, Iterations},
        {gen_password(), gen_salt(), gen_iterations()},
        begin
            Server = minato_scram_server:new(Password, #{salt => Salt, iterations => Iterations}),
            {ClientFirst, Client} = minato_scram:client_first(~"minato", #{}),
            {ServerFirst, Ready} = minato_scram_server:first(iolist_to_binary(ClientFirst), Server),
            {ClientFinal, Check} = minato_scram:client_final(ServerFirst, Password, Client),
            {ok, ServerFinal} = minato_scram_server:final(iolist_to_binary(ClientFinal), Ready),
            <<"v=", Encoded/binary>> = ServerFinal,
            every_flip(base64:decode(Encoded), fun(Tampered) ->
                ok =/= verifies(<<"v=", (base64:encode(Tampered))/binary>>, Check)
            end)
        end
    ).

prop_server_nonce_must_extend_the_client_nonce() ->
    ?FORALL(
        {Nonce, Salt},
        {gen_binary(), gen_salt()},
        begin
            {ClientFirst, Client} = minato_scram:client_first(~"minato", #{}),
            ClientNonce = client_nonce(ClientFirst),
            Offered = base64:encode(Nonce),
            Challenge = minato_scram_server:challenge(Offered, Salt, 4096),
            extends(Offered, ClientNonce) orelse
                {error, server_nonce_does_not_extend_client_nonce} =:=
                    rejects(Challenge, ~"pencil", Client)
        end
    ).

prop_iteration_count_outside_the_bounds_is_rejected() ->
    ?FORALL(
        {Iterations, Salt},
        {integer(-1000, 4095), gen_salt()},
        begin
            {ClientFirst, Client} = minato_scram:client_first(~"minato", #{}),
            Nonce = <<(client_nonce(ClientFirst))/binary, "server">>,
            Challenge = minato_scram_server:challenge(Nonce, Salt, Iterations),
            case rejects(Challenge, ~"pencil", Client) of
                {error, {iteration_count_below_minimum, _Count, 4096}} -> Iterations >= 0;
                {error, {iteration_count_not_a_number, _Count}} -> Iterations < 0;
                _Other -> false
            end
        end
    ).

%%----------------------------------------------------------------------
%% Preparation
%%----------------------------------------------------------------------

prop_printable_ascii_is_prepared_unchanged() ->
    ?FORALL(
        Password,
        gen_printable_ascii(),
        minato_saslprep:prepare(Password) =:= Password andalso
            minato_saslprep:normalise(Password) =:= {ok, Password}
    ).

prop_prepare_never_raises() ->
    ?FORALL(
        Password,
        gen_binary(),
        is_binary(minato_saslprep:prepare(Password))
    ).

%%----------------------------------------------------------------------
%% Running an exchange
%%----------------------------------------------------------------------

exchange(Username, Stored, Offered, Salt, Iterations) ->
    Server = minato_scram_server:new(Stored, #{salt => Salt, iterations => Iterations}),
    {ClientFirst, Client} = minato_scram:client_first(Username, #{}),
    {ServerFirst, Ready} = minato_scram_server:first(iolist_to_binary(ClientFirst), Server),
    finish(ServerFirst, Offered, Client, Ready).

finish(ServerFirst, Password, Client, Ready) ->
    try minato_scram:client_final(ServerFirst, Password, Client) of
        {ClientFinal, Check} ->
            case minato_scram_server:final(iolist_to_binary(ClientFinal), Ready) of
                {ok, ServerFinal} -> verifies(ServerFinal, Check);
                Error -> Error
            end
    catch
        error:{minato_scram, #{reason := Reason}} -> {error, Reason}
    end.

refuses(ClientFinal, Ready) ->
    try
        minato_scram_server:final(ClientFinal, Ready)
    catch
        error:_Reason -> {error, unreadable}
    end.

authenticates({ok, _ServerFinal}) -> true;
authenticates(_Refused) -> false.

extends(Offered, ClientNonce) ->
    byte_size(Offered) > byte_size(ClientNonce) andalso
        binary:longest_common_prefix([Offered, ClientNonce]) =:= byte_size(ClientNonce).

verifies(ServerFinal, Check) ->
    try
        minato_scram:server_final(ServerFinal, Check)
    catch
        error:{minato_scram, #{reason := Reason}} -> {error, Reason}
    end.

rejects(ServerFirst, Password, Client) ->
    try minato_scram:client_final(ServerFirst, Password, Client) of
        {_Message, _Check} -> accepted
    catch
        error:{minato_scram, #{reason := Reason}} -> {error, Reason}
    end.

client_nonce(ClientFirst) ->
    [_Header, Nonce] = binary:split(iolist_to_binary(ClientFirst), ~",r="),
    Nonce.

every_flip(Binary, Broken) ->
    lists:all(
        fun(Position) -> Broken(flip(Binary, Position)) end,
        lists:seq(0, byte_size(Binary) - 1)
    ).

flip(Binary, Position) ->
    <<Head:Position/binary, Byte, Tail/binary>> = Binary,
    <<Head/binary, (Byte bxor 1), Tail/binary>>.

%%----------------------------------------------------------------------
%% Generators
%%----------------------------------------------------------------------

gen_username() ->
    ?LET(Bytes, list(integer(16#21, 16#7E)), list_to_binary(Bytes)).

gen_password() ->
    ?LET(Bytes, list(integer(0, 255)), list_to_binary(Bytes)).

gen_printable_ascii() ->
    ?LET(Bytes, list(integer(16#20, 16#7E)), list_to_binary(Bytes)).

gen_binary() ->
    ?LET(Bytes, list(integer(0, 255)), list_to_binary(Bytes)).

gen_salt() ->
    ?LET(Bytes, vector(16, integer(0, 255)), list_to_binary(Bytes)).

gen_iterations() ->
    integer(4096, 5000).
