# Types

What a value comes back as, what minato will accept for it, and what happens to
a type it has no codec for.

## The table

Every type below works in both wire formats, and every one of them has an array
type that works too. Arrays are lists; encoding writes one dimension, decoding
reads any number and nests.

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
