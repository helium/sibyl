%%%-------------------------------------------------------------------
%% @doc sibyl top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(sibyl_sup).

-behaviour(supervisor).

-export([start_link/0, start_link/1]).

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
    supervisor:start_link({local, ?SERVER}, ?MODULE, [grpc]).

start_link(POCTransportType) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, [POCTransportType]).

init([POCTransportType]) ->
    %% create the sibyl_mgr ets table under this supervisor and set ourselves as the heir
    %% we call `ets:give_away' every time we start_link sibyl_mgr
    _ = sibyl_bus:start(),
    SibylMgrOpts = [{ets, sibyl_mgr:make_ets_table()}],

    POCServers =
        case POCTransportType of
            grpc ->
                SibylPocMgrOpts = [],
                [?WORKER(sibyl_poc_mgr, SibylPocMgrOpts)];
            _ ->
                []
        end,
    {ok,
        {?FLAGS,
            [
                ?WORKER(sibyl_mgr, [SibylMgrOpts])
            ] ++ POCServers}}.

%% internal functions
