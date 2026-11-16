-module(minato_traces_tests).
-moduledoc """
Holds the observability guide to the module it shows.

The guide prints `m:minato_traces` whole, and a module on a page is not
compiled by anything. This compares the page with the file that is.
""".

-include_lib("eunit/include/eunit.hrl").

the_guide_shows_the_module_that_is_tested_test() ->
    Guide = text("guides/observability.md"),
    Module = text("test/minato_traces.erl"),
    Shown = <<"```erlang\n", Module/binary, "```\n">>,
    ?assertNotEqual(nomatch, binary:match(Guide, Shown)).

%% A checkout on Windows ends its lines with a carriage return as well.
text(Path) ->
    {ok, Bytes} = file:read_file(filename:join(root(), Path)),
    binary:replace(Bytes, ~"\r\n", ~"\n", [global]).

%% `rebar3 eunit` runs where `rebar.config` is, wherever it builds.
root() ->
    {ok, Root} = file:get_cwd(),
    Root.
