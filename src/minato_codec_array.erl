-module(minato_codec_array).
-moduledoc """
Codec for array types.

Internal to minato. The supported surface is `m:minato_codec`.

## Wire format

The binary representation is a header followed by one length prefixed value per
element, in row-major order:

```text
int32   ndim          number of dimensions, 0 for an empty array
int32   flags         bit 0 set when any element is NULL
uint32  element_oid   the type OID of the elements
        per dimension:
int32     size        number of elements along that dimension
int32     lower_bound index of the first element, 1 by default
        per element:
int32     length      byte length, or -1 for NULL
bytes     value       absent when the length is -1
```

An empty array carries `ndim = 0` and no dimension headers at all.

The text representation is `{1,2,3}`, with `{}` for empty, an unquoted `NULL`
for a null element, and `{{1,2},{3,4}}` for nesting. Elements are quoted with
`"` when they are empty, when they would read as the literal `NULL`, or when
they contain a brace, a comma, a quote, a backslash or whitespace; inside
quotes, `"` and `\` are backslash escaped. A leading `[1:3]=` dimension prefix
is skipped when decoding and never produced when encoding.

## Erlang representation

Arrays are lists, and an array of more than one dimension is a list of lists,
in row-major order: a 2 by 2 array is `[[1,2],[3,4]]` in both directions.

**Decoding handles any number of dimensions.**

**Encoding reads a list inside a list as a row wherever an element cannot be a
list**, which is every element type except the `iodata()` ones: `bool`, the
integers, the floats, `numeric`, `uuid` and the temporal types. So
`[[1,2],[3,4]]` is a 2 by 2 `_int4`.

For `_text`, `_varchar`, `_json`, `_jsonb` and `_bytea` a list is already a
value, a string given as `iodata()`, so `[[~"a",~"b"],[~"c",~"d"]]` is and stays
the one dimensional array of `ab` and `cd`. To send those as rows, say so:
`{array, [[~"a",~"b"],[~"c",~"d"]]}`. Inside that tuple every list is a
dimension and nothing else is, for every element type, so an element there is a
binary and never a string written as a list.

An array is rectangular: every row of a dimension has the same length and the
same depth. One that is not is refused with `ragged_array`, naming the row or
element that does not fit. An array with no elements has no dimensions,
whatever lists it was written with: `[[],[]]` encodes as `[]` does, which is
also how the server stores it.

A string written as a list is a list, and nothing tells it from a row. Handed
to an array of numbers, `["12","34"]` is the 2 by 2 array of four character
codes, and `[1,"2"]` is ragged.

Lower bounds are not represented in the Erlang term. An array with a lower bound
other than 1 decodes to the same list as one with a lower bound of 1, and every
dimension is encoded with a lower bound of 1.

The element type OID in the binary header is written when encoding and ignored
when decoding: the element type follows from the array type OID, which is the
only thing the text format carries as well.

## Bounds

PostgreSQL arrays have at most six dimensions, so a binary header declaring
more, or text nested deeper, is refused before anything is read from it. A
dimension cannot have a negative size, and the header cannot declare more
elements than the bytes that follow could hold, since every element takes at
least its four byte length. Without those a few bytes of header could ask for
any amount of nesting or any number of elements.
""".

-export([encode/4, decode/4]).

-define(MAX_DIMENSIONS, 6).
-define(SMALLEST_ELEMENT, 4).

-type nesting() :: dimensions | values.

-doc """
Encode a list, or `{array, List}`, to `Format` array wire bytes for the given
array type OID. See the module documentation for what a list inside it means.
""".
-spec encode(minato_oid:oid(), term(), minato_codec:format(), minato_codec:opts()) -> iodata().
encode(Oid, {array, List}, Format, Opts) when is_list(List) ->
    written(Oid, element_oid(Oid), List, dimensions, Format, Opts);
encode(Oid, List, Format, Opts) when is_list(List) ->
    ElementOid = element_oid(Oid),
    written(Oid, ElementOid, List, nesting(ElementOid), Format, Opts);
encode(Oid, Value, _Format, _Opts) ->
    minato_codec:bad({array, Oid}, not_a_list, Value).

