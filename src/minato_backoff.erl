-module(minato_backoff).
-moduledoc """
How long to wait before connecting again.

A pool and a listener double their wait each time a connect fails, from the
same start and to the same ceiling, so every node that lost a server at the
same moment would come back to it at the same moments. What is waited is a
random time in the upper half of that, which keeps the backoff and takes the
beat out of it.
""".

-export([spread/1]).

-doc """
A wait of at least half of `Longest` and at most `Longest`, in milliseconds.
""".
-spec spread(pos_integer()) -> pos_integer().
spread(Longest) ->
    Longest - rand:uniform(Longest div 2 + 1) + 1.
