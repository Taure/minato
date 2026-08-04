-module(minato_saslprep).
-moduledoc """
SASLprep (RFC 4013) preparation of a password, as far as OTP can carry it.

SCRAM hashes `Normalize(password)` rather than the password, so a client that
normalises differently from the server derives a different key and fails against
a verifier the server itself computed. This module exists to agree with
PostgreSQL, not to be a general stringprep library.

## What is handled

RFC 4013 is a profile of stringprep (RFC 3454) and runs in four steps. Three of
them are here:

1. **Mapping.** The "commonly mapped to nothing" characters of table B.1 are
   removed, and the non-ASCII space characters of table C.1.2 become SPACE
   (U+0020). B.1 is applied first, which settles U+200B ZERO WIDTH SPACE: it is
   listed in both tables, and removal is what the wider profile family does
   with it.
2. **Normalisation.** Unicode NFKC, through `unicode:characters_to_nfkc_list/1`.
3. **Prohibited output.** Every character of tables C.1.2, C.2.1, C.2.2, C.3,
   C.4, C.5, C.6, C.7, C.8 and C.9 is rejected. The check runs after
   normalisation, because NFKC can produce characters the input did not hold.
   Those tables overlap each other, and a character in more than one of them is
   reported under the first that claims it, so the name in a `t:reason/0` says
   which rule caught it and not that it was the only applicable rule.

   Running the check on the output rather than the input is what RFC 3454
   section 7 orders, and it has a consequence worth knowing: a prohibited
   character that normalisation replaces is never seen by this step. U+0340
   COMBINING GRAVE TONE MARK is prohibited by table C.8 and decomposed by NFKC
   to U+0300, which is not, so a password holding one is accepted with the
   substitution made. That is the specified behaviour and not a hole: the
   character has gone.

Printable ASCII, which is what almost every password is, takes none of those
branches: nothing in it is mapped, NFKC is the identity on it, and nothing in it
is prohibited, so the bytes come back exactly as they went in. Control
characters are the one ASCII case not passed through, and table C.2.1 prohibits
them rather than this module ignoring them.

## What is not handled

- **The bidirectional check** of RFC 3454 section 6. It needs the bidirectional
  category of every code point, which is tables D.1 and D.2 of RFC 3454, and OTP
  publishes neither. The rule it enforces is that a string mixing right-to-left
  and left-to-right characters must not display ambiguously, which is a
  presentation property of an identifier. A password is never displayed.
- **The unassigned code point check** of RFC 3454 table A.1. It is defined
  against Unicode 3.2 specifically, while OTP normalises against whatever
  version it was built with, so there is no table to check against and no way
  to obtain one that would still give the 3.2 answer.

Neither omission can make this module accept a password and derive a different
key from a server that ran the whole algorithm. Both are input rejection rules,
so the only strings they cover are ones that would otherwise have been refused,
and `prepare/1` already falls back to the raw bytes for those.

## Falling back to the raw password

PostgreSQL documents that it prepares a password with SASLprep as though it were
UTF-8 whatever encoding it is really in, and that "if it is not a legal UTF-8
byte sequence, or it contains UTF-8 byte sequences that are prohibited by the
SASLprep algorithm, the raw password will be used without SASLprep processing,
instead of throwing an error".

That decision is taken on the server when the verifier is stored, so a client
that rejected those passwords instead could not authenticate against a verifier
the server was perfectly happy to write. `prepare/1` therefore returns the
untouched input whenever preparation cannot be completed, which reaches the same
bytes the server hashed. `normalise/1` reports the reason instead, for callers
and tests that want to see the decision rather than its result.
""".

-export([prepare/1, normalise/1]).

-doc """
Why a password could not be prepared.

`not_utf8` is a byte sequence that is not valid UTF-8. `{prohibited, Table,
Codepoint}` is a character RFC 4013 forbids in output, named for the RFC 3454
table that forbids it.
""".
-type reason() :: not_utf8 | {prohibited, table(), char()}.

-doc "An RFC 3454 table of prohibited output, under a name for what it holds.".
-type table() ::
    ascii_control
    | non_ascii_control
    | non_ascii_space
    | private_use
    | non_character
    | surrogate
    | inappropriate_for_plain_text
    | inappropriate_for_canonical_representation
    | change_display_properties
    | tagging.

-export_type([reason/0, table/0]).

-doc """
Prepare a password for SCRAM, falling back to the raw bytes.

```erlang
1> minato_saslprep:prepare(~"pencil").
<<"pencil">>
2> minato_saslprep:prepare(<<"a", 16#C2, 16#A0, "b">>).
<<"a b">>
```

Never raises. A password this module cannot prepare comes back exactly as it
arrived, because that is the password PostgreSQL hashed when it stored the
verifier. See the module documentation.
""".
-spec prepare(binary()) -> binary().
prepare(Password) ->
    case normalise(Password) of
        {ok, Prepared} -> Prepared;
        {error, _Reason} -> Password
    end.

-doc """
Prepare a password, reporting why when it cannot be done.

```erlang
1> minato_saslprep:normalise(~"pencil").
{ok,<<"pencil">>}
2> minato_saslprep:normalise(<<"pen", 7, "cil">>).
{error,{prohibited,ascii_control,7}}
3> minato_saslprep:normalise(<<16#FF>>).
{error,not_utf8}
```
""".
-spec normalise(binary()) -> {ok, binary()} | {error, reason()}.
normalise(Password) ->
    case unicode:characters_to_list(Password, utf8) of
        Codepoints when is_list(Codepoints) -> normalised(mapped(Codepoints));
        _NotUtf8 -> {error, not_utf8}
    end.

