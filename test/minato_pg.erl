-module(minato_pg).
-moduledoc """
The test time PostgreSQL driver for the differential suite.

Driving the server needs a client, and minato has no protocol layer yet, so the
suite borrows `pgo` for the job. `pgo` is a test profile dependency used as a
transport and nothing else: every byte it carries is produced or consumed by
minato, never by `pg_types`, because `patch/1` swaps the type registry entry for
the OID under test to `m:minato_pg_raw` first.

## Two pools

`pg_types` keys its type registry on the pool, so the suite opens two. The wire
pool is patched and carries minato's bytes untouched in both directions. The
oracle pool is left alone, and `type_info/1` reads the descriptors the oracle
would have used out of it. One pool cannot do both jobs: patching it would mean
the oracle grading itself against the passthrough.

## What the server is asked

- `roundtrip/2` sends minato's binary encoding as a parameter and reads back
  both the server's own binary representation of the value it parsed and its
  text representation. That is the strongest check available: PostgreSQL parsed
  the bytes with its `recv` function and re-emitted them with its `send`
  function, so agreement means agreement with the server and not with a
  second implementation of the same guess.
- `from_text/2` sends minato's text encoding and reads back the server's binary
  representation, which is how the text path is judged. `pg_types` has no text
  path at all, so here the server is the only reference there is.

## Configuration

`MINATO_PG_HOST`, `MINATO_PG_PORT`, `MINATO_PG_DATABASE`, `MINATO_PG_USER` and
`MINATO_PG_PASSWORD`, defaulting to a throwaway container on port 55432. When
no server answers, `start/0` says so and the suite skips rather than fails: the
harness is a gate for minato, not a reason for a laptop without Docker to go
red.
""".

-export([start/0, patch/1, type_info/1, roundtrip/2, from_text/2, query/2]).

-define(WIRE_POOL, minato_differential_wire).
-define(ORACLE_POOL, minato_differential_oracle).

-doc """
Start `pgo` and open both pools.

Answers `{skip, Reason}` when no server answers or the session is not at UTC,
because an offset changes every `timestamptz` text representation and would make
the text comparisons meaningless. The offset is checked rather than the zone
name, since UTC goes by several names.
""".
-spec start() -> ok | {skip, term()}.
start() ->
    {ok, _} = application:ensure_all_started(pgo),
    case open(?WIRE_POOL) of
        ok ->
            case open(?ORACLE_POOL) of
                ok -> check_server();
                Skip -> Skip
            end;
        Skip ->
            Skip
    end.

-spec open(atom()) -> ok | {skip, term()}.
open(Pool) ->
    case pgo:start_pool(Pool, pool_options()) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        Other -> {skip, {pool_failed, Pool, Other}}
    end.

-spec pool_options() -> map().
pool_options() ->
    #{
        pool_size => 2,
        queue_target => 5000,
        host => env("MINATO_PG_HOST", "127.0.0.1"),
        port => list_to_integer(env("MINATO_PG_PORT", "55432")),
        database => env("MINATO_PG_DATABASE", "minato_test"),
        user => env("MINATO_PG_USER", "minato"),
        password => env("MINATO_PG_PASSWORD", "minato")
    }.

-spec env(string(), string()) -> string().
env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.

-spec check_server() -> ok | {skip, term()}.
check_server() ->
    Sql = ~"select current_setting('TimeZone'), extract(timezone from now())::int",
    case query(Sql, []) of
        {ok, [{_Zone, 0}]} -> ok;
        {ok, [{Zone, Offset}]} -> {skip, {server_not_utc, Zone, Offset}};
        {ok, Rows} -> {skip, {unexpected_rows, Rows}};
        {error, Reason} -> {skip, {server_unreachable, Reason}}
    end.

-doc "Run a query on the wire pool, normalising `pgo`'s answer to a rows or error tuple.".
-spec query(binary(), [term()]) -> {ok, [dynamic()]} | {error, term()}.
query(Sql, Parameters) ->
    try pgo:query(Sql, Parameters, #{pool => ?WIRE_POOL}) of
        #{rows := Rows} -> {ok, Rows};
        Other -> {error, Other}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

-doc """
Register `m:minato_pg_raw` for each OID on the wire pool.

The registry entry is a record private to `pg_types`, so the module field is
replaced by position. The field is asserted to hold a `pg_` module first, so a
`pg_types` release that reorders the record fails loudly here rather than
silently testing the wrong thing.
""".
-spec patch([minato_oid:oid()]) -> ok.
patch([]) ->
    ok;
patch([Oid | Rest]) ->
    ok = patch_one(Oid),
    patch(Rest).

-spec patch_one(minato_oid:oid()) -> ok.
patch_one(Oid) ->
    Original = pg_types:lookup_type_info(?WIRE_POOL, Oid),
    "pg_" ++ _ = atom_to_list(element(3, Original)),
    Patched = setelement(3, Original, minato_pg_raw),
    true = ets:insert(pg_types_table, {{?WIRE_POOL, Oid}, Patched}),
    ok.

-doc """
The type descriptor the oracle would have used for an OID.

Read from the pool `patch/1` never touched. `pg_types` does not export the type
of its descriptors, so the answer is `dynamic()`: it is only ever handed back to
`pg_types`.
""".
-spec type_info(minato_oid:oid()) -> dynamic().
type_info(Oid) ->
    case pg_types:lookup_type_info(?ORACLE_POOL, Oid) of
        unknown_oid -> error({unknown_oid, Oid});
        TypeInfo -> TypeInfo
    end.

-doc """
Send minato's binary encoding of a value and read back what the server makes of
it, in both of the server's own representations.
""".
-spec roundtrip(binary(), binary()) -> {ok, binary(), binary()} | {error, term()}.
roundtrip(SqlType, Bytes) ->
    Sql = <<"select $1::", SqlType/binary, ", ($1::", SqlType/binary, ")::text">>,
    case query(Sql, [Bytes]) of
        {ok, [{Binary, Text}]} when is_binary(Binary), is_binary(Text) -> {ok, Binary, Text};
        {ok, Rows} -> {error, {unexpected_rows, Rows}};
        {error, Reason} -> {error, Reason}
    end.

-doc """
Send minato's text encoding of a value and read back the server's binary
representation of what it parsed.
""".
-spec from_text(binary(), binary()) -> {ok, binary()} | {error, term()}.
from_text(SqlType, Text) ->
    Sql = <<"select ($1::text)::", SqlType/binary>>,
    case query(Sql, [Text]) of
        {ok, [{Binary}]} when is_binary(Binary) -> {ok, Binary};
        {ok, Rows} -> {error, {unexpected_rows, Rows}};
        {error, Reason} -> {error, Reason}
    end.
