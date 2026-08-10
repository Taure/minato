-module(minato_differential_SUITE).
-moduledoc """
Differential tests: minato's codecs against a known good implementation and
against PostgreSQL itself.

An oracle proves agreement, not correctness, so this suite uses two references
and keeps them separate.

## The oracle

`pg_types` is a test profile dependency, called and compared with, never read
and never shipped. For every type and every corpus value, minato's binary
encoding must be byte identical to `pg_types`', and the two must decode the
server's own bytes to the same value once the shape difference between them is
mapped away by `m:minato_oracle`.

## The server

`pg_types` cannot settle a disagreement and has no text path at all, so every
case also goes to a real PostgreSQL. `m:minato_pg_raw` replaces the type
registry entry for the OID under test, which turns the driver into a pipe:
minato's bytes are what the server parses with its `recv` function, and the
server's `send` output is what minato decodes. Four things are then true or the
case fails:

- minato's binary encoding is byte identical to the server's own, except where
  the server normalises the value as it parses it
- decoding the server's binary output gives the value back
- decoding the server's text output gives the same value back
- the server parses minato's text encoding to the same value

## Disagreements

A disagreement is a result, not a failure to paper over. Every one is decided
against the server and the documentation, written down in `known/3` with which
implementation is right, and counted. A disagreement that is not in that list
fails the run, so the list can only grow deliberately.
""".

-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    fixed_corpus/1,
    generated_corpus/1,
    pg_types_loses_numeric_precision/1,
    pg_types_writes_a_dimension_for_an_empty_array/1,
    pg_types_pads_numeric_with_a_zero_digit/1,
    pg_types_reads_date_infinity_as_a_date/1,
    pg_types_leaks_a_negative_seconds_field/1,
    pg_types_cannot_decode_the_end_of_day/1,
    numeric_specials_ignore_display_scale/1,
    minato_encodes_a_quiet_nan/1,
    minato_narrows_float4_read_from_text/1,
    coverage/1
]).

-define(SEED, 20260804).
-define(TALLY, {?MODULE, tally}).

-doc "One place where two implementations, or an implementation and the server, differ.".
-type finding() :: #{
    check := atom(),
    type := minato_oid:name() | {array, minato_oid:name()},
    value := term(),
    detail := #{atom() => term()}
}.

-doc "How much of the corpus ran, keyed by what is being counted.".
-type counts() :: #{term() => integer()}.

-spec all() -> [atom() | {group, atom()}].
all() ->
    [{group, corpus}, {group, findings}, coverage].

-spec groups() -> [{atom(), [atom()], [atom()]}].
groups() ->
    [
        {corpus, [sequence], [fixed_corpus, generated_corpus]},
        {findings, [sequence], [
            pg_types_loses_numeric_precision,
            pg_types_writes_a_dimension_for_an_empty_array,
            pg_types_pads_numeric_with_a_zero_digit,
            pg_types_reads_date_infinity_as_a_date,
            pg_types_leaks_a_negative_seconds_field,
            pg_types_cannot_decode_the_end_of_day,
            numeric_specials_ignore_display_scale,
            minato_encodes_a_quiet_nan,
            minato_narrows_float4_read_from_text
        ]}
    ].

