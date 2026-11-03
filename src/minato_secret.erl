-module(minato_secret).
-moduledoc false.

%% The password and the TLS options are kept as closures, which print as
%% `#Fun<...>`, so a child spec, a crash report, a stacktrace or a process state
%% that holds the connection options does not show them. This is hygiene for
%% logs and reports, not a boundary: code running on the node can read a
%% closure's environment with `erlang:fun_info/2`.
%%
%% minato never calls a closure it made. A hot upgrade that changes this module
%% and purges the old version leaves every such closure raising `badfun` when
%% called, while its environment can still be read. A fun from anywhere else is
%% the caller's own and is called.

-export([pool/1, connection/1, revealed/1]).

-spec pool(dynamic()) -> dynamic().
pool(#{connection := #{} = Connection} = Opts) ->
    Opts#{connection => connection(Connection)};
pool(Opts) ->
    Opts.

-spec connection(minato_conn:opts()) -> minato_conn:opts().
connection(Connection) ->
    maps:map(fun sealed/2, Connection).

-spec revealed(dynamic()) -> dynamic().
revealed(Sealed) when is_function(Sealed, 0) ->
    case erlang:fun_info(Sealed, module) of
        {module, ?MODULE} ->
            {env, [Secret]} = erlang:fun_info(Sealed, env),
            Secret;
        {module, _Caller} ->
            Sealed()
    end;
revealed(Secret) ->
    Secret.

-spec sealed(term(), dynamic()) -> dynamic().
sealed(password, Password) when is_binary(Password) ->
    closure(Password);
sealed(password, Password) when is_list(Password) ->
    closure(text(Password));
sealed(ssl_options, Options) when is_list(Options) ->
    closure(Options);
sealed(_Key, Value) ->
    Value.

%% A password given as a string is turned into the binary the authentication
%% code expects here, where a failure can be reported without the password.
-spec text(list()) -> binary().
text(Password) ->
    try unicode:characters_to_binary(Password) of
        Text when is_binary(Text) -> Text;
        _NotText -> not_text()
    catch
        error:_NotText -> not_text()
    end.

-spec not_text() -> no_return().
not_text() ->
    error({minato_conn, #{message => password, reason => not_text, data => undefined}}).

-spec closure(term()) -> fun(() -> term()).
closure(Secret) ->
    fun() -> Secret end.
