%%%-------------------------------------------------------------------
%% @doc sibyl top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(sibyl_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SUP(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => supervisor,
    modules => [I]
}).

-define(WORKER(I, Args), #{
    id => I,
    start => {I, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

-define(WORKER(I, Mod, Args), #{
    id => I,
    start => {Mod, start_link, Args},
    restart => permanent,
    shutdown => 5000,
    type => worker,
    modules => [I]
}).

-define(FLAGS, #{
    strategy => one_for_one,
    intensity => 1,
    period => 5
}).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    {ok,
        {?FLAGS, [
            ?SUP(routing_updates_sup, []),
            ?WORKER(sibyl_mgr, [])
        ]}}.

%% internal functions
