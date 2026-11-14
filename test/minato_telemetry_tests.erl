-module(minato_telemetry_tests).
-moduledoc """
What an event may carry of a failure, without a server to fail against.

`m:minato_telemetry_SUITE` asserts the events themselves. These assert the rule
that decides what goes into one.
""".

-include_lib("eunit/include/eunit.hrl").

-define(SECRET, ~"hunter2").

a_server_error_keeps_what_names_things_test() ->
    Fields = #{
        severity => ~"ERROR",
        severity_non_localised => ~"ERROR",
        code => ~"23505",
        message => <<"duplicate key value ", ?SECRET/binary>>,
        detail => <<"Key (email)=(", ?SECRET/binary, ") already exists.">>,
        hint => ?SECRET,
        where => ?SECRET,
        internal_query => ?SECRET,
        schema => ~"public",
        table => ~"users",
        column => ~"email",
        data_type => ~"text",
        constraint => ~"users_email_key",
        routine => ~"_bt_check_unique"
    },
    ?assertEqual(
        {pgsql_error, maps:without([message, detail, hint, where, internal_query], Fields)},
        minato_telemetry:reason({pgsql_error, Fields})
    ).

a_value_that_would_not_encode_is_redacted_test() ->
    ?assertEqual(
        {minato_codec, #{type => int4, reason => not_an_integer, value => redacted}},
        minato_telemetry:reason(
            {minato_codec, #{type => int4, reason => not_an_integer, value => ?SECRET}}
        )
    ).

bytes_that_could_not_be_read_are_redacted_test_() ->
    [
        ?_assertEqual(
            {Module, #{message => data_row, reason => malformed, data => redacted}},
            minato_telemetry:reason(
                {Module, #{message => data_row, reason => malformed, data => Data}}
            )
        )
     || Module <- [minato_protocol, minato_query],
        Data <- [?SECRET, {data_row, [?SECRET]}, [?SECRET], {3, ?SECRET}]
    ].

lengths_and_counts_are_kept_test_() ->
    [
        ?_assertEqual(Reason, minato_telemetry:reason(Reason))
     || Reason <- [
            {minato_protocol, #{
                message => frontend, reason => message_too_long, data => {$B, 1 bsl 31, 1 bsl 30}
            }},
            {minato_protocol, #{
                message => data_row, reason => column_count_mismatch, data => {2, 3}
            }},
            {minato_query, #{message => bind, reason => parameter_count_mismatch, data => {1, 2}}},
            {socket, closed},
            {pool, timeout},
            timeout
        ]
    ].

arguments_are_taken_out_of_a_stacktrace_test() ->
    Location = [{file, "minato_codec.erl"}, {line, 1}],
    ?assertEqual(
        [{minato_codec, encode, 3, Location}, {minato_query, bound, 4, Location}],
        minato_telemetry:frames([
            {minato_codec, encode, [23, ?SECRET, binary], Location},
            {minato_query, bound, 4, Location}
        ])
    ).

values_are_kept_when_asked_for_test_() ->
    {setup, fun() -> application:set_env(minato, log_values, true) end,
        fun(_) -> application:unset_env(minato, log_values) end, fun(_) ->
            Reason = {minato_codec, #{type => int4, reason => not_an_integer, value => ?SECRET}},
            Failed = {pgsql_error, #{code => ~"23505", detail => ?SECRET}},
            Frames = [{minato_codec, encode, [23, ?SECRET, binary], []}],
            [
                ?_assert(minato_telemetry:values()),
                ?_assertEqual(Reason, minato_telemetry:reason(Reason)),
                ?_assertEqual(Failed, minato_telemetry:reason(Failed)),
                ?_assertEqual(Frames, minato_telemetry:frames(Frames))
            ]
        end}.

values_are_off_unless_asked_for_test() ->
    ?assertNot(minato_telemetry:values()).
