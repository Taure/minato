-module(minato_secret).
-moduledoc false.

%% A password kept as a closure prints as `#Fun<...>`, so a child spec, a crash
%% report, a stacktrace or a process state that holds the options does not show
%% it. The closures are made in this module alone so that reloading the modules
%% which keep them does not leave a fun to purged code in a pool's child spec.

-export([pool/1, connection/1]).

-spec pool(dynamic()) -> dynamic().
pool(#{connection := #{} = Connection} = Opts) ->
    Opts#{connection => connection(Connection)};
pool(Opts) ->
    Opts.

-spec connection(minato_conn:opts()) -> minato_conn:opts().
connection(Connection) ->
    maps:map(fun sealed/2, Connection).

-spec sealed(term(), dynamic()) -> dynamic().
sealed(password, Password) when is_binary(Password); is_list(Password) ->
    closure(Password);
sealed(ssl_options, Options) when is_list(Options) ->
    [tls(Option) || Option <- Options];
sealed(_Key, Value) ->
    Value.

-spec tls(dynamic()) -> dynamic().
tls({password, Password}) when is_binary(Password); is_list(Password) ->
    {password, closure(Password)};
tls(Option) ->
    Option.

-spec closure(binary() | list()) -> fun(() -> binary() | list()).
closure(Secret) ->
    fun() -> Secret end.
