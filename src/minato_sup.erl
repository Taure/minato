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

-export([start_link/0, start_pool/2, stop_pool/1, start_listener/2, stop_listener/1, reserved/1]).
-export([init/1]).

-doc "Start the supervisor and every pool the environment declares.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc """
Add a pool at run time.

`{error, {reserved_name, Name}}` for a name minato's own processes are
registered under and kept by: see `reserved/1`.
""".
-spec start_pool(minato_pool:name(), minato_pool:opts()) -> supervisor:startchild_ret().
start_pool(Name, Opts) ->
    started(minato_pool, Name, Opts).

-doc "Add a listener at run time. The same names are reserved as for a pool.".
-spec start_listener(minato_listener:name(), minato_listener:opts()) ->
    supervisor:startchild_ret().
start_listener(Name, Opts) ->
    started(minato_listener, Name, Opts).

-spec started(module(), atom(), dynamic()) -> supervisor:startchild_ret().
started(Module, Name, Opts) ->
    case reserved(Name) of
        true -> {error, {reserved_name, Name}};
        false -> unwrapped(supervisor:start_child(?MODULE, child(Module, Name, Opts)))
    end.

-doc """
Whether a name is one of minato's own and so not a pool's or a listener's.

`minato_overdue` is the child that bounds TLS writes and `minato_sup` is this
supervisor. A pool under either name would be mistaken for it: started, it
would answer with the pid of a process that is not a pool, and stopped, it
would take that process with it.
""".
-spec reserved(term()) -> boolean().
reserved(minato_overdue) -> true;
reserved(minato_sup) -> true;
reserved(_Name) -> false.

%% A start error carries the child spec, and with it the connection options.
-spec unwrapped(supervisor:startchild_ret()) -> supervisor:startchild_ret().
unwrapped({error, {already_started, Pid}} = Started) when is_pid(Pid) -> Started;
unwrapped({error, {Reason, _ChildSpec}}) -> {error, Reason};
unwrapped(Started) -> Started.

-doc "Stop a listener and forget it.".
-spec stop_listener(minato_listener:name()) -> ok | {error, not_found}.
stop_listener(Name) ->
    stop_pool(Name).

-doc "Stop a pool and forget it.".
-spec stop_pool(minato_pool:name()) -> ok | {error, not_found}.
stop_pool(Name) ->
    case reserved(Name) of
        true -> {error, not_found};
        false -> stopped(Name)
    end.

-spec stopped(atom()) -> ok | {error, not_found}.
stopped(Name) ->
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
    Pools = declared(pools),
    Listeners = declared(listeners),
    ok = unreserved(maps:keys(Pools) ++ maps:keys(Listeners)),
    Children =
        [overdue()] ++
            [child(minato_pool, Name, Opts) || Name := Opts <- Pools] ++
            [child(minato_listener, Name, Opts) || Name := Opts <- Listeners],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 60}, Children}}.

-spec overdue() -> supervisor:child_spec().
overdue() ->
    #{
        id => minato_overdue,
        start => {minato_overdue, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.

%% A pool declared under one of minato's own names would start as a second
%% child with the same id, which a supervisor refuses in terms that say nothing
%% of why. The application does not start, and says which name.
-spec unreserved([term()]) -> ok.
unreserved(Names) ->
    case [Name || Name <- Names, reserved(Name)] of
        [] -> ok;
        [Name | _Rest] -> exit({reserved_name, Name})
    end.

-spec declared(pools | listeners) -> #{dynamic() => dynamic()}.
declared(Key) ->
    case application:get_env(minato, Key) of
        {ok, Declared} when is_map(Declared) -> Declared;
        _None -> #{}
    end.

%% A supervisor prints its child specs, so the password and ssl_options go in sealed.
-spec child(module(), atom(), dynamic()) -> supervisor:child_spec().
child(Module, Name, Opts) ->
    #{
        id => Name,
        start => {Module, start_link, [Name, minato_secret:seal_options(Opts)]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.
