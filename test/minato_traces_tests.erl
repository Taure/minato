-module(minato_traces_tests).
-moduledoc """
Holds the observability guide to the module it shows.

The guide prints `m:minato_traces` whole, and a module on a page is not
compiled by anything. This compares the page with the file that is.
""".

-include_lib("eunit/include/eunit.hrl").

the_guide_shows_the_module_that_is_tested_test() ->
    {ok, Guide} = file:read_file(filename:join(root(), "guides/observability.md")),
    {ok, Module} = file:read_file(filename:join(root(), "test/minato_traces.erl")),
    Shown = <<"```erlang\n", Module/binary, "```\n">>,
    ?assertNotEqual(nomatch, binary:match(Guide, Shown)).

%% `rebar3 eunit` runs where `rebar.config` is, wherever it builds.
root() ->
    {ok, Root} = file:get_cwd(),
    Root.
