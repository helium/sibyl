-module(route_updates_sup).

-behaviour(supervisor).

-export([
    init/1,
    start_link/0,
    start_route_stream_worker/1
]).

-define(WORKER(I), #{
    id => I,
    start => {I, start_link, []},
    restart => temporary,
    shutdown => 1000,
    type => worker,
    modules => [I]
}).

-define(FLAGS, #{
    strategy => simple_one_for_one,
    intensity => 3,
    period => 60
}).

start_route_stream_worker(Stream) ->
    supervisor:start_child(?MODULE, [Stream]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {?FLAGS, [?WORKER(route_updates_server)]}}.
