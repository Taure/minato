-module(minato_oid).
-moduledoc """
PostgreSQL type OIDs and the mapping between an array type and its element type.

OIDs for built-in types are fixed by PostgreSQL and are stable across servers,
so they are compiled in as function clauses rather than read from `pg_type` at
connection time. User defined types (enums, composites, domains) get OIDs
assigned per database and are not handled here.

OIDs arrive from the server, so every function that takes one is total and
answers `undefined` for an OID minato has no codec for. Names come from your own
code, so `oid/1` has no such escape and raises on a name that does not exist.
""".

-export([
    name/1,
    oid/1,
    element_oid/1,
    array_oid/1,
    is_array/1,
    names/0
]).

-type oid() :: non_neg_integer().
-doc "The name minato uses for a built-in PostgreSQL type.".
-type name() ::
    bool
    | bytea
    | int2
    | int4
    | int8
    | float4
    | float8
    | numeric
    | text
    | varchar
    | json
    | jsonb
    | uuid
    | date
    | time
    | timestamp
    | timestamptz.

-export_type([oid/0, name/0]).

-doc """
The name of a scalar type OID, or of an array OID as `{array, Name}`.

Returns `undefined` for any OID minato has no codec for.

```erlang
1> minato_oid:name(23).
int4
2> minato_oid:name(1016).
{array,int8}
3> minato_oid:name(2249).
undefined
```
""".
-spec name(oid()) -> name() | {array, name()} | undefined.
name(16) ->
    bool;
name(17) ->
    bytea;
name(20) ->
    int8;
name(21) ->
    int2;
name(23) ->
    int4;
name(25) ->
    text;
name(114) ->
    json;
name(700) ->
    float4;
name(701) ->
    float8;
name(1043) ->
    varchar;
name(1082) ->
    date;
name(1083) ->
    time;
name(1114) ->
    timestamp;
name(1184) ->
    timestamptz;
name(1700) ->
    numeric;
name(2950) ->
    uuid;
name(3802) ->
    jsonb;
name(Oid) ->
    case element_oid(Oid) of
        undefined ->
            undefined;
        ElementOid ->
            case name(ElementOid) of
                undefined -> undefined;
                Name when is_atom(Name) -> {array, Name}
            end
    end.

-doc """
The OID of a named scalar type, or of an array type given as `{array, Name}`.

Raises `function_clause` for a name that is not a `t:name/0`, which can only be
a mistake in the calling code.
""".
-spec oid(name() | {array, name()}) -> oid().
oid(bool) -> 16;
oid(bytea) -> 17;
oid(int8) -> 20;
oid(int2) -> 21;
oid(int4) -> 23;
oid(text) -> 25;
oid(json) -> 114;
oid(float4) -> 700;
oid(float8) -> 701;
oid(varchar) -> 1043;
oid(date) -> 1082;
oid(time) -> 1083;
oid(timestamp) -> 1114;
oid(timestamptz) -> 1184;
oid(numeric) -> 1700;
oid(uuid) -> 2950;
oid(jsonb) -> 3802;
oid({array, bool}) -> 1000;
oid({array, bytea}) -> 1001;
oid({array, int8}) -> 1016;
oid({array, int2}) -> 1005;
oid({array, int4}) -> 1007;
oid({array, text}) -> 1009;
oid({array, json}) -> 199;
oid({array, float4}) -> 1021;
oid({array, float8}) -> 1022;
oid({array, varchar}) -> 1015;
oid({array, date}) -> 1182;
oid({array, time}) -> 1183;
oid({array, timestamp}) -> 1115;
oid({array, timestamptz}) -> 1185;
oid({array, numeric}) -> 1231;
oid({array, uuid}) -> 2951;
oid({array, jsonb}) -> 3807.

-doc """
The element type OID of an array type OID.

Returns `undefined` when the OID is not an array type minato knows.

```erlang
1> minato_oid:element_oid(1009).
25
```
""".
-spec element_oid(oid()) -> oid() | undefined.
element_oid(199) -> 114;
element_oid(1000) -> 16;
element_oid(1001) -> 17;
element_oid(1005) -> 21;
element_oid(1007) -> 23;
element_oid(1009) -> 25;
element_oid(1015) -> 1043;
element_oid(1016) -> 20;
element_oid(1021) -> 700;
element_oid(1022) -> 701;
element_oid(1115) -> 1114;
element_oid(1182) -> 1082;
element_oid(1183) -> 1083;
element_oid(1185) -> 1184;
element_oid(1231) -> 1700;
element_oid(2951) -> 2950;
element_oid(3807) -> 3802;
element_oid(_) -> undefined.

-doc """
The array type OID whose elements are the given scalar type OID.

Returns `undefined` when the OID is not a scalar type minato knows.

```erlang
1> minato_oid:array_oid(25).
1009
```
""".
-spec array_oid(oid()) -> oid() | undefined.
array_oid(16) -> 1000;
array_oid(17) -> 1001;
array_oid(20) -> 1016;
array_oid(21) -> 1005;
array_oid(23) -> 1007;
array_oid(25) -> 1009;
array_oid(114) -> 199;
array_oid(700) -> 1021;
array_oid(701) -> 1022;
array_oid(1043) -> 1015;
array_oid(1082) -> 1182;
array_oid(1083) -> 1183;
array_oid(1114) -> 1115;
array_oid(1184) -> 1185;
array_oid(1700) -> 1231;
array_oid(2950) -> 2951;
array_oid(3802) -> 3807;
array_oid(_) -> undefined.

-doc "Whether the OID names an array type minato knows.".
-spec is_array(oid()) -> boolean().
is_array(Oid) ->
    element_oid(Oid) =/= undefined.

-doc "Every scalar type name minato has a codec for.".
-spec names() -> [name()].
names() ->
    [
        bool,
        bytea,
        int2,
        int4,
        int8,
        float4,
        float8,
        numeric,
        text,
        varchar,
        json,
        jsonb,
        uuid,
        date,
        time,
        timestamp,
        timestamptz
    ].
