%%%-------------------------------------------------------------------
%% @doc sibyl public API
%% @end
%%%-------------------------------------------------------------------

-module(sibyl_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    _ = sibyl_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
