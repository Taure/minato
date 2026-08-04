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

Arrays are plain lists.

**Encoding always produces a one dimensional array** with a lower bound of 1.
A nested list is not treated as a nested array: it is handed to the element
codec, so `[[1,2]]` encodes as an `_int8` only if the element codec accepts
`[1,2]`, which it does not. This is deliberate. For `_text` a list is valid
`iodata()`, so guessing at nesting would silently change the meaning of a list
of strings.

**Decoding handles any number of dimensions**, returning nested lists in
row-major order, so a 2 by 2 array decodes to `[[1,2],[3,4]]`. Such a value
cannot be encoded back without flattening it first.

Lower bounds are not represented in the Erlang term. An array with a lower bound
other than 1 decodes to the same list as one with a lower bound of 1.

The element type OID in the binary header is written when encoding and ignored
when decoding: the element type follows from the array type OID, which is the
only thing the text format carries as well.
""".

-export([encode/4, decode/4]).

-doc "Encode a list to `Format` array wire bytes for the given array type OID.".
-spec encode(minato_oid:oid(), term(), minato_codec:format(), minato_codec:opts()) -> iodata().
encode(Oid, List, binary, Opts) when is_list(List) ->
    ElementOid = element_oid(Oid),
    Elements = [binary_element(ElementOid, Value, Opts) || Value <- List],
    [
        header(List, ElementOid),
        Elements
    ];
encode(Oid, List, text, Opts) when is_list(List) ->
    ElementOid = element_oid(Oid),
    [${, comma_separated(ElementOid, List, Opts), $}];
encode(Oid, Value, _Format, _Opts) ->
    minato_codec:bad({array, Oid}, not_a_list, Value).

-doc "Decode `Format` array wire bytes for the given array type OID.".
-spec decode(minato_oid:oid(), binary(), minato_codec:format(), minato_codec:opts()) ->
    [minato_codec:value()].
decode(_Oid, <<0:32/signed, _Flags:32, _ElementOid:32, _Rest/binary>>, binary, _Opts) ->
    [];
decode(Oid, <<NDim:32/signed, _Flags:32, _ElementOid:32, Rest/binary>>, binary, Opts) when
    NDim > 0
->
    {Dimensions, AfterDimensions} = dimensions(NDim, Rest),
    {Flat, Trailing} = elements(count(Dimensions), AfterDimensions, element_oid(Oid), Opts),
    case Trailing of
        ~"" -> reshape(Flat, Dimensions);
        _ -> minato_codec:bad({array, Oid}, trailing_bytes, Trailing)
    end;
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
%% Binary format
%%----------------------------------------------------------------------

-spec header([term()], minato_oid:oid()) -> binary().
header([], ElementOid) ->
    <<0:32/signed, 0:32, ElementOid:32>>;
header(List, ElementOid) ->
    Flags =
        case lists:member(null, List) of
            true -> 1;
            false -> 0
        end,
    <<1:32/signed, Flags:32, ElementOid:32, (length(List)):32/signed, 1:32/signed>>.

-spec binary_element(minato_oid:oid(), term(), minato_codec:opts()) -> iodata().
binary_element(ElementOid, Value, Opts) ->
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
dimensions(N, <<Size:32/signed, _LowerBound:32/signed, Rest/binary>>) ->
    {Sizes, Tail} = dimensions(N - 1, Rest),
    {[Size | Sizes], Tail};
dimensions(_N, Rest) ->
    minato_codec:bad(array, truncated_dimensions, Rest).

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

-spec comma_separated(minato_oid:oid(), [term()], minato_codec:opts()) -> [iodata()].
comma_separated(_ElementOid, [], _Opts) ->
    [];
comma_separated(ElementOid, [Value], Opts) ->
    [text_element(ElementOid, Value, Opts)];
comma_separated(ElementOid, [Value | Rest], Opts) ->
    [text_element(ElementOid, Value, Opts), ~"," | comma_separated(ElementOid, Rest, Opts)].

-spec text_element(minato_oid:oid(), term(), minato_codec:opts()) -> iodata().
text_element(ElementOid, Value, Opts) ->
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
    case list(Bin, element_oid(Oid), Opts) of
        {List, ~""} -> List;
        {_List, Trailing} -> minato_codec:bad({array, Oid}, trailing_bytes, Trailing)
    end.

-spec list(binary(), minato_oid:oid(), minato_codec:opts()) ->
    {[minato_codec:value()], binary()}.
list(<<${, $}, Rest/binary>>, _ElementOid, _Opts) ->
    {[], Rest};
list(<<${, Rest/binary>>, ElementOid, Opts) ->
    items(Rest, ElementOid, Opts);
list(Bin, _ElementOid, _Opts) ->
    minato_codec:bad(array, malformed_text, Bin).

-spec items(binary(), minato_oid:oid(), minato_codec:opts()) ->
    {[minato_codec:value()], binary()}.
items(Bin, ElementOid, Opts) ->
    {Value, Rest} = item(Bin, ElementOid, Opts),
    case Rest of
        <<$,, Tail/binary>> ->
            {Values, Trailing} = items(Tail, ElementOid, Opts),
            {[Value | Values], Trailing};
        <<$}, Tail/binary>> ->
            {[Value], Tail};
        _ ->
            minato_codec:bad(array, malformed_text, Rest)
    end.

-spec item(binary(), minato_oid:oid(), minato_codec:opts()) ->
    {minato_codec:value(), binary()}.
item(<<${, _/binary>> = Bin, ElementOid, Opts) ->
    list(Bin, ElementOid, Opts);
item(<<$", Rest/binary>>, ElementOid, Opts) ->
    {Raw, Tail} = quoted(Rest, ~""),
    {minato_codec:decode(ElementOid, Raw, text, Opts), Tail};
item(Bin, ElementOid, Opts) ->
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
