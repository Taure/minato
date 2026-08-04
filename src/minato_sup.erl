-module(minato_sup).
-moduledoc """
The supervisor over the pools.

Pools declared in the application environment are started here, so an
application whose database is not up yet still starts: a pool is up before it
has connections, and fills in the background.

```erlang
{minato, [{pools, #{main => #{size => 10, connection => #{user => ~"minato"}}}}]}
```

`start_pool/2` adds one at run time. A pool is `one_for_one` and permanent: it
holds sockets, and a pool that died and stayed dead would take every caller with
it.
""".

-behaviour(supervisor).

-export([start_link/0, start_pool/2, stop_pool/1]).
-export([init/1]).

-doc "Start the supervisor and every pool the environment declares.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Add a pool at run time.".
-spec start_pool(minato_pool:name(), minato_pool:opts()) -> supervisor:startchild_ret().
start_pool(Name, Opts) ->
    supervisor:start_child(?MODULE, child(Name, Opts)).

-doc "Stop a pool and forget it.".
-spec stop_pool(minato_pool:name()) -> ok | {error, not_found}.
stop_pool(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok -> deleted(supervisor:delete_child(?MODULE, Name));
        {error, _Reason} -> {error, not_found}
    end.

-spec deleted(ok | {error, term()}) -> ok | {error, not_found}.
deleted(ok) -> ok;
deleted({error, _Reason}) -> {error, not_found}.

-doc false.
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Children = [child(Name, Opts) || Name := Opts <- declared()],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 60}, Children}}.

-spec declared() -> #{dynamic() => dynamic()}.
declared() ->
    case application:get_env(minato, pools) of
        {ok, Pools} when is_map(Pools) -> Pools;
        _None -> #{}
    end.

-spec child(minato_pool:name(), minato_pool:opts()) -> supervisor:child_spec().
child(Name, Opts) ->
    #{
        id => Name,
        start => {minato_pool, start_link, [Name, Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.
