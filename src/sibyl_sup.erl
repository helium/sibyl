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
    strategy => rest_for_one,
    intensity => 1,
    period => 5
}).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    {ok, _} = application:ensure_all_started(lager),
    %% set route and client ref header config for chatterbox
    %% if a new http2 handler is added, be sure to add its route/path and
    %% associated module to the fun below
    RouterHttp2HandlerRoutingFun = fun
        (<<"/v1/routes">>) -> {ok, http2_handler_routes_v1};
        (<<"/v1/events/route_updates", _Topic/binary>>) -> {ok, http2_handler_sse_route_updates_v1};
        (UnknownRequestType) -> {error, {handler_not_found, UnknownRequestType}}
    end,
    ok = application:set_env(
        chatterbox,
        stream_callback_opts,
        [
            {http2_handler_routing_fun, RouterHttp2HandlerRoutingFun},
            {http2_client_ref_header_name, <<"x-gateway-id">>}
        ]
    ),
    {ok,
        {?FLAGS, [
            ?SUP(chatterbox_sup, []),
            ?WORKER(sibyl_mgr, [])
        ]}}.

%% internal functions