-spec nesting(minato_oid:oid()) -> nesting().
nesting(ElementOid) ->
    case minato_oid:name(ElementOid) of
        Name when
            Name =:= bytea; Name =:= text; Name =:= varchar; Name =:= json; Name =:= jsonb
        ->
            values;
        _ ->
            dimensions
    end.

-spec written(
    minato_oid:oid(),
    minato_oid:oid(),
    [term()],
    nesting(),
    minato_codec:format(),
    minato_codec:opts()
) -> iodata().
written(Oid, ElementOid, [Row | _] = List, dimensions, Format, Opts) when is_list(Row) ->
    rows(Oid, ElementOid, List, sizes(Oid, List, 1), Format, Opts);
written(Oid, ElementOid, List, Nesting, binary, Opts) ->
    [
        header(List, ElementOid)
        | [binary_element(Oid, ElementOid, Value, Nesting, Opts) || Value <- List]
    ];
written(Oid, ElementOid, List, Nesting, text, Opts) ->
    [${, comma_separated(Oid, ElementOid, List, Nesting, Opts), $}].

-doc "Decode `Format` array wire bytes for the given array type OID.".
-spec decode(minato_oid:oid(), binary(), minato_codec:format(), minato_codec:opts()) ->
    [minato_codec:value()].
decode(_Oid, <<0:32/signed, _Flags:32, _ElementOid:32, _Rest/binary>>, binary, _Opts) ->
    [];
decode(Oid, <<NDim:32/signed, _Flags:32, _ElementOid:32, Rest/binary>>, binary, Opts) when
    NDim > 0, NDim =< ?MAX_DIMENSIONS
->
    {Dimensions, AfterDimensions} = dimensions(NDim, Rest),
    Count = held(count(Dimensions), AfterDimensions),
    {Flat, Trailing} = elements(Count, AfterDimensions, element_oid(Oid), Opts),
    case Trailing of
        ~"" -> reshape(Flat, Dimensions);
        _ -> minato_codec:bad({array, Oid}, trailing_bytes, Trailing)
    end;
decode(Oid, <<NDim:32/signed, _Flags:32, _ElementOid:32, _Rest/binary>>, binary, _Opts) ->
    minato_codec:bad({array, Oid}, dimensions_out_of_range, NDim);
decode(Oid, Bin, text, Opts) ->
    parse(Oid, strip_dimension_prefix(Bin), Opts);
decode(Oid, Bin, Format, _Opts) ->
    minato_codec:bad({array, Oid}, {malformed, Format}, Bin).

-spec element_oid(minato_oid:oid()) -> minato_oid:oid().
element_oid(Oid) ->
    case minato_oid:element_oid(Oid) of
        undefined -> minato_codec:bad({array, Oid}, not_an_array_type, Oid);
        ElementOid -> ElementOid
    end.

%%----------------------------------------------------------------------
%% More than one dimension
%%----------------------------------------------------------------------

-spec sizes(minato_oid:oid(), [term()], pos_integer()) -> [non_neg_integer()].
sizes(Oid, List, Depth) when Depth > ?MAX_DIMENSIONS ->
    minato_codec:bad({array, Oid}, dimensions_out_of_range, List);
sizes(Oid, [Row | _] = List, Depth) when is_list(Row) ->
    [length(List) | sizes(Oid, Row, Depth + 1)];
sizes(_Oid, List, _Depth) ->
    [length(List)].

-spec rows(
    minato_oid:oid(),
    minato_oid:oid(),
    [term()],
    [non_neg_integer()],
    minato_codec:format(),
    minato_codec:opts()
) -> iodata().
rows(Oid, ElementOid, List, Sizes, binary, Opts) ->
    case leaves(Oid, List, Sizes) of
        [] ->
            header([], ElementOid);
        Leaves ->
            [
                <<(length(Sizes)):32/signed, (null_flag(Leaves)):32, ElementOid:32>>,
                [<<Size:32/signed, 1:32/signed>> || Size <- Sizes]
                | [binary_element(Oid, ElementOid, Leaf, dimensions, Opts) || Leaf <- Leaves]
            ]
    end;
