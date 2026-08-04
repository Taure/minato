-module(minato_pg_raw).
-moduledoc """
A `pg_types` type module that carries wire bytes through untouched.

The differential suite needs to put minato's own bytes on the wire and read the
server's bytes back without a second codec in between. `pg_types` dispatches on
a per pool, per OID entry in its registry, so registering this module for the
OID under test turns the driver into a pipe: what minato encoded is what
PostgreSQL parses, and what PostgreSQL sends is what minato decodes.

That makes the server the judge. If minato's bytes are wrong for the type,
PostgreSQL rejects them with an error of its own rather than a client library
quietly repairing them.
""".

-export([init/1, encode/2, decode/2, type_spec/0]).

-doc "No configuration: the module is the same for every type it stands in for.".
-spec init(dynamic()) -> {[binary()], []}.
init(_Options) ->
    {[], []}.

-doc "Prefix the caller's bytes with their length, which is all the protocol needs.".
-spec encode(binary(), dynamic()) -> iodata().
encode(Bytes, _Config) when is_binary(Bytes) ->
    [<<(byte_size(Bytes)):32/signed>>, Bytes].

-doc "Hand the value bytes back exactly as they arrived.".
-spec decode(binary(), dynamic()) -> binary().
decode(Bytes, _Config) ->
    Bytes.

-doc "Only ever seen by `pg_types` itself.".
-spec type_spec() -> string().
type_spec() ->
    "binary()".
