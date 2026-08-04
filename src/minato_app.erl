-module(minato_app).
-moduledoc """
The application. Starts the supervisor, which starts whatever pools the
environment declares.
""".

-behaviour(application).

-export([start/2, stop/1]).

-doc "Start minato's supervision tree.".
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    case minato_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, Reason};
        ignore -> {error, ignore}
    end.

-doc "Nothing to undo: the supervisor closes the connections as it goes down.".
-spec stop(term()) -> ok.
stop(_State) ->
    ok.
