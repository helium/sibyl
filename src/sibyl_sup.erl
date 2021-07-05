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
    %% create the sibyl_mgr ets table under this supervisor and set ourselves as the heir
    %% we call `ets:give_away' every time we start_link sibyl_mgr
    _ = sibyl_bus:start(),
    SibylMgrOpts = [{ets, sibyl_mgr:make_ets_table()}],
    SibylPocMgrOpts = [],
    {ok,
        {?FLAGS, [
            ?WORKER(sibyl_mgr, [SibylMgrOpts]),
            ?WORKER(sibyl_poc_mgr, SibylPocMgrOpts)
        ]}}.

%% internal functions
