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

What is watched is the process that was started, not its name. Every test of a
module runs in one process, so the process that asked is gone when the whole
run is, which is when the next run starts under the same names: a watcher that
stopped a name would stop what that run had just started. One that has seen
its own pool or listener go has nothing left to do, and one whose owner went
first stops what it was given only while the supervisor still has that very
process under the name. A pool the supervisor restarted is another process and
is no longer watched.
""".

-export([pool/2, listener/2]).

-doc "`minato:start_pool/2`, for a pool that is stopped when the caller exits.".
-spec pool(minato:pool(), minato_pool:opts()) -> supervisor:startchild_ret().
pool(Name, Opts) ->
    {ok, _Applications} = application:ensure_all_started(minato),
    watched(Name, minato:start_pool(Name, Opts)).

-doc "`minato:start_listener/2`, for a listener that is stopped when the caller exits.".
-spec listener(minato_listener:name(), minato_listener:opts()) -> supervisor:startchild_ret().
listener(Name, Opts) ->
    {ok, _Applications} = application:ensure_all_started(minato),
    watched(Name, minato:start_listener(Name, Opts)).

-spec watched(atom(), supervisor:startchild_ret()) -> supervisor:startchild_ret().
watched(Name, {ok, Started} = Answer) when is_pid(Started) ->
    Application = group_leader_of(whereis(minato_sup)),
    Owner = self(),
    _ = spawn(fun() ->
        true = group_leader(Application, self()),
        Owning = erlang:monitor(process, Owner),
        Running = erlang:monitor(process, Started),
        receive
            {'DOWN', Running, process, Started, _Reason} -> ok;
            {'DOWN', Owning, process, Owner, _Reason} -> stopped(Name, Started)
        end
    end),
    Answer;
watched(_Name, NotStarted) ->
    NotStarted.

-spec group_leader_of(pid() | port() | undefined) -> pid().
group_leader_of(Supervisor) when is_pid(Supervisor) ->
    {group_leader, Leader} = erlang:process_info(Supervisor, group_leader),
    Leader.

-spec stopped(atom(), pid()) -> ok | {error, not_found}.
stopped(Name, Started) ->
    try supervisor:which_children(minato_sup) of
        Children ->
            case lists:keyfind(Started, 2, Children) of
                {Name, Started, _Type, _Modules} -> minato_sup:stop_pool(Name);
                _Another -> ok
            end
    catch
        exit:_NoSupervisor -> ok
    end.
