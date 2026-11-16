# Types

What a value comes back as, what minato will accept for it, and what happens to
a type it has no codec for.

## The table

Every type below works in both wire formats, and every one of them has an array
type that works too. Arrays are lists, and an array of more than one dimension
decodes to a list of lists; see [Arrays](#arrays) for how to send one.

| PostgreSQL | Erlang out | Erlang in |
| --- | --- | --- |
| `bool` | `true` \| `false` | the same |
| `bytea` | `binary()` | `binary()` |
| `int2`, `int4`, `int8` | `integer()` | `integer()` |
| `float4`, `float8` | `float()`, or `nan` \| `infinity` \| `neg_infinity` | the same, and `integer()` |
| `numeric` | `binary()`, exact, keeping its display scale | `binary()`, `integer()`, `float()` |
| `text`, `varchar` | `binary()` | `binary()` |
| `json`, `jsonb` | `binary()`, the document as bytes | `binary()` |
| `uuid` | `binary()`, the 36 character form | the 36 character form, 32 hex characters, or the raw 16 bytes |
| `date` | `{Year, Month, Day}` | the same |
| `time` | `{Hour, Minute, Second}` | the same |
| `timestamp`, `timestamptz` | `{{Y,M,D},{H,Mi,S}}` | the same, and `integer()` microseconds |

## NULL

`null` is the NULL sentinel in both directions, and the only one. Not
`undefined`, not `nil`, not an empty binary - those are values.

```erlang
{ok, #{rows := [{null}]}} = minato:query(main, ~"SELECT NULL::int4", []).
{ok, #{rows := [{null}]}} = minato:query(main, ~"SELECT $1::int4", [null]).
```

## The ones worth knowing about

**`numeric` is exact.** It decodes to a binary such as `~"123.4500"`, keeping
the scale the server sent, and never to a float unless you ask. `numeric` is the
type somebody chose *because* binary floating point was not good enough: `0.1`
has no exact representation, anything past about seventeen significant digits is
rounded away, and a column of money summed in floats drifts. A client that
converts by default has quietly thrown away the one property the column was
picked for, and you find out during a reconciliation.

`numeric_format => float` converts anyway, which is the right answer for an
average or a ratio and the wrong one for money:

```erlang
{ok, #{rows := [{3.5}]}} =
    minato:query(main, ~"SELECT avg(n) FROM t", [], #{numeric_format => float}).
```

`NaN`, `Infinity` and `-Infinity` are the atoms `nan`, `infinity` and
`neg_infinity` in both forms.

**`jsonb` is bytes.** minato contains no JSON parser and never will: it does not
know which JSON library you use, whether you want maps or proplists, or whether
you want the document parsed at all. Use OTP's `json` module, or anything else.

**`timestamptz` loses sub-second precision by default**, because
`{{Y,M,D},{H,Mi,S}}` has nowhere to put it. `datetime_format => microseconds`
gives an integer count from the Unix epoch instead, which is lossless.

**`uuid` is the readable form by default.** `uuid_format => binary` gives the
raw 16 bytes, which is what you want if you are hashing or comparing them in
bulk.

## Arrays

A list is an array of one dimension, and each element is a value of the
element type:

```erlang
{ok, #{rows := [{[1, 2, 3]}]}} =
    minato:query(main, ~"SELECT $1::int4[]", [[1, 2, 3]]).
```

An array of more than one dimension, up to the six PostgreSQL has, decodes to a
list of lists. To send one, wrap it in `{array, _}`, which says that every list
in it is a dimension:

```erlang
{ok, #{rows := [{[[1, 2], [3, 4]]}]}} =
    minato:query(main, ~"SELECT $1::int4[]", [{array, [[1, 2], [3, 4]]}]).
```

Without the wrapper a list is never a row. For `text`, `varchar`, `json`,
`jsonb` and `bytea` a list inside a list is one string, given as `iodata()`,
and for every other element type it is refused by the element's codec, as it
always was:

```erlang
[~"ab", ~"cd"]               = sent([[~"a", ~"b"], [~"c", ~"d"]]),
[[~"a", ~"b"], [~"c", ~"d"]] = sent({array, [[~"a", ~"b"], [~"c", ~"d"]]}).
```

where `sent(V)` is what `SELECT $1::text[]` returns for `V`. So
`["12", "34"]` handed to an `int4[]` raises `not_an_integer`: a string written
as a list is a list, and read as a row it would be stored as character codes.
Inside `{array, _}` an element is never a string written as a list.

Rows must all be the same length and depth: anything else is refused with
`ragged_array` before a byte is sent, and a seventh dimension with
`dimensions_out_of_range`. An array with no elements has no dimensions, so
`{array, [[], []]}` is `[]`. Lower bounds other than 1 are read and dropped.

## What raises

A value that cannot be what its type takes is a mistake in the call, so it is
raised, with the statement not run and the connection left ready for the next:

```erlang
error({minato_codec, #{type := Type, reason := Reason, value := Value}})
```

`Type` is the type's name, its OID when minato has no name for it, or
`{array, Oid}` with the array type's OID. `Value` is `redacted` unless
`{minato, [{log_values, true}]}` is set, because the raise is printed by
whatever supervises the caller.

| `Reason` | Raised for |
| --- | --- |
| `not_an_integer`, `not_a_float`, `not_a_boolean`, `not_a_numeric`, `not_a_uuid`, `not_a_date`, `not_a_time`, `not_a_timestamp`, `not_iodata`, `not_a_list` | a value that is not what the type takes at all |
| `out_of_range` | an integer wider than its type, a float `float4` cannot hold, a `numeric` with more digits or a larger scale than PostgreSQL has, a `date` or timestamp at or past the two values the wire keeps for infinity |
| `month_out_of_range`, `day_out_of_range` | a `date` whose month is not 1 to 12, or whose day that month does not have |
| `time_out_of_range` | a `time` outside `{0,0,0}` to `{24,0,0}`, or a count of microseconds longer than a day |
| `ragged_array` | rows of an `{array, _}` that are not all the same length and depth |
| `dimensions_out_of_range` | a seventh dimension, sent or received |
| `unsupported_oid` | a value that is not a binary, for a type minato has no codec for |

Two raises are not about a value's type:

| Raise | Raised for |
| --- | --- |
| `{minato_query, #{reason := parameter_count_mismatch, data := {Wanted, Given}}}` | the wrong number of parameters. The statement was not run |
| `{minato_protocol, #{reason := null_byte, data := Field}}` | a zero byte in the SQL or in a statement or portal name, where `Field` is `query`, `name`, `portal` or `statement`. Nothing was sent. A parameter value may hold any byte |

And one is the server's mistake, not the caller's:
`{minato_protocol, #{message := data_row, reason := column_count_mismatch,
data := {Described, Sent}}}` is a row with another number of columns than the
server said the result has. The answer cannot be read past it, so a pooled
connection is closed and replaced.

## A type minato has no codec for

It still works. The value arrives as its **text representation**, exactly as
PostgreSQL renders it:

```erlang
{ok, #{rows := [{~"1 year"}]}} = minato:query(main, ~"SELECT '1 year'::interval", []).
```

That covers `interval`, `inet`, `macaddr`, `money`, `tsvector`, enums, composite
types, domains, and anything an extension defines. An enum column gives you the
label as a binary; a composite gives you the row literal PostgreSQL prints.
Sending one works the same way: pass the text form as a binary.

This is deliberate. A client that refuses every type it does not model is a
client you cannot use with the schema you already have, and the text
representation is the one thing PostgreSQL guarantees for every type there is.

## Which format is asked for

Per parameter and per column: binary for a type minato has a codec for, text for
everything else. You do not choose, and there is nothing to configure - the
choice is made from the type OID the server reports, which is the only thing
that can be right about it.

## Verifying this yourself

The type table is not a promise, it is a test. `minato_differential_SUITE`
compares every codec against `pg_types` and against PostgreSQL itself, and
`minato_roundtrip_SUITE` runs the same corpus through the whole client - as a
bound parameter and as a column of a real table - and requires the value that
comes back to be the value that went in.
