-module(minato_protocol_frontend_tests).
-moduledoc """
Byte for byte tests of every frontend message against the documented format.

Every expected binary here is written out in full, length field included, rather
than computed. A length that counts the wrong bytes is the defect this file
exists to catch, and a test that computes the length the same way the encoder
does cannot catch it.
""".

-include_lib("eunit/include/eunit.hrl").

enc(Message) ->
    iolist_to_binary(minato_protocol:encode(Message)).

%%----------------------------------------------------------------------
%% Messages with no type byte
%%----------------------------------------------------------------------

startup_test() ->
    ?assertEqual(
        <<0, 0, 0, 21, 0, 3, 0, 0, "user", 0, "minato", 0, 0>>,
        enc({startup, #{~"user" => ~"minato"}})
    ).

startup_with_no_parameters_test() ->
    ?assertEqual(<<0, 0, 0, 9, 0, 3, 0, 0, 0>>, enc({startup, #{}})).

startup_carries_every_parameter_test() ->
    Parameters = #{
        ~"user" => ~"minato",
        ~"database" => ~"minato_test",
        ~"application_name" => ~"minato"
    },
    ?assertEqual(
        {startup, Parameters},
        minato_frontend_reader:read(enc({startup, Parameters}))
    ).

ssl_request_test() ->
    ?assertEqual(<<0, 0, 0, 8, 4, 210, 22, 47>>, enc(ssl_request)).

cancel_request_test() ->
    ?assertEqual(
        <<0, 0, 0, 16, 4, 210, 22, 46, 0, 0, 48, 57, 0, 1, 9, 50>>,
        enc({cancel_request, 12345, 67890})
    ).

%%----------------------------------------------------------------------
%% Authentication
%%----------------------------------------------------------------------

password_test() ->
    ?assertEqual(<<$p, 0, 0, 0, 11, "secret", 0>>, enc({password, ~"secret"})).

empty_password_test() ->
    ?assertEqual(<<$p, 0, 0, 0, 5, 0>>, enc({password, ~""})).

sasl_initial_response_test() ->
    ?assertEqual(
        <<$p, 0, 0, 0, 33, "SCRAM-SHA-256", 0, 0, 0, 0, 11, "n,,n=,r=abc">>,
        enc({sasl_initial_response, ~"SCRAM-SHA-256", ~"n,,n=,r=abc"})
    ).

sasl_initial_response_with_no_data_test() ->
    ?assertEqual(
        <<$p, 0, 0, 0, 22, "SCRAM-SHA-256", 0, 255, 255, 255, 255>>,
        enc({sasl_initial_response, ~"SCRAM-SHA-256", null})
    ).

sasl_response_test() ->
    ?assertEqual(
        <<$p, 0, 0, 0, 16, "c=biws,r=abc">>,
        enc({sasl_response, ~"c=biws,r=abc"})
    ).

%%----------------------------------------------------------------------
%% Simple query
%%----------------------------------------------------------------------

query_test() ->
    ?assertEqual(<<$Q, 0, 0, 0, 13, "SELECT 1", 0>>, enc({query, ~"SELECT 1"})).

query_accepts_iodata_test() ->
    ?assertEqual(
        enc({query, ~"SELECT 1"}),
        enc({query, [~"SELECT", " ", [$1]]})
    ).

%%----------------------------------------------------------------------
%% Extended query
%%----------------------------------------------------------------------

parse_test() ->
    ?assertEqual(
        <<$P, 0, 0, 0, 21, 0, "SELECT $1", 0, 0, 1, 0, 0, 0, 23>>,
        enc({parse, ~"", ~"SELECT $1", [23]})
    ).

parse_with_no_parameter_types_test() ->
    ?assertEqual(
        <<$P, 0, 0, 0, 18, "s1", 0, "SELECT 1", 0, 0, 0>>,
        enc({parse, ~"s1", ~"SELECT 1", []})
    ).

bind_test() ->
    ?assertEqual(
        <<$B, 0, 0, 0, 26, 0, "s1", 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 4, 0, 0, 0, 42, 0, 1, 0, 1>>,
        enc({bind, ~"", ~"s1", [binary], [<<0, 0, 0, 42>>], [binary]})
    ).

bind_with_a_null_parameter_test() ->
    ?assertEqual(
        <<$B, 0, 0, 0, 18, "p1", 0, 0, 0, 0, 0, 1, 255, 255, 255, 255, 0, 0>>,
        enc({bind, ~"p1", ~"", [], [null], []})
    ).

bind_with_no_parameters_test() ->
    ?assertEqual(
        <<$B, 0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0>>,
        enc({bind, ~"", ~"", [], [], []})
    ).

bind_writes_a_text_format_code_as_zero_test() ->
    ?assertEqual(
        <<$B, 0, 0, 0, 20, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, "42", 0, 0>>,
        enc({bind, ~"", ~"", [text], [~"42"], []})
    ).

bind_accepts_a_parameter_as_iodata_test() ->
    ?assertEqual(
        enc({bind, ~"", ~"", [text], [~"42"], []}),
        enc({bind, ~"", ~"", [text], [[$4, "2"]], []})
    ).

describe_statement_test() ->
    ?assertEqual(<<$D, 0, 0, 0, 8, $S, "s1", 0>>, enc({describe, statement, ~"s1"})).

describe_portal_test() ->
    ?assertEqual(<<$D, 0, 0, 0, 6, $P, 0>>, enc({describe, portal, ~""})).

execute_test() ->
    ?assertEqual(<<$E, 0, 0, 0, 9, 0, 0, 0, 0, 0>>, enc({execute, ~"", 0})).

execute_with_a_row_limit_test() ->
    ?assertEqual(<<$E, 0, 0, 0, 11, "p1", 0, 0, 0, 0, 100>>, enc({execute, ~"p1", 100})).

close_statement_test() ->
    ?assertEqual(<<$C, 0, 0, 0, 8, $S, "s1", 0>>, enc({close, statement, ~"s1"})).

close_portal_test() ->
    ?assertEqual(<<$C, 0, 0, 0, 6, $P, 0>>, enc({close, portal, ~""})).

%%----------------------------------------------------------------------
%% Messages with an empty payload
%%----------------------------------------------------------------------

sync_test() ->
    ?assertEqual(<<$S, 0, 0, 0, 4>>, enc(sync)).

flush_test() ->
    ?assertEqual(<<$H, 0, 0, 0, 4>>, enc(flush)).

terminate_test() ->
    ?assertEqual(<<$X, 0, 0, 0, 4>>, enc(terminate)).

%%----------------------------------------------------------------------
%% Every message declares its own length
%%----------------------------------------------------------------------

declared_length_matches_the_bytes_test_() ->
    [
        {lists:flatten(io_lib:format("~p", [Message])), fun() ->
            check_length(Message, enc(Message))
        end}
     || Message <- samples()
    ].

check_length({startup, _}, Bytes) -> declared(Bytes, 0);
check_length(ssl_request, Bytes) -> declared(Bytes, 0);
check_length({cancel_request, _, _}, Bytes) -> declared(Bytes, 0);
check_length(_Message, Bytes) -> declared(Bytes, 1).

declared(Bytes, Offset) ->
    <<_:Offset/binary, Length:32, _/binary>> = Bytes,
    ?assertEqual(byte_size(Bytes) - Offset, Length).

samples() ->
    [
        {startup, #{~"user" => ~"minato", ~"database" => ~"minato_test"}},
        ssl_request,
        {cancel_request, 1, 2},
        {password, ~"secret"},
        {sasl_initial_response, ~"SCRAM-SHA-256", ~"n,,n=,r=abc"},
        {sasl_initial_response, ~"SCRAM-SHA-256", null},
        {sasl_response, ~"c=biws"},
        {query, ~"SELECT 1"},
        {parse, ~"s1", ~"SELECT $1::int4", [23]},
        {bind, ~"p1", ~"s1", [binary, text], [<<1>>, null], [binary]},
        {describe, statement, ~"s1"},
        {describe, portal, ~"p1"},
        {execute, ~"p1", 100},
        sync,
        flush,
        {close, statement, ~"s1"},
        {close, portal, ~"p1"},
        terminate
    ].