rows(Oid, ElementOid, List, Sizes, text, Opts) ->
    Braced = braced(Oid, ElementOid, List, Sizes, Opts),
    case lists:member(0, Sizes) of
        true -> ~"{}";
        false -> Braced
    end.

-spec leaves(minato_oid:oid(), term(), [non_neg_integer()]) -> [term()].
leaves(_Oid, List, [Size]) when is_list(List), length(List) =:= Size ->
    List;
leaves(Oid, List, [Size | Inner]) when is_list(List), length(List) =:= Size ->
    lists:append([leaves(Oid, Row, Inner) || Row <- List]);
leaves(Oid, Value, _Sizes) ->
    minato_codec:bad({array, Oid}, ragged_array, Value).

-spec braced(minato_oid:oid(), minato_oid:oid(), term(), [non_neg_integer()], minato_codec:opts()) ->
    iodata().
braced(Oid, ElementOid, List, [Size], Opts) when is_list(List), length(List) =:= Size ->
    [${, comma_separated(Oid, ElementOid, List, dimensions, Opts), $}];
braced(Oid, ElementOid, List, [Size | Inner], Opts) when is_list(List), length(List) =:= Size ->
    [${, between_commas([braced(Oid, ElementOid, Row, Inner, Opts) || Row <- List]), $}];
braced(Oid, _ElementOid, Value, _Sizes, _Opts) ->
    minato_codec:bad({array, Oid}, ragged_array, Value).

-spec between_commas([iodata()]) -> [iodata()].
between_commas([Last]) -> [Last];
between_commas([Row | Rest]) -> [Row, ~"," | between_commas(Rest)];
between_commas([]) -> [].

%%----------------------------------------------------------------------
%% Binary format
%%----------------------------------------------------------------------

-spec header([term()], minato_oid:oid()) -> binary().
header([], ElementOid) ->
    <<0:32/signed, 0:32, ElementOid:32>>;
header(List, ElementOid) ->
    <<1:32/signed, (null_flag(List)):32, ElementOid:32, (length(List)):32/signed, 1:32/signed>>.

-spec null_flag([term()]) -> 0 | 1.
null_flag(Elements) ->
    case lists:member(null, Elements) of
        true -> 1;
        false -> 0
    end.

-spec binary_element(minato_oid:oid(), minato_oid:oid(), term(), nesting(), minato_codec:opts()) ->
    iodata().
binary_element(Oid, _ElementOid, Value, dimensions, _Opts) when is_list(Value) ->
    minato_codec:bad({array, Oid}, ragged_array, Value);
binary_element(_Oid, ElementOid, Value, _Nesting, Opts) ->
    case minato_codec:encode(ElementOid, Value, binary, Opts) of
        null ->
            <<-1:32/signed>>;
        IoData ->
            Bin = iolist_to_binary(IoData),
            <<(byte_size(Bin)):32/signed, Bin/binary>>
    end.

-spec dimensions(integer(), binary()) -> {[integer()], binary()}.
dimensions(N, Rest) when N =< 0 ->
    {[], Rest};
dimensions(N, <<Size:32/signed, _LowerBound:32/signed, Rest/binary>>) when Size >= 0 ->
    {Sizes, Tail} = dimensions(N - 1, Rest),
    {[Size | Sizes], Tail};
dimensions(_N, <<Size:32/signed, _LowerBound:32/signed, _Rest/binary>>) ->
    minato_codec:bad(array, negative_dimension, Size);
dimensions(_N, Rest) ->
    minato_codec:bad(array, truncated_dimensions, Rest).

-spec held(integer(), binary()) -> integer().
held(Count, Elements) when Count * ?SMALLEST_ELEMENT =< byte_size(Elements) ->
    Count;
held(_Count, Elements) ->
    minato_codec:bad(array, truncated_elements, Elements).

-spec count([integer()]) -> integer().
count([]) -> 0;
count([Size]) -> Size;
count([Size | Rest]) -> Size * count(Rest).

-spec elements(integer(), binary(), minato_oid:oid(), minato_codec:opts()) ->
    {[minato_codec:value()], binary()}.
