-module(minato_oracle).
-moduledoc """
`pg_types` as a black box differential oracle.

`pg_types` is a test profile dependency and nothing else. It is never read for
implementation guidance and never shipped: it is called, and what it answers is
compared with what minato answers. Its API was established by calling its
exported functions and observing the results, which is the whole point of an
oracle.

`pg_types` writes a four byte length prefix in front of every encoded value,
because it encodes straight into a protocol message body. minato returns the
value bytes alone and leaves the length to the caller, so `encode/3` strips the
prefix before comparing.

## Shapes

The two libraries choose different Erlang terms for several types, which is a
design difference and not a defect. `to_oracle/2` maps a corpus value into the
shape `pg_types` accepts and `from_oracle/3` maps its answer back into minato's,
so that a comparison is about the wire bytes and not about spelling:

| Type | minato | pg_types |
| --- | --- | --- |
| `numeric` | exact decimal binary | `float()` or `integer()` |
| specials | `nan`, `infinity`, `neg_infinity` | `'NaN'`, `infinity`, `'-infinity'` |
| `uuid` | 36 character binary, or 16 raw bytes | 16 raw bytes |
| sub-second temporals | microseconds, or floored seconds | `float()` in the seconds field |
| nested arrays | nested lists | `{array, List}` |

Where a corpus value cannot be expressed at all in the oracle's shape, the
mapping answers `unsupported` with a reason, and the suite counts it rather than
passing it off as agreement.
""".

-export([encode/3, decode/4, to_oracle/2, from_oracle/3]).

-doc "An oracle answer: agreement is decided by the caller, absence is explained here.".
-type outcome(T) :: {ok, T} | {unsupported, atom()} | {failed, term()}.

-export_type([outcome/1]).

