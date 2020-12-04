-module(route_updates_server).

-behaviour(gen_server).

-include("../../include/sibyl.hrl").

-record(state, {
    stream :: grpc:stream()
}).

-type state() :: #state{}.

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
    NewStream = maybe_send_inital_all_routes_msg(Stream),
    {ok, #state{stream = NewStream}}.

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
    NewStream = handle_routing_updates(Updates, State),
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
-spec maybe_send_inital_all_routes_msg(grpc:stream()) -> grpc:stream().
maybe_send_inital_all_routes_msg(Stream) ->
    %% if the client presented the x-last-height header then we will only return
    %% the initial route data if it was modified since that height
    %% if header not presented default last height to 1 and thus always return route data
    Headers = grpc:metadata(Stream),
    ClientLastRequestHeight = sibyl_utils:ensure(
        integer_or_default,
        maps:get(?CLIENT_HEIGHT_HEADER, Headers, 1),
        1
    ),
    LastModifiedHeight = sibyl_mgr:get_last_modified(?EVENT_ROUTING_UPDATE),
    case is_data_modified(ClientLastRequestHeight, LastModifiedHeight) of
        false ->
            Stream;
        true ->
            %% get the route data
            Chain = sibyl_mgr:blockchain(),
            Ledger = blockchain:ledger(Chain),
            {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
            case blockchain_ledger_v1:get_routes(Ledger) of
                {ok, Routes} ->
                    RoutesPB = encode_response(
                        all,
                        Routes,
                        CurHeight,
                        sibyl_mgr:sigfun()
                    ),
                    NewStream = grpc:send(Stream, RoutesPB),
                    NewStream;
                {error, _Reason} ->
                    Stream
            end
    end.

-spec handle_routing_updates({reference(), atom(), binary()}, state()) -> grpc:stream().
handle_routing_updates(
    Updates,
    #state{
        stream = Stream
    }
) ->
    Ledger = blockchain:ledger(sibyl_mgr:blockchain()),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    %% get the sigfun which will be used to sign event payloads sent to the client
    SigFun = sibyl_mgr:sigfun(),
    lists:foldl(
        fun(Update, AccStream) ->
            {_Ref, Action, _Something, RoutePB} = Update,
            Route = blockchain_ledger_routing_v1:deserialize(RoutePB),
            RouteUpdatePB = encode_response(Action, [Route], Height, SigFun),
            lager:debug("sending event:  ~p", [
                RouteUpdatePB
            ]),
            grpc:send(AccStream, RouteUpdatePB)
        end,
        Stream,
        Updates
    ).

-spec encode_response(
    atom(),
    blockchain_ledger_routing_v1:routing(),
    non_neg_integer(),
    function()
) -> routes_v1_server:routing_v1_response().
encode_response(Action, Routes, Height, SigFun) ->
    RouteUpdatePB = [to_routing_pb(R) || R <- Routes],
    Resp = #{
        routes => RouteUpdatePB,
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

-spec is_data_modified(non_neg_integer(), non_neg_integer()) -> boolean().
is_data_modified(ClientLastHeight, LastModifiedHeight) when
    is_integer(ClientLastHeight); is_integer(LastModifiedHeight)
->
    ClientLastHeight < LastModifiedHeight;
is_data_modified(_ClientLastHeight, _LastModifiedHeight) ->
    true.