-spec init_per_suite(ct_suite:ct_config()) -> ct_suite:ct_config() | {skip, term()}.
init_per_suite(Config) ->
    case minato_pg:start() of
        {skip, Reason} ->
            {skip, Reason};
        ok ->
            ok = minato_pg:patch([Oid || #{oid := Oid} <- minato_corpus:types()]),
            Config
    end.

-spec end_per_suite(ct_suite:ct_config()) -> ok.
end_per_suite(_Config) ->
    _ = [persistent_term:erase({?TALLY, Label}) || Label <- [fixed, generated]],
    ok.

%%----------------------------------------------------------------------
%% The corpus
%%----------------------------------------------------------------------

-doc "Every hand written awkward value, for every type.".
-spec fixed_corpus(ct_suite:ct_config()) -> ok.
fixed_corpus(_Config) ->
    run(fixed, fun minato_corpus:fixed/1).

-doc "A deterministic generated corpus, for every type.".
-spec generated_corpus(ct_suite:ct_config()) -> ok.
generated_corpus(_Config) ->
    Scalars = count("MINATO_DIFF_SCALAR_CASES", 1000),
    Arrays = count("MINATO_DIFF_ARRAY_CASES", 400),
    run(generated, fun(Entry) ->
        minato_corpus:generate(Entry, cases_for(Entry, Scalars, Arrays), ?SEED)
    end).

-spec cases_for(minato_corpus:entry(), non_neg_integer(), non_neg_integer()) -> non_neg_integer().
cases_for(#{kind := scalar}, Scalars, _Arrays) -> Scalars;
cases_for(#{kind := array}, _Scalars, Arrays) -> Arrays.

-spec count(string(), pos_integer()) -> pos_integer().
count(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Value -> list_to_integer(Value)
    end.

-spec run(atom(), fun((minato_corpus:entry()) -> [minato_corpus:value_case()])) -> ok.
run(Label, Cases) ->
    Results = [check_type(Entry, Cases(Entry)) || Entry <- minato_corpus:types()],
    Findings = concat([Found || {Found, _Counts} <- Results]),
    Counts = merge([Counts || {_Found, Counts} <- Results]),
    {Known, Unknown} = classify(Findings),
    tally(Label, Counts, Known),
    report(Label, Counts, Known, Unknown),
    ?assertEqual([], Unknown),
    ok.

-spec check_type(minato_corpus:entry(), [minato_corpus:value_case()]) ->
    {[finding()], counts()}.
check_type(Entry, Cases) ->
    Findings = concat([check_case(Entry, Case) || Case <- Cases]),
    #{name := Name} = Entry,
    Counts = #{
        {cases, Name} => length(Cases),
        cases => length(Cases),
        checks => length(Cases) * 6
    },
    {Findings, Counts}.

-spec check_case(minato_corpus:entry(), minato_corpus:value_case()) -> [finding()].
check_case(Entry, Case) ->
    #{oid := Oid, sql := Sql} = Entry,
    #{value := Value, opts := Opts} = Case,
    Binary = minato_corpus:encoded(Oid, Value, binary, Opts),
    Text = minato_corpus:encoded(Oid, Value, text, Opts),
    case minato_pg:roundtrip(Sql, Binary) of
        {error, Reason} ->
            [finding(server_rejected_binary, Entry, Case, #{bytes => Binary, reason => Reason})];
        {ok, ServerBinary, ServerText} ->
            server_checks(Entry, Case, Binary, ServerBinary, ServerText) ++
                oracle_checks(Entry, Case, Binary, ServerBinary) ++
                text_input_check(Entry, Case, Text, ServerBinary)
    end.

-spec server_checks(
    minato_corpus:entry(), minato_corpus:value_case(), binary(), binary(), binary()
) -> [finding()].
server_checks(Entry, Case, Binary, ServerBinary, ServerText) ->
    #{oid := Oid} = Entry,
    #{expected := Expected, opts := Opts} = Case,
    canonical(Entry, Case, Binary, ServerBinary) ++
        decoded(binary_decode, Entry, Case, Oid, ServerBinary, binary, Opts, Expected) ++
        decoded(text_decode, Entry, Case, Oid, ServerText, text, Opts, Expected).

-spec canonical(minato_corpus:entry(), minato_corpus:value_case(), binary(), binary()) ->
    [finding()].
canonical(_Entry, _Case, Bytes, Bytes) ->
    [];
canonical(Entry, Case, Bytes, ServerBytes) ->
    [finding(binary_encode, Entry, Case, #{minato => Bytes, server => ServerBytes})].

-spec decoded(
    atom(),
    minato_corpus:entry(),
    minato_corpus:value_case(),
    minato_oid:oid(),
    binary(),
    minato_codec:format(),
    minato_codec:opts(),
    term()
) -> [finding()].
decoded(Check, Entry, Case, Oid, Bytes, Format, Opts, Expected) ->
    try minato_codec:decode(Oid, Bytes, Format, Opts) of
        Expected -> [];
        Other -> [finding(Check, Entry, Case, #{minato => Other, expected => Expected})]
    catch
        Class:Reason ->
            [finding(Check, Entry, Case, #{raised => {Class, Reason}, bytes => Bytes})]
    end.

-spec text_input_check(minato_corpus:entry(), minato_corpus:value_case(), binary(), binary()) ->
    [finding()].
text_input_check(Entry, Case, Text, ServerBinary) ->
    #{sql := Sql} = Entry,
    case minato_pg:from_text(Sql, Text) of
        {ok, ServerBinary} ->
            [];
        {ok, Other} ->
            [finding(text_encode, Entry, Case, #{from_text => Other, from_binary => ServerBinary})];
        {error, Reason} ->
            [finding(text_encode, Entry, Case, #{text => Text, reason => Reason})]
    end.

-spec oracle_checks(minato_corpus:entry(), minato_corpus:value_case(), binary(), binary()) ->
    [finding()].
oracle_checks(Entry, Case, Binary, ServerBinary) ->
    oracle_encode_check(Entry, Case, Binary) ++ oracle_decode_check(Entry, Case, ServerBinary).

-spec oracle_encode_check(minato_corpus:entry(), minato_corpus:value_case(), binary()) ->
    [finding()].
oracle_encode_check(Entry, Case, Binary) ->
    #{value := Value} = Case,
    #{oid := Oid} = Entry,
    case minato_oracle:encode(Entry, Value, minato_pg:type_info(Oid)) of
        {ok, Binary} -> [];
        {ok, Other} -> [finding(oracle_encode, Entry, Case, #{minato => Binary, oracle => Other})];
        {unsupported, Reason} -> [finding(oracle_encode, Entry, Case, #{unsupported => Reason})];
        {failed, Reason} -> [finding(oracle_encode, Entry, Case, #{raised => Reason})]
    end.

-spec oracle_decode_check(minato_corpus:entry(), minato_corpus:value_case(), binary()) ->
    [finding()].
oracle_decode_check(Entry, Case, ServerBinary) ->
    #{oid := Oid} = Entry,
    #{opts := Opts} = Case,
    Mine = minato_codec:decode(Oid, ServerBinary, binary, Opts),
    case minato_oracle:decode(Entry, ServerBinary, Opts, minato_pg:type_info(Oid)) of
        {ok, Mine} ->
            [];
        {ok, Other} ->
            [finding(oracle_decode, Entry, Case, #{minato => Mine, oracle => Other})];
        {unsupported, Reason} ->
            [finding(oracle_decode, Entry, Case, #{unsupported => Reason})];
        {failed, Reason} ->
            [finding(oracle_decode, Entry, Case, #{minato => Mine, raised => Reason})]
    end.

-spec finding(atom(), minato_corpus:entry(), minato_corpus:value_case(), #{atom() => term()}) ->
    finding().
finding(Check, #{name := Name}, #{value := Value}, Detail) ->
    #{check => Check, type => Name, value => Value, detail => Detail}.

%%----------------------------------------------------------------------
%% Which disagreements are already understood
%%----------------------------------------------------------------------

-spec classify([finding()]) -> {[{term(), finding()}], [finding()]}.
classify([]) ->
    {[], []};
classify([Finding | Rest]) ->
    {Known, Unknown} = classify(Rest),
    #{check := Check, type := Type, detail := Detail} = Finding,
    case known(Check, Type, Detail) of
        {yes, Reason} -> {[{Reason, Finding} | Known], Unknown};
        no -> {Known, [Finding | Unknown]}
    end.

-spec concat([[finding()]]) -> [finding()].
concat([]) -> [];
concat([Head | Rest]) -> Head ++ concat(Rest).

-doc """
The disagreements that are understood, with which implementation is right.

Anything not on this list fails the run.

Two entries cover the same finding in two shapes, because one disagreement is
sensitive to the OTP version the suite runs on. `pg_types` reads the reserved
`date` minimum as an ordinary calendar date roughly 5.8 million years BC, and
`calendar:gregorian_days_to_date/1` only started answering for days before year
zero in OTP 29. So the same `pg_types` code raises `function_clause` on OTP 28
and answers a date on OTP 29, and the run records
`oracle_cannot_decode_date_infinity` or `oracle_reads_date_infinity_as_a_date`
accordingly. Neither is minato's defect and neither is a reason to stop testing
the value: the reserved minimum is `-infinity`, not a date, on every version.
""".
-spec known(atom(), term(), #{atom() => term()}) -> {yes, atom()} | no.
known(text_encode, Type, #{from_text := Text, from_binary := Binary}) when
    is_binary(Text),
    is_binary(Binary),
    Type =:= float4 orelse Type =:= float8 orelse
        Type =:= {array, float4} orelse Type =:= {array, float8}
->
    nan_payload(Type, Text, Binary);
known(oracle_encode, Type, #{unsupported := no_null_encoding}) when
    Type =:= {array, bool};
    Type =:= {array, bytea};
    Type =:= {array, int2};
    Type =:= {array, int4};
    Type =:= {array, int8};
    Type =:= {array, float4};
    Type =:= {array, float8};
    Type =:= {array, numeric};
    Type =:= {array, text};
    Type =:= {array, varchar};
    Type =:= {array, json};
    Type =:= {array, jsonb};
    Type =:= {array, uuid};
    Type =:= {array, date};
    Type =:= {array, time};
    Type =:= {array, timestamp};
    Type =:= {array, timestamptz}
->
    {yes, oracle_cannot_encode_null};
known(oracle_encode, Type, #{unsupported := no_microsecond_input}) when
    Type =:= time;
    Type =:= timestamp;
    Type =:= timestamptz;
    Type =:= {array, time};
    Type =:= {array, timestamp};
    Type =:= {array, timestamptz}
->
    {yes, oracle_has_no_microsecond_input};
known(oracle_encode, Type, #{unsupported := no_date_infinity}) when
    Type =:= date; Type =:= {array, date}
->
    {yes, oracle_cannot_encode_date_infinity};
known(oracle_decode, numeric, #{minato := Minato, oracle := Oracle}) ->
    numeric_decode_difference(Minato, Oracle);
known(oracle_decode, {array, numeric}, #{minato := Minato, oracle := Oracle}) when
    is_list(Minato), is_list(Oracle)
->
    worst([
        numeric_decode_difference(Mine, Theirs)
     || {Mine, Theirs} <- zip(Minato, Oracle), Mine =/= Theirs
    ]);
known(oracle_decode, date, #{minato := Minato, raised := {error, function_clause}}) when
    Minato =:= infinity; Minato =:= neg_infinity
->
    {yes, oracle_cannot_decode_date_infinity};
known(oracle_decode, {array, date}, #{minato := Minato, raised := {error, function_clause}}) when
    is_list(Minato)
->
    date_infinity_in_array(Minato, oracle_cannot_decode_date_infinity);
known(oracle_decode, Type, #{minato := Minato}) when
    Type =:= date, Minato =:= infinity;
    Type =:= date, Minato =:= neg_infinity
->
    {yes, oracle_reads_date_infinity_as_a_date};
known(oracle_decode, {array, date}, #{minato := Minato}) when is_list(Minato) ->
    date_infinity_in_array(Minato, oracle_reads_date_infinity_as_a_date);
known(oracle_encode, Type, #{minato := Minato, oracle := Oracle}) when
    Type =:= numeric orelse Type =:= {array, numeric}, is_binary(Minato), is_binary(Oracle)
->
    numeric_encode_difference(Minato, Oracle);
known(oracle_encode, {array, _}, #{minato := Minato, oracle := Oracle}) when
    is_binary(Minato), is_binary(Oracle)
->
    empty_array_difference(Minato, Oracle);
known(binary_encode, Type, #{minato := Minato, server := Server}) when
    Type =:= numeric orelse Type =:= {array, numeric}, is_binary(Minato), is_binary(Server)
->
    special_scale_difference(Minato, Server);
known(binary_encode, Type, _Detail) when Type =:= jsonb; Type =:= {array, jsonb} ->
    {yes, server_reserialises_jsonb};
known(oracle_decode, Type, #{raised := {error, function_clause}}) when
    Type =:= time; Type =:= {array, time}
->
    {yes, oracle_cannot_decode_the_end_of_day};
known(_Check, _Type, _Detail) ->
    no.

-spec date_infinity_in_array([term()], atom()) -> {yes, atom()} | no.
date_infinity_in_array(Values, Reason) ->
    case lists:member(infinity, Values) orelse lists:member(neg_infinity, Values) of
        true -> {yes, Reason};
        false -> no
    end.

-doc """
Whether the oracle's float carries the same value as minato's exact decimal.

A float that lands on the same decimal has only lost the display scale, which is
a representation choice. A float that lands somewhere else has lost the value,
and no caller can get it back.
""".
-spec numeric_decode_difference(term(), term()) -> {yes, atom()} | no.
numeric_decode_difference(Decimal, {approximate_number, Number}) when
    is_binary(Decimal), is_number(Number)
->
    case decimal_value(Decimal) =:= decimal_value(number_text(Number)) of
        true -> {yes, oracle_decodes_numeric_as_float};
        false -> {yes, oracle_loses_numeric_precision}
    end;
numeric_decode_difference(_Minato, _Oracle) ->
    no.

-spec number_text(number()) -> binary().
number_text(Number) when is_integer(Number) -> integer_to_binary(Number);
number_text(Number) -> float_to_binary(Number, [short]).

-doc "A decimal string as an exact `{Mantissa, PowerOfTen}` pair.".
-spec decimal_value(binary()) -> {integer(), integer()}.
decimal_value(<<$-, Body/binary>>) ->
    {Mantissa, Exponent} = decimal_value(Body),
    {-Mantissa, Exponent};
decimal_value(Body) ->
    {Digits, Exponent} = split_exponent(Body),
    {Integer, Fraction} = split_point(Digits),
    All = <<Integer/binary, Fraction/binary>>,
    trim_zeros(binary_to_integer(<<$0, All/binary>>), Exponent - byte_size(Fraction)).

-spec split_exponent(binary()) -> {binary(), integer()}.
split_exponent(Bin) ->
    case binary:split(Bin, [~"e", ~"E"]) of
        [Digits] -> {Digits, 0};
        [Digits, <<$+, Exponent/binary>>] -> {Digits, binary_to_integer(Exponent)};
        [Digits, Exponent] -> {Digits, binary_to_integer(Exponent)}
    end.

-spec split_point(binary()) -> {binary(), binary()}.
split_point(Bin) ->
    case binary:split(Bin, ~".") of
        [Integer] -> {Integer, ~""};
        [Integer, Fraction] -> {Integer, Fraction}
    end.

-spec trim_zeros(integer(), integer()) -> {integer(), integer()}.
trim_zeros(0, _Exponent) ->
    {0, 0};
trim_zeros(Mantissa, Exponent) when Mantissa rem 10 =:= 0 ->
    trim_zeros(Mantissa div 10, Exponent + 1);
trim_zeros(Mantissa, Exponent) ->
    {Mantissa, Exponent}.

-spec zip([term()], [term()]) -> [{term(), term()}].
zip([], _Other) -> [];
zip(_Mine, []) -> [];
zip([Mine | Rest], [Theirs | OtherRest]) -> [{Mine, Theirs} | zip(Rest, OtherRest)].

-doc """
Whether two encodings of the same float differ only in the bits of a NaN.

IEEE 754 says nothing about the payload a NaN gets when one is made from the
string "NaN", so a server whose C library writes `7fffffff` and one that writes
`7fc00000` are both right and both mean NaN. The two are told apart from a real
disagreement by decoding them: every NaN decodes to the atom, so bytes that
differ and values that do not is the payload and nothing else.
""".
-spec nan_payload(minato_oid:name() | {array, minato_oid:name()}, binary(), binary()) ->
    {yes, atom()} | no.
nan_payload(Type, Text, Binary) ->
    Oid = minato_oid:oid(Type),
    case {value(Oid, Text), value(Oid, Binary)} of
        {{ok, Same}, {ok, Same}} -> {yes, nan_payloads_are_not_specified};
        _Really_different -> no
    end.

-spec value(minato_oid:oid(), binary()) -> {ok, term()} | error.
value(Oid, Bytes) ->
    try
        {ok, minato_codec:decode(Oid, Bytes, binary, #{})}
    catch
        _Class:_Reason -> error
    end.

-spec worst([{yes, atom()} | no]) -> {yes, atom()} | no.
worst([]) ->
    no;
worst(Outcomes) ->
    case lists:member(no, Outcomes) of
        true ->
            no;
        false ->
            case lists:member({yes, oracle_loses_numeric_precision}, Outcomes) of
                true -> {yes, oracle_loses_numeric_precision};
                false -> {yes, oracle_decodes_numeric_as_float}
            end
    end.

-spec numeric_encode_difference(binary(), binary()) -> {yes, atom()} | no.
numeric_encode_difference(Minato, Oracle) when byte_size(Oracle) > byte_size(Minato) ->
    {yes, oracle_pads_numeric_with_a_zero_digit};
numeric_encode_difference(Minato, Oracle) ->
    special_scale_difference(Minato, Oracle).

-spec special_scale_difference(binary(), binary()) -> {yes, atom()} | no.
special_scale_difference(Minato, Other) when byte_size(Minato) =:= byte_size(Other) ->
    case scales_only(Minato, Other, 0) of
        true -> {yes, display_scale_is_meaningless_for_numeric_infinity};
        false -> no
    end;
special_scale_difference(_Minato, _Other) ->
    no.

-spec scales_only(binary(), binary(), non_neg_integer()) -> boolean().
scales_only(Minato, _Other, Index) when Index >= byte_size(Minato) ->
    true;
scales_only(Minato, Other, Index) ->
    case binary:at(Minato, Index) =:= binary:at(Other, Index) of
        true ->
            scales_only(Minato, Other, Index + 1);
        false ->
            display_scale_byte(Minato, Index) andalso display_scale_byte(Other, Index) andalso
                scales_only(Minato, Other, Index + 1)
    end.

-spec display_scale_byte(binary(), non_neg_integer()) -> boolean().
display_scale_byte(Bin, Index) ->
    special_sign_at(Bin, Index - 2) orelse special_sign_at(Bin, Index - 3).

-spec special_sign_at(binary(), integer()) -> boolean().
special_sign_at(Bin, Offset) when Offset >= 0, Offset + 2 =< byte_size(Bin) ->
    Sign = binary:part(Bin, Offset, 2),
    Sign =:= <<16#D000:16>> orelse Sign =:= <<16#F000:16>>;
special_sign_at(_Bin, _Offset) ->
    false.

-spec empty_array_difference(binary(), binary()) -> {yes, atom()} | no.
empty_array_difference(<<0:32, _Flags:32, Element:32>>, <<1:32, _F:32, Element:32, 0:32, 1:32>>) ->
    {yes, oracle_writes_a_dimension_for_an_empty_array};
empty_array_difference(_Minato, _Oracle) ->
    no.

%%----------------------------------------------------------------------
%% Reporting
%%----------------------------------------------------------------------

-spec merge([counts()]) -> counts().
merge(Maps) ->
    merge(Maps, #{}).

-spec merge([counts()], counts()) -> counts().
merge([], Acc) ->
    Acc;
merge([Map | Rest], Acc) ->
    merge(Rest, maps:merge_with(fun(_Key, A, B) -> A + B end, Acc, Map)).

-spec tally(atom(), counts(), [{term(), finding()}]) -> ok.
tally(Label, Counts, Known) ->
    Reasons = frequencies([Reason || {Reason, _Finding} <- Known]),
    persistent_term:put({?TALLY, Label}, #{counts => Counts, reasons => Reasons}),
    ok.

-spec corpus_size(atom()) -> integer().
corpus_size(Label) ->
    case persistent_term:get({?TALLY, Label}, #{}) of
        #{counts := #{cases := Cases}} when is_integer(Cases) -> Cases;
        _Missing -> 0
    end.

-spec tallied(atom()) -> term().
tallied(Label) ->
    persistent_term:get({?TALLY, Label}, #{}).

-spec frequencies([term()]) -> counts().
frequencies(Terms) ->
    merge([#{Term => 1} || Term <- Terms]).

-spec report(atom(), counts(), [{term(), finding()}], [finding()]) -> ok.
report(Label, Counts, Known, Unknown) ->
    ct:pal(
        "~p corpus: ~p values over ~p types, ~p checks~n"
        "known disagreements: ~p~n"
        "new disagreements: ~p",
        [
            Label,
            maps:get(cases, Counts, 0),
            length(minato_corpus:types()),
            maps:get(checks, Counts, 0),
            frequencies([Reason || {Reason, _Finding} <- Known]),
            length(Unknown)
        ]
    ),
    dump(Label, Unknown).

-spec dump(atom(), [finding()]) -> ok.
dump(_Label, []) ->
    ok;
dump(Label, Unknown) ->
    _ = [ct:pal("unexpected disagreement: ~p", [Finding]) || Finding <- lists:sublist(Unknown, 25)],
    write_dump(os:getenv("MINATO_DIFF_DUMP_DIR"), Label, Unknown).

-spec write_dump(false | string(), atom(), [finding()]) -> ok.
write_dump(false, _Label, _Unknown) ->
    ok;
write_dump(Dir, Label, Unknown) ->
    File = filename:join(Dir, atom_to_list(Label) ++ "_disagreements.txt"),
    ok = file:write_file(File, [io_lib:format("~p~n", [Finding]) || Finding <- Unknown]),
    ct:pal("new disagreements written to ~s", [File]).

-doc "Print the totals the suite is claimed to prove, and assert the coverage.".
-spec coverage(ct_suite:ct_config()) -> ok.
coverage(_Config) ->
    Types = minato_corpus:types(),
    Scalars = [Entry || #{kind := scalar} = Entry <- Types],
    Arrays = [Entry || #{kind := array} = Entry <- Types],
    ?assertEqual(17, length(Scalars)),
    ?assertEqual(17, length(Arrays)),
    ?assertEqual(length(minato_oid:names()), length(Scalars)),
    ct:pal("differential coverage~nfixed ~p~ngenerated ~p", [tallied(fixed), tallied(generated)]),
    Total = corpus_size(fixed) + corpus_size(generated),
    ct:pal("~p types, ~p corpus values", [length(Types), Total]),
    ?assert(Total > 20000),
    ok.

%%----------------------------------------------------------------------
%% The disagreements, demonstrated one at a time
%%----------------------------------------------------------------------

-doc """
`pg_types` decodes `numeric` to a float, so a value with more significant digits
than a double can hold comes back wrong. minato decodes to an exact decimal.
""".
-spec pg_types_loses_numeric_precision(ct_suite:ct_config()) -> ok.
pg_types_loses_numeric_precision(_Config) ->
    Exact = ~"12345678901234567890.12345678901234567890",
    Bytes = server_binary(~"numeric", Exact),
    ?assertEqual(Exact, minato_codec:decode(1700, Bytes, binary)),
    Oracle = pg_types:decode(Bytes, minato_pg:type_info(1700)),
    case Oracle of
        Number when is_float(Number) ->
            ?assertNotEqual(Exact, float_to_binary(Number, [short])),
            ct:pal("numeric ~s decodes as ~p through pg_types", [Exact, Number]);
        Other ->
            ct:fail({expected_a_float, Other})
    end,
    ok.

-doc """
The server writes an empty array with no dimensions at all. `pg_types` writes one
dimension of length zero, which is a different byte string for the same value.
""".
-spec pg_types_writes_a_dimension_for_an_empty_array(ct_suite:ct_config()) -> ok.
pg_types_writes_a_dimension_for_an_empty_array(_Config) ->
    Server = server_binary(~"int8[]", ~"{}"),
    Mine = minato_corpus:encoded(1016, [], binary, #{}),
    Oracle = oracle_binary(1016, []),
    ?assertEqual(Server, Mine),
    ?assertEqual(<<0:32, 0:32, 20:32>>, Server),
    ?assertNotEqual(Server, Oracle),
    ?assertEqual(<<1:32, 0:32, 20:32, 0:32, 1:32>>, Oracle),
    ok.

-doc """
The server strips base-10000 digit groups that are entirely zero. `pg_types`
keeps a trailing one, which the server never emits for the same value.
""".
-spec pg_types_pads_numeric_with_a_zero_digit(ct_suite:ct_config()) -> ok.
pg_types_pads_numeric_with_a_zero_digit(_Config) ->
    Server = server_binary(~"numeric", ~"123.4500"),
    Mine = minato_corpus:encoded(1700, ~"123.4500", binary, #{}),
    Oracle = oracle_binary(1700, ~"123.4500"),
    ?assertEqual(Server, Mine),
    ?assertEqual(<<2:16, 0:16, 0:16, 4:16, 123:16, 4500:16>>, Server),
    ?assertEqual(<<3:16, 0:16, 0:16, 4:16, 123:16, 4500:16, 0:16>>, Oracle),
    ok.

-doc """
`date` reserves the largest and smallest `int32` for infinity. `pg_types` reads
them as ordinary dates five million years out, and cannot encode them at all.

The reserved minimum lands before year zero, which `calendar` only started
answering for in OTP 29, so on OTP 28 the same read raises `function_clause`
instead. Both shapes are the same finding and both are recorded in `known/3`.
""".
-spec pg_types_reads_date_infinity_as_a_date(ct_suite:ct_config()) -> ok.
pg_types_reads_date_infinity_as_a_date(_Config) ->
    Bytes = server_binary(~"date", ~"infinity"),
    ?assertEqual(<<2147483647:32>>, Bytes),
    ?assertEqual(infinity, minato_codec:decode(1082, Bytes, binary)),
    Oracle = oracle_date(Bytes),
    ?assertMatch({ok, {_Year, _Month, _Day}}, Oracle),
    ?assertEqual({unsupported, no_date_infinity}, minato_oracle:to_oracle(date, infinity)),
    ct:pal("date infinity decodes as ~p through pg_types", [Oracle]),
    NegBytes = server_binary(~"date", ~"-infinity"),
    ?assertEqual(<<-2147483648:32/signed>>, NegBytes),
    ?assertEqual(neg_infinity, minato_codec:decode(1082, NegBytes, binary)),
    ?assertEqual({unsupported, no_date_infinity}, minato_oracle:to_oracle(date, neg_infinity)),
    NegOracle = oracle_date(NegBytes),
    case NegOracle of
        {raised, Raised} -> ?assertEqual({error, function_clause}, Raised);
        {ok, Date} -> ?assertMatch({_Year, _Month, _Day}, Date)
    end,
    ct:pal("date -infinity decodes as ~p through pg_types on OTP ~s", [
        NegOracle, erlang:system_info(otp_release)
    ]),
    ok.

-doc "What the oracle makes of `date` wire bytes, raise included.".
-spec oracle_date(binary()) -> {ok, term()} | {raised, term()}.
oracle_date(Bytes) ->
    try pg_types:decode(Bytes, minato_pg:type_info(1082)) of
        Decoded -> {ok, Decoded}
    catch
        Class:Reason -> {raised, {Class, Reason}}
    end.

-doc """
Half a second before the 2000 epoch, `pg_types` answers a tuple whose seconds
field is negative, which is not a time of day. minato floors instead, so the
date it answers is the date the instant falls on.
""".
-spec pg_types_leaks_a_negative_seconds_field(ct_suite:ct_config()) -> ok.
pg_types_leaks_a_negative_seconds_field(_Config) ->
    Bytes = server_binary(~"timestamptz", ~"1999-12-31 23:59:59.5+00"),
    ?assertEqual(<<-500000:64/signed>>, Bytes),
    ?assertEqual({{1999, 12, 31}, {23, 59, 59}}, minato_codec:decode(1184, Bytes, binary)),
    ?assertEqual(
        946684799500000,
        minato_codec:decode(1184, Bytes, binary, #{datetime_format => microseconds})
    ),
    Oracle = pg_types:decode(Bytes, minato_pg:type_info(1184)),
    ?assertMatch({{2000, 1, 1}, {0, 0, Second}} when Second < 0, Oracle),
    ct:pal("timestamptz -0.5s decodes as ~p through pg_types", [Oracle]),
    ok.

-doc """
The server emits a display scale of 32 for `numeric` infinity and 0 for NaN,
which is a field the format gives no meaning to when the sign says the value is
special. minato writes 0 for all three, and the server accepts it.
""".
-spec numeric_specials_ignore_display_scale(ct_suite:ct_config()) -> ok.
numeric_specials_ignore_display_scale(_Config) ->
    ?assertEqual(<<0:16, 0:16, 16#D000:16, 32:16>>, server_binary(~"numeric", ~"Infinity")),
    ?assertEqual(
        <<0:16, 0:16, 16#D000:16, 0:16>>,
        minato_corpus:encoded(1700, infinity, binary, #{})
    ),
    {ok, Echoed, Text} = minato_pg:roundtrip(
        ~"numeric", minato_corpus:encoded(1700, infinity, binary, #{})
    ),
    ?assertEqual(~"Infinity", Text),
    ?assertEqual(infinity, minato_codec:decode(1700, Echoed, binary)),
    ok.

-doc """
`24:00:00` is a legal `time` in PostgreSQL and the server sends it as a whole
day of microseconds. `pg_types` raises `function_clause` on it.
""".
-spec pg_types_cannot_decode_the_end_of_day(ct_suite:ct_config()) -> ok.
pg_types_cannot_decode_the_end_of_day(_Config) ->
    Bytes = server_binary(~"time", ~"24:00:00"),
    ?assertEqual(<<86400000000:64>>, Bytes),
    ?assertEqual({24, 0, 0}, minato_codec:decode(1083, Bytes, binary)),
    ?assertError(function_clause, pg_types:decode(Bytes, minato_pg:type_info(1083))),
    ok.

-doc """
The server and the oracle both write the quiet NaN. minato wrote a signalling
one until this suite compared them, which the server never notices because it
stores whatever bit pattern it is handed.
""".
-spec minato_encodes_a_quiet_nan(ct_suite:ct_config()) -> ok.
minato_encodes_a_quiet_nan(_Config) ->
    %% What minato writes is the canonical quiet NaN, and that is asserted
    %% exactly. What the server writes is whatever its C library makes of the
    %% string, which is `7fc00000` on glibc and `7fffffff` on Windows and is a
    %% quiet NaN either way - the payload of a NaN is not specified, so only the
    %% quietness is worth asserting.
    ?assertEqual(<<16#7FC00000:32>>, minato_corpus:encoded(700, nan, binary, #{})),
    ?assertEqual(
        <<16#7FF8000000000000:64>>, minato_corpus:encoded(701, nan, binary, #{})
    ),
    ?assertMatch(<<_Sign:1, 255:8, 1:1, _Payload:22>>, server_binary(~"float4", ~"NaN")),
    ?assertMatch(
        <<_Sign:1, 2047:11, 1:1, _Payload:51>>, server_binary(~"float8", ~"NaN")
    ),
    ok.

-doc """
The server prints a `float4` with only the digits a `float4` needs, so reading
its text output as a double lands on a number no `float4` holds. Both wire
formats have to give the same term or the type has two meanings.
""".
-spec minato_narrows_float4_read_from_text(ct_suite:ct_config()) -> ok.
minato_narrows_float4_read_from_text(_Config) ->
    Max = 3.4028234663852886e38,
    {ok, Binary, Text} = minato_pg:roundtrip(
        ~"float4", minato_corpus:encoded(700, Max, binary, #{})
    ),
    ?assertEqual(~"3.4028235e+38", Text),
    ?assertEqual(Max, minato_codec:decode(700, Binary, binary)),
    ?assertEqual(Max, minato_codec:decode(700, Text, text)),
    ?assertNotEqual(Max, binary_to_float(Text)),
    ok.

-spec server_binary(binary(), binary()) -> binary().
server_binary(SqlType, Literal) ->
    {ok, Bytes} = minato_pg:from_text(SqlType, Literal),
    Bytes.

-spec oracle_binary(minato_oid:oid(), term()) -> binary().
oracle_binary(Oid, Value) ->
    {ok, Bytes} = minato_oracle:encode(entry(Oid), Value, minato_pg:type_info(Oid)),
    Bytes.

-spec entry(minato_oid:oid()) -> minato_corpus:entry().
entry(Oid) ->
    entry(Oid, minato_corpus:types()).

-spec entry(minato_oid:oid(), [minato_corpus:entry()]) -> minato_corpus:entry().
entry(Oid, [#{oid := Oid} = Entry | _Rest]) -> Entry;
entry(Oid, [_Other | Rest]) -> entry(Oid, Rest).