elements(N, Rest, _ElementOid, _Opts) when N =< 0 ->
    {[], Rest};
elements(N, <<-1:32/signed, Rest/binary>>, ElementOid, Opts) ->
    {Values, Tail} = elements(N - 1, Rest, ElementOid, Opts),
    {[null | Values], Tail};
elements(N, <<Length:32/signed, Value:Length/binary, Rest/binary>>, ElementOid, Opts) when
    Length >= 0
->
    Decoded = minato_codec:decode(ElementOid, Value, binary, Opts),
    {Values, Tail} = elements(N - 1, Rest, ElementOid, Opts),
    {[Decoded | Values], Tail};
elements(_N, Rest, _ElementOid, _Opts) ->
    minato_codec:bad(array, truncated_elements, Rest).

-spec reshape([minato_codec:value()], [integer()]) -> [minato_codec:value()].
reshape(Elements, [_Size]) ->
    Elements;
reshape(Elements, [_Size | Rest]) ->
    [reshape(Chunk, Rest) || Chunk <- chunks(Elements, count(Rest))];
reshape(Elements, []) ->
    Elements.

-spec chunks([minato_codec:value()], integer()) -> [[minato_codec:value()]].
chunks([], _Size) ->
    [];
chunks(Elements, Size) when Size > 0 ->
    {Chunk, Rest} = take(Size, Elements),
    [Chunk | chunks(Rest, Size)];
chunks(Elements, _Size) ->
    [Elements].

-spec take(integer(), [minato_codec:value()]) ->
    {[minato_codec:value()], [minato_codec:value()]}.
take(N, Rest) when N =< 0 ->
    {[], Rest};
take(_N, []) ->
    {[], []};
take(N, [Head | Tail]) ->
    {Taken, Rest} = take(N - 1, Tail),
    {[Head | Taken], Rest}.

%%----------------------------------------------------------------------
%% Text format
%%----------------------------------------------------------------------

-spec comma_separated(minato_oid:oid(), minato_oid:oid(), [term()], nesting(), minato_codec:opts()) ->
    [iodata()].
comma_separated(_Oid, _ElementOid, [], _Nesting, _Opts) ->
    [];
comma_separated(Oid, ElementOid, [Value], Nesting, Opts) ->
    [text_element(Oid, ElementOid, Value, Nesting, Opts)];
comma_separated(Oid, ElementOid, [Value | Rest], Nesting, Opts) ->
    [
        text_element(Oid, ElementOid, Value, Nesting, Opts),
        ~","
        | comma_separated(Oid, ElementOid, Rest, Nesting, Opts)
    ].

-spec text_element(minato_oid:oid(), minato_oid:oid(), term(), nesting(), minato_codec:opts()) ->
    iodata().
text_element(Oid, _ElementOid, Value, dimensions, _Opts) when is_list(Value) ->
    minato_codec:bad({array, Oid}, ragged_array, Value);
text_element(_Oid, ElementOid, Value, _Nesting, Opts) ->
    case minato_codec:encode(ElementOid, Value, text, Opts) of
        null -> ~"NULL";
        IoData -> quote(iolist_to_binary(IoData))
    end.

-spec quote(binary()) -> iodata().
quote(Bin) ->
    case needs_quote(Bin) of
        true -> [$", escape(Bin, ~""), $"];
        false -> Bin
    end.

-spec needs_quote(binary()) -> boolean().
needs_quote(~"") -> true;
needs_quote(Bin) -> is_null_literal(Bin) orelse has_special(Bin).

-spec has_special(binary()) -> boolean().
has_special(~"") -> false;
has_special(<<C, Rest/binary>>) -> special(C) orelse has_special(Rest).

-spec special(byte()) -> boolean().
special(C) when C =:= ${; C =:= $}; C =:= $,; C =:= $"; C =:= $\\ -> true;
special(C) when C =< $\s -> true;
special(_) -> false.

-spec escape(binary(), binary()) -> binary().
escape(~"", Acc) -> Acc;
escape(<<C, Rest/binary>>, Acc) when C =:= $"; C =:= $\\ -> escape(Rest, <<Acc/binary, $\\, C>>);
escape(<<C, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, C>>).

