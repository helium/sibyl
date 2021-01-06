-module(helium_validator_service).

-behavior(helium_validator_bhvr).

-include("../../include/sibyl.hrl").
-include("autogen/server/validator_pb.hrl").

-record(handler_state, {
    initialized = false :: boolean()
}).

-export([
    init/1,
    handle_info/2,
    routing/2
]).

init(StreamState) ->
    lager:debug("handler init, stream state ~p", [StreamState]),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #handler_state{
            initialized = false
        }
    ),
    NewStreamState.

routing(#routing_request_pb{height = ClientHeight} = Msg, StreamState) ->
    lager:debug("RPC routing called with height ~p", [ClientHeight]),
    #handler_state{initialized = Initialized} = grpcbox_stream:stream_handler_state(StreamState),
    routing(Initialized, sibyl_mgr:blockchain(), Msg, StreamState).
routing(_Initialized, undefined = _Chain, #routing_request_pb{} = _Msg, _StreamState) ->
    % if chain not up we have no way to return routing data so just return a 14/503
    lager:debug("chain not ready, returning error response"),
    {grpc_error,
        {grpcbox_stream:code_to_status(14), <<"temporarily unavavailable">>}};
routing(false = _Initialized, _Chain, #routing_request_pb{height = ClientHeight} = _Msg, StreamState) ->
    %% not previously initialized, this must be the first msg from the client
    %% we will have some setup to do
    lager:debug("handling first msg from client ~p", [_Msg]),
    ok = erlbus:sub(self(), ?EVENT_ROUTING_UPDATE),
    NewStreamState = maybe_send_inital_all_routes_msg(ClientHeight, StreamState),
    NewStreamState0 = grpcbox_stream:stream_handler_state(
        NewStreamState,
        #handler_state{
            initialized = true
        }
    ),
    {continue, NewStreamState0};
routing(true = _Initialized, _Chain, #routing_request_pb{} = _Msg, StreamState) ->
    %% we previously initialized, this must be a subsequent incoming msg from the client
    %% ignore these and return continue directive
    lager:debug("ignoring subsequent msg from client ~p", [_Msg]),
    {continue, StreamState}.

handle_info(
    {event, EventTopic, Updates} = _Msg,
    StreamState
) when EventTopic =:= ?EVENT_ROUTING_UPDATE ->
    lager:debug("received event ~p", [_Msg]),
    NewStreamState = handle_routing_updates(Updates, StreamState),
    NewStreamState;
handle_info(
    _Msg,
    StreamState
) ->
    lager:debug("unhandled info msg: ~p", [_Msg]),
    StreamState.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec maybe_send_inital_all_routes_msg(validator_pb:routing_request(), grpc:stream()) ->
    grpc:stream().
maybe_send_inital_all_routes_msg(ClientHeight, StreamState) ->
    %% get the height field from the request msg and only return
    %% the initial full set of routes if they were modified since that height
    LastModifiedHeight = sibyl_mgr:get_last_modified(?EVENT_ROUTING_UPDATE),
    case is_data_modified(ClientHeight, LastModifiedHeight) of
        false ->
            lager:debug("not sending initial routes msg, data not modified since client height ~p", [ClientHeight]),
            StreamState;
        true ->
            lager:debug("sending initial routes msg, data has been modified since client height ~p", [ClientHeight]),
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
                    NewStream = grpcbox_stream:send(false, RoutesPB, StreamState),
                    NewStream;
                {error, _Reason} ->
                    StreamState
            end
    end.

-spec handle_routing_updates({reference(), atom(), binary()}, grpc:stream()) -> grpc:stream().
handle_routing_updates(
    Updates,
    StreamState
) ->
    Ledger = blockchain:ledger(sibyl_mgr:blockchain()),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    %% get the sigfun which will be used to sign event payloads sent to the client
    SigFun = sibyl_mgr:sigfun(),
    NewStreamState =
        lists:foldl(
        fun(Update, AccStream) ->
            {_Ref, Action, _Something, RoutePB} = Update,
            Route = blockchain_ledger_routing_v1:deserialize(RoutePB),
            RouteUpdatePB = encode_response(Action, [Route], Height, SigFun),
            lager:debug("sending event to client:  ~p", [
                RouteUpdatePB
            ]),
            grpcbox_stream:send(false, RouteUpdatePB, AccStream)
        end,
        StreamState,
        Updates
    ),
    NewStreamState.

-spec encode_response(
    atom(),
    blockchain_ledger_routing_v1:routing(),
    non_neg_integer(),
    function()
) -> validator_pb:routing_response_pb().
encode_response(_Action, Routes, Height, SigFun) ->
    RouteUpdatePB = [to_routing_pb(R) || R <- Routes],
    Resp = #routing_response_pb{
        routings = RouteUpdatePB,
        height = Height
    },
    EncodedRoutingInfoBin = validator_pb:encode_msg(Resp, routing_response_pb),
    Resp#routing_response_pb{signature = SigFun(EncodedRoutingInfoBin)}.

-spec to_routing_pb(blockchain_ledger_routing_v1:routing()) -> validator_pb:routing_pb().
to_routing_pb(Route) ->
    #routing_pb{
        oui = blockchain_ledger_routing_v1:oui(Route),
        owner = blockchain_ledger_routing_v1:owner(Route),
        addresses = blockchain_ledger_routing_v1:addresses(Route),
        filters = blockchain_ledger_routing_v1:filters(Route),
        subnets = blockchain_ledger_routing_v1:subnets(Route)
    }.

-spec is_data_modified(non_neg_integer(), non_neg_integer()) -> boolean().
is_data_modified(ClientLastHeight, LastModifiedHeight) when
    is_integer(ClientLastHeight); is_integer(LastModifiedHeight)
->
    ClientLastHeight < LastModifiedHeight;
is_data_modified(_ClientLastHeight, _LastModifiedHeight) ->
    true.
