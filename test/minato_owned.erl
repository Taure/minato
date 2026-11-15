-module(minato_owned).
-moduledoc """
A pool or a listener under the supervisor that goes when the test that started
it does.

A test that is killed, by its timeout or by a run that is cut short, runs no
`after`, and what it started under `minato_sup` is not linked to it: it stays,
connecting to a server that is gone, for as long as the node does. Each is
watched here by a process that is one of the application's and not one of the
run's, so that whatever ends the run leaves it standing, and stopped when the
process that asked for it is gone.
""".

-export([pool/2, listener/2]).

-doc "`minato:start_pool/2`, for a pool that is stopped when the caller exits.".
-spec pool(minato:pool(), minato_pool:opts()) -> supervisor:startchild_ret().
pool(Name, Opts) ->
    ok = watched({pool, Name}),
    minato:start_pool(Name, Opts).

-doc "`minato:start_listener/2`, for a listener that is stopped when the caller exits.".
-spec listener(minato_listener:name(), minato_listener:opts()) -> supervisor:startchild_ret().
listener(Name, Opts) ->
    ok = watched({listener, Name}),
    minato:start_listener(Name, Opts).

-spec watched({pool | listener, atom()}) -> ok.
watched(Started) ->
    {ok, _Applications} = application:ensure_all_started(minato),
    Application = group_leader_of(whereis(minato_sup)),
    Owner = self(),
    _ = spawn(fun() ->
        true = group_leader(Application, self()),
        Monitor = erlang:monitor(process, Owner),
        receive
            {'DOWN', Monitor, process, Owner, _Reason} -> stopped(Started)
        end
    end),
    ok.

-spec group_leader_of(pid() | port() | undefined) -> pid().
group_leader_of(Supervisor) when is_pid(Supervisor) ->
    {group_leader, Leader} = erlang:process_info(Supervisor, group_leader),
    Leader.

-spec stopped({pool | listener, atom()}) -> ok | {error, not_found}.
stopped({pool, Name}) -> minato:stop_pool(Name);
stopped({listener, Name}) -> minato:stop_listener(Name).