-doc """
The oracle's binary encoding of a corpus value, without the length prefix.

Answers `{unsupported, Reason}` when the value has no representation in the
oracle's input shapes, and `{failed, Reason}` when the oracle raises on a value
it ought to accept.
""".
-spec encode(minato_corpus:entry(), term(), dynamic()) -> outcome(binary()).
encode(#{name := Name}, Value, TypeInfo) ->
    case to_oracle(Name, Value) of
        {unsupported, Reason} ->
            {unsupported, Reason};
        {ok, Mapped} ->
            try iolist_to_binary(pg_types:encode(Mapped, TypeInfo)) of
                <<Length:32/signed, Bytes/binary>> when Length =:= byte_size(Bytes) ->
                    {ok, Bytes};
                Other ->
                    {failed, {unexpected_length_prefix, Other}}
            catch
                Class:Reason -> {failed, {Class, Reason}}
            end
    end.

-doc """
The oracle's decoding of wire bytes, mapped into minato's shape.

Answers `{unsupported, Reason}` when the oracle's answer has no counterpart in
minato's shape, which is itself worth counting.
""".
-spec decode(minato_corpus:entry(), binary(), minato_codec:opts(), dynamic()) ->
    outcome(term()).
decode(#{name := Name}, Bytes, Opts, TypeInfo) ->
    try pg_types:decode(Bytes, TypeInfo) of
        Decoded -> from_oracle(Name, Decoded, Opts)
    catch
        Class:Reason -> {failed, {Class, Reason}}
    end.

%%----------------------------------------------------------------------
%% minato shape to pg_types shape
%%----------------------------------------------------------------------

-doc "Map a minato value into the shape `pg_types` accepts for the same type.".
-spec to_oracle(minato_oid:name() | {array, minato_oid:name()}, term()) ->
    {ok, term()} | {unsupported, atom()}.
to_oracle({array, Name}, List) when is_list(List) ->
    map_elements(Name, List, []);
to_oracle(_Name, null) ->
    {unsupported, no_null_encoding};
to_oracle(Name, nan) when Name =:= float4; Name =:= float8; Name =:= numeric ->
    {ok, 'NaN'};
to_oracle(Name, infinity) when Name =:= float4; Name =:= float8; Name =:= numeric ->
    {ok, infinity};
to_oracle(Name, neg_infinity) when Name =:= float4; Name =:= float8; Name =:= numeric ->
    {ok, '-infinity'};
to_oracle(Name, infinity) when Name =:= timestamp; Name =:= timestamptz ->
    {ok, infinity};
to_oracle(Name, neg_infinity) when Name =:= timestamp; Name =:= timestamptz ->
    {ok, '-infinity'};
to_oracle(date, Value) when Value =:= infinity; Value =:= neg_infinity ->
    {unsupported, no_date_infinity};
to_oracle(Name, Value) when
    is_integer(Value), Name =:= time;
    is_integer(Value), Name =:= timestamp;
    is_integer(Value), Name =:= timestamptz
->
    {unsupported, no_microsecond_input};
to_oracle(_Name, Value) ->
    {ok, Value}.

-spec map_elements(minato_oid:name(), [term()], [term()]) ->
    {ok, [term()]} | {unsupported, atom()}.
map_elements(_Name, [], Acc) ->
    {ok, lists:reverse(Acc)};
map_elements(Name, [null | Rest], Acc) ->
    map_elements(Name, Rest, [null | Acc]);
map_elements(Name, [Head | Rest], Acc) ->
    case to_oracle(Name, Head) of
        {unsupported, Reason} -> {unsupported, Reason};
        {ok, Mapped} -> map_elements(Name, Rest, [Mapped | Acc])
    end.

%%----------------------------------------------------------------------
%% pg_types shape to minato shape
%%----------------------------------------------------------------------

-doc """
Map an oracle answer into the shape minato produces for the same type and
options, so that a comparison is about the value and not about spelling.
""".
-spec from_oracle(minato_oid:name() | {array, minato_oid:name()}, term(), minato_codec:opts()) ->
    outcome(term()).
from_oracle({array, Name}, List, Opts) when is_list(List) ->
    unmap_elements(Name, List, Opts, []);
from_oracle(_Name, null, _Opts) ->
    {ok, null};
from_oracle(Name, 'NaN', _Opts) when Name =:= float4; Name =:= float8 ->
    {ok, nan};
from_oracle(Name, infinity, _Opts) when Name =:= float4; Name =:= float8 ->
    {ok, infinity};
from_oracle(Name, '-infinity', _Opts) when Name =:= float4; Name =:= float8 ->
    {ok, neg_infinity};
from_oracle(numeric, 'NaN', _Opts) ->
    {ok, nan};
from_oracle(numeric, infinity, _Opts) ->
    {ok, infinity};
from_oracle(numeric, '-infinity', _Opts) ->
    {ok, neg_infinity};
from_oracle(numeric, Value, _Opts) when is_number(Value) ->
    {ok, {approximate_number, Value}};
from_oracle(uuid, Raw, Opts) when is_binary(Raw), byte_size(Raw) =:= 16 ->
    {ok, minato_codec:decode(minato_oid:oid(uuid), Raw, binary, Opts)};
from_oracle(time, {Hour, Minute, Second}, Opts) when
    is_integer(Hour), is_integer(Minute), is_number(Second)
->
    {ok, day_micros_out(clock_micros(Hour, Minute, Second), Opts)};
from_oracle(Name, {{Year, Month, Day}, {Hour, Minute, Second}}, Opts) when
    Name =:= timestamp orelse Name =:= timestamptz,
    is_integer(Year),
    is_integer(Month),
    is_integer(Day),
    is_integer(Hour),
    is_integer(Minute),
    is_number(Second)
->
    Micros =
        minato_codec_datetime:days_from_civil(Year, Month, Day) * 86400000000 +
            clock_micros(Hour, Minute, Second),
    {ok, unix_micros_out(Micros, Opts)};
from_oracle(Name, Value, _Opts) when
    Name =:= timestamp, Value =:= infinity;
    Name =:= timestamptz, Value =:= infinity
->
    {ok, infinity};
from_oracle(Name, '-infinity', _Opts) when Name =:= timestamp; Name =:= timestamptz ->
    {ok, neg_infinity};
from_oracle(_Name, Value, _Opts) ->
    {ok, Value}.

-spec unmap_elements(minato_oid:name(), [term()], minato_codec:opts(), [term()]) ->
    outcome([term()]).
unmap_elements(_Name, [], _Opts, Acc) ->
    {ok, lists:reverse(Acc)};
unmap_elements(Name, [{array, Sub} | Rest], Opts, Acc) when is_list(Sub) ->
    case unmap_elements(Name, Sub, Opts, []) of
        {ok, Nested} -> unmap_elements(Name, Rest, Opts, [Nested | Acc]);
        Other -> Other
    end;
unmap_elements(Name, [Head | Rest], Opts, Acc) ->
    case from_oracle(Name, Head, Opts) of
        {ok, Mapped} -> unmap_elements(Name, Rest, Opts, [Mapped | Acc]);
        Other -> Other
    end.

-spec clock_micros(integer(), integer(), number()) -> integer().
clock_micros(Hour, Minute, Second) ->
    (Hour * 3600 + Minute * 60) * 1000000 + round(Second * 1000000).

-spec day_micros_out(integer(), minato_codec:opts()) -> term().
day_micros_out(Micros, #{datetime_format := microseconds}) ->
    Micros;
day_micros_out(Micros, _Opts) ->
    Seconds = floor_div(Micros, 1000000),
    {Seconds div 3600, (Seconds rem 3600) div 60, Seconds rem 60}.

-spec unix_micros_out(integer(), minato_codec:opts()) -> term().
unix_micros_out(Micros, #{datetime_format := microseconds}) ->
    Micros;
unix_micros_out(Micros, _Opts) ->
    Days = floor_div(Micros, 86400000000),
    Seconds = floor_div(Micros - Days * 86400000000, 1000000),
    {minato_codec_datetime:civil_from_days(Days), {
        Seconds div 3600, (Seconds rem 3600) div 60, Seconds rem 60
    }}.

-spec floor_div(integer(), pos_integer()) -> integer().
floor_div(A, B) when A >= 0 -> A div B;
floor_div(A, B) -> -((-A + B - 1) div B).