-spec normalised([char()]) -> {ok, binary()} | {error, reason()}.
normalised(Mapped) ->
    case unicode:characters_to_nfkc_list(Mapped) of
        Codepoints when is_list(Codepoints) -> checked(Codepoints);
        _NotUtf8 -> {error, not_utf8}
    end.

-spec checked([char()]) -> {ok, binary()} | {error, reason()}.
checked(Codepoints) ->
    case prohibited(Codepoints) of
        none -> encoded(Codepoints);
        {Table, Codepoint} -> {error, {prohibited, Table, Codepoint}}
    end.

-spec encoded([char()]) -> {ok, binary()} | {error, reason()}.
encoded(Codepoints) ->
    case unicode:characters_to_binary(Codepoints, utf8, utf8) of
        Prepared when is_binary(Prepared) -> {ok, Prepared};
        _NotUtf8 -> {error, not_utf8}
    end.

-spec mapped([char()]) -> [char()].
mapped(Codepoints) ->
    [space_or_self(Codepoint) || Codepoint <- Codepoints, not mapped_to_nothing(Codepoint)].

-spec space_or_self(char()) -> char().
space_or_self(Codepoint) ->
    case non_ascii_space(Codepoint) of
        true -> $\s;
        false -> Codepoint
    end.

-spec mapped_to_nothing(char()) -> boolean().
mapped_to_nothing(16#00AD) -> true;
mapped_to_nothing(16#034F) -> true;
mapped_to_nothing(16#1806) -> true;
mapped_to_nothing(Codepoint) when Codepoint >= 16#180B, Codepoint =< 16#180D -> true;
mapped_to_nothing(Codepoint) when Codepoint >= 16#200B, Codepoint =< 16#200D -> true;
mapped_to_nothing(16#2060) -> true;
mapped_to_nothing(Codepoint) when Codepoint >= 16#FE00, Codepoint =< 16#FE0F -> true;
mapped_to_nothing(16#FEFF) -> true;
mapped_to_nothing(_Codepoint) -> false.

-spec non_ascii_space(char()) -> boolean().
non_ascii_space(16#00A0) -> true;
non_ascii_space(16#1680) -> true;
non_ascii_space(Codepoint) when Codepoint >= 16#2000, Codepoint =< 16#200B -> true;
non_ascii_space(16#202F) -> true;
non_ascii_space(16#205F) -> true;
non_ascii_space(16#3000) -> true;
non_ascii_space(_Codepoint) -> false.

-spec prohibited([char()]) -> none | {table(), char()}.
prohibited([]) ->
    none;
prohibited([Codepoint | Codepoints]) ->
    case table(Codepoint) of
        none -> prohibited(Codepoints);
        Table -> {Table, Codepoint}
    end.

-spec table(char()) -> none | table().
table(Codepoint) when Codepoint =< 16#001F -> ascii_control;
table(16#007F) ->
    ascii_control;
table(Codepoint) when Codepoint >= 16#0080, Codepoint =< 16#009F -> non_ascii_control;
table(16#06DD) ->
    non_ascii_control;
table(16#070F) ->
    non_ascii_control;
table(16#180E) ->
    non_ascii_control;
table(Codepoint) when Codepoint >= 16#2028, Codepoint =< 16#2029 -> non_ascii_control;
table(Codepoint) when Codepoint >= 16#2060, Codepoint =< 16#2063 -> non_ascii_control;
table(Codepoint) when Codepoint >= 16#1D173, Codepoint =< 16#1D17A -> non_ascii_control;
table(16#0340) ->
    change_display_properties;
table(16#0341) ->
    change_display_properties;
table(Codepoint) when Codepoint >= 16#200E, Codepoint =< 16#200F -> change_display_properties;
table(Codepoint) when Codepoint >= 16#202A, Codepoint =< 16#202E -> change_display_properties;
table(Codepoint) when Codepoint >= 16#206A, Codepoint =< 16#206F -> change_display_properties;
table(Codepoint) when Codepoint >= 16#D800, Codepoint =< 16#DFFF -> surrogate;
table(Codepoint) when Codepoint >= 16#E000, Codepoint =< 16#F8FF -> private_use;
table(Codepoint) when Codepoint >= 16#F0000, Codepoint =< 16#FFFFD -> private_use;
table(Codepoint) when Codepoint >= 16#100000, Codepoint =< 16#10FFFD -> private_use;
table(Codepoint) when Codepoint >= 16#FDD0, Codepoint =< 16#FDEF -> non_character;
table(Codepoint) when (Codepoint band 16#FFFF) >= 16#FFFE -> non_character;
table(Codepoint) when Codepoint >= 16#FFF9, Codepoint =< 16#FFFD -> inappropriate_for_plain_text;
table(Codepoint) when Codepoint >= 16#2FF0, Codepoint =< 16#2FFB ->
    inappropriate_for_canonical_representation;
table(16#E0001) ->
    tagging;
table(Codepoint) when Codepoint >= 16#E0020, Codepoint =< 16#E007F -> tagging;
table(Codepoint) ->
    non_ascii_space_or_none(Codepoint).

-spec non_ascii_space_or_none(char()) -> none | non_ascii_space.
non_ascii_space_or_none(Codepoint) ->
    case non_ascii_space(Codepoint) of
        true -> non_ascii_space;
        false -> none
    end.