-spec is_null_literal(binary()) -> boolean().
is_null_literal(<<N, U, L1, L2>>) ->
    lower(N) =:= $n andalso lower(U) =:= $u andalso lower(L1) =:= $l andalso lower(L2) =:= $l;
is_null_literal(_) ->
    false.

-spec lower(byte()) -> byte().
lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.

-spec strip_dimension_prefix(binary()) -> binary().
strip_dimension_prefix(<<$[, _/binary>> = Bin) ->
    case binary:match(Bin, ~"=") of
        {Pos, 1} -> binary_part(Bin, Pos + 1, byte_size(Bin) - Pos - 1);
        nomatch -> Bin
    end;
strip_dimension_prefix(Bin) ->
    Bin.

-spec parse(minato_oid:oid(), binary(), minato_codec:opts()) -> [minato_codec:value()].
parse(Oid, Bin, Opts) ->
    case list(Bin, element_oid(Oid), Opts, 1) of
        {List, ~""} -> List;
        {_List, Trailing} -> minato_codec:bad({array, Oid}, trailing_bytes, Trailing)
    end.

-spec list(binary(), minato_oid:oid(), minato_codec:opts(), pos_integer()) ->
    {[minato_codec:value()], binary()}.
list(Bin, _ElementOid, _Opts, Depth) when Depth > ?MAX_DIMENSIONS ->
    minato_codec:bad(array, dimensions_out_of_range, Bin);
list(<<${, $}, Rest/binary>>, _ElementOid, _Opts, _Depth) ->
    {[], Rest};
list(<<${, Rest/binary>>, ElementOid, Opts, Depth) ->
    items(Rest, ElementOid, Opts, Depth);
list(Bin, _ElementOid, _Opts, _Depth) ->
    minato_codec:bad(array, malformed_text, Bin).

-spec items(binary(), minato_oid:oid(), minato_codec:opts(), pos_integer()) ->
    {[minato_codec:value()], binary()}.
items(Bin, ElementOid, Opts, Depth) ->
    {Value, Rest} = item(Bin, ElementOid, Opts, Depth),
    case Rest of
        <<$,, Tail/binary>> ->
            {Values, Trailing} = items(Tail, ElementOid, Opts, Depth),
            {[Value | Values], Trailing};
        <<$}, Tail/binary>> ->
            {[Value], Tail};
        _ ->
            minato_codec:bad(array, malformed_text, Rest)
    end.

-spec item(binary(), minato_oid:oid(), minato_codec:opts(), pos_integer()) ->
    {minato_codec:value(), binary()}.
item(<<${, _/binary>> = Bin, ElementOid, Opts, Depth) ->
    list(Bin, ElementOid, Opts, Depth + 1);
item(<<$", Rest/binary>>, ElementOid, Opts, _Depth) ->
    {Raw, Tail} = quoted(Rest, ~""),
    {minato_codec:decode(ElementOid, Raw, text, Opts), Tail};
item(Bin, ElementOid, Opts, _Depth) ->
    {Raw, Tail} = bare(Bin, 0),
    case is_null_literal(Raw) of
        true -> {null, Tail};
        false -> {minato_codec:decode(ElementOid, Raw, text, Opts), Tail}
    end.

-spec quoted(binary(), binary()) -> {binary(), binary()}.
quoted(<<$\\, C, Rest/binary>>, Acc) -> quoted(Rest, <<Acc/binary, C>>);
quoted(<<$", Rest/binary>>, Acc) -> {Acc, Rest};
quoted(<<C, Rest/binary>>, Acc) -> quoted(Rest, <<Acc/binary, C>>);
quoted(~"", Acc) -> minato_codec:bad(array, unterminated_quote, Acc).

-spec bare(binary(), non_neg_integer()) -> {binary(), binary()}.
bare(Bin, Taken) ->
    case Bin of
        <<_:Taken/binary, C, _/binary>> when C =/= $,, C =/= $} ->
            bare(Bin, Taken + 1);
        _ ->
            {binary_part(Bin, 0, Taken), binary_part(Bin, Taken, byte_size(Bin) - Taken)}
    end.
