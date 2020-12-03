-module(route_updates_server).

-behaviour(gen_server).

-include("../../include/sibyl.hrl").

-record(state, {
    stream :: any()
}).

-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% gen_server exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

%% ------------------------------------------------------------------
%% API exports
%% ------------------------------------------------------------------
-export([
    start_link/1
]).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------
-spec start_link(any()) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link(Stream) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Stream], []).

%% ------------------------------------------------------------------
%% gen_server functions
%% ------------------------------------------------------------------
init([Stream] = _Args) ->
    lager:info("init with args ~p", [_Args]),
    erlbus:sub(self(), ?EVENT_ROUTING_UPDATE),
    {ok, #state{stream = Stream}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {event, EventTopic, Updates} = _Msg,
    State
) when EventTopic =:= ?EVENT_ROUTING_UPDATE ->
    NewStream = handle_routing_updates(State, EventTopic, Updates),
    {noreply, State#state{stream = NewStream}};
handle_info(
    _Msg,
    State = #state{}
) ->
    lager:debug("unhandled info msg: ~p", [_Msg]),
    {ok, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------

handle_routing_updates(
    #state{
        stream = Stream
    },
    Topic,
    Updates
) ->
    Ledger = blockchain:ledger(sibyl_mgr:blockchain()),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    true = sibyl_mgr:update_last_modified(Topic, Height),
    %% get the sigfun which will be used to sign event payloads sent to the client
    SigFun = sibyl_mgr:sigfun(),
    lists:foldl(
        fun(Update, AccStream) ->
            {_Ref, Action, _Something, RoutePB} = Update,
            Route = blockchain_ledger_routing_v1:deserialize(RoutePB),

            RouteUpdatePB = serialize_response(Action, Route, Height, SigFun),
            lager:debug("sending event:  ~p", [
                RouteUpdatePB
            ]),
            grpc:send(AccStream, RouteUpdatePB)
        end,
        Stream,
        Updates
    ).

-spec serialize_response(
    atom(),
    blockchain_ledger_routing_v1:routing(),
    non_neg_integer(),
    function()
) -> routes_v1_server:routing_v1_response().
serialize_response(Action, Route, Height, SigFun) ->
    RouteUpdatePB = to_routing_pb(Route),
    Resp = #{
        route => RouteUpdatePB,
        height => Height,
        action => sibyl_utils:ensure(binary, Action)
    },
    EncodedRoutingInfoBin = routes_v1:encode_msg(Resp, routing_v1_update),
    Resp#{signature => SigFun(EncodedRoutingInfoBin)}.

-spec to_routing_pb(blockchain_ledger_routing_v1:routing()) -> routes_v1_server:routing_v1().
to_routing_pb(Route) ->
    #{
        oui => blockchain_ledger_routing_v1:oui(Route),
        owner => blockchain_ledger_routing_v1:owner(Route),
        router_addresses => blockchain_ledger_routing_v1:addresses(Route),
        filters => blockchain_ledger_routing_v1:filters(Route),
        subnets => blockchain_ledger_routing_v1:subnets(Route)
    }.
