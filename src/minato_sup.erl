-module(minato_sup).
-moduledoc """
The supervisor over the pools.

Pools declared in the application environment are started here, so an
application whose database is not up yet still starts: a pool is up before it
has connections, and fills in the background.

```erlang
{minato, [{pools, #{main => #{size => 10, connection => #{user => ~"minato"}}}},
          {listeners, #{events => #{connection => #{user => ~"minato"}}}}]}
```

`start_pool/2` and `start_listener/2` add one at run time. A pool is `one_for_one` and permanent: it
holds sockets, and a pool that died and stayed dead would take every caller with
it.
""".

-behaviour(supervisor).

-export([start_link/0, start_pool/2, stop_pool/1, start_listener/2, stop_listener/1]).
-export([init/1]).

-doc "Start the supervisor and every pool the environment declares.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "Add a pool at run time.".
-spec start_pool(minato_pool:name(), minato_pool:opts()) -> supervisor:startchild_ret().
start_pool(Name, Opts) ->
    supervisor:start_child(?MODULE, child(minato_pool, Name, Opts)).

-doc "Add a listener at run time.".
-spec start_listener(minato_listener:name(), minato_listener:opts()) ->
    supervisor:startchild_ret().
start_listener(Name, Opts) ->
    supervisor:start_child(?MODULE, child(minato_listener, Name, Opts)).

-doc "Stop a listener and forget it.".
-spec stop_listener(minato_listener:name()) -> ok | {error, not_found}.
stop_listener(Name) ->
    stop_pool(Name).

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
    Pools = [child(minato_pool, Name, Opts) || Name := Opts <- declared(pools)],
    Listeners = [child(minato_listener, Name, Opts) || Name := Opts <- declared(listeners)],
    Children = Pools ++ Listeners,
    {ok, {#{strategy => one_for_one, intensity => 10, period => 60}, Children}}.

-spec declared(pools | listeners) -> #{dynamic() => dynamic()}.
declared(Key) ->
    case application:get_env(minato, Key) of
        {ok, Declared} when is_map(Declared) -> Declared;
        _None -> #{}
    end.

-spec child(module(), atom(), dynamic()) -> supervisor:child_spec().
child(Module, Name, Opts) ->
    #{
        id => Name,
        start => {Module, start_link, [Name, Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.
