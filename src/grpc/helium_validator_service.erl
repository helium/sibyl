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

-spec init(grpcbox_stream:t()) -> grpcbox_stream:t().
init(StreamState) ->
    lager:debug("handler init, stream state ~p", [StreamState]),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #handler_state{
            initialized = false
        }
    ),
    NewStreamState.

-spec routing(validator_pb:routing_request_pb(), grpcbox_stream:t()) ->
    {continue, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
routing(#routing_request_pb{height = ClientHeight} = Msg, StreamState) ->
    lager:debug("RPC routing called with height ~p", [ClientHeight]),
    #handler_state{initialized = Initialized} = grpcbox_stream:stream_handler_state(StreamState),
    routing(Initialized, sibyl_mgr:blockchain(), Msg, StreamState).

-spec routing(
    boolean(),
    blockchain:blockchain(),
    validator_pb:routing_request_pb(),
    grpcbox_stream:t()
) -> {continue, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
routing(_Initialized, undefined = _Chain, #routing_request_pb{} = _Msg, _StreamState) ->
    % if chain not up we have no way to return routing data so just return a 14/503
    lager:debug("chain not ready, returning error response"),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavavailable">>}};
routing(
    false = _Initialized,
    _Chain,
    #routing_request_pb{height = ClientHeight} = _Msg,
    StreamState
) ->
    %% not previously initialized, this must be the first msg from the client
    %% we will have some setup to do including subscribing to our required events
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

-spec handle_info(sibyl_mgr:event() | any(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(
    {event, _EventTopic, _Payload} = Event,
    StreamState
) ->
    lager:debug("received event ~p", [Event]),
    NewStreamState = handle_event(Event, StreamState),
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

-spec handle_event(sibyl_mgr:event(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_event(
    {event, ?EVENT_ROUTING_UPDATE, EncodedRoutesPB} = _Event,
    StreamState
) ->
    lager:debug("sending event to client:  ~p", [
        EncodedRoutesPB
    ]),
    NewStreamState = grpcbox_stream:send(false, EncodedRoutesPB, StreamState),
    NewStreamState;
handle_event(
    {event, _EventType, _Payload} = _Event,
    StreamState
) ->
    lager:warning("received unhandled event ~p", [_Event]),
    StreamState.

-spec maybe_send_inital_all_routes_msg(validator_pb:routing_request(), grpcbox_stream:t()) ->
    grpc:stream().
maybe_send_inital_all_routes_msg(ClientHeight, StreamState) ->
    %% get the height field from the request msg and only return
    %% the initial full set of routes if they were modified since that height
    LastModifiedHeight = sibyl_mgr:get_last_modified(?EVENT_ROUTING_UPDATE),
    case is_data_modified(ClientHeight, LastModifiedHeight) of
        false ->
            lager:debug(
                "not sending initial routes msg, data not modified since client height ~p",
                [ClientHeight]
            ),
            StreamState;
        true ->
            lager:debug(
                "sending initial routes msg, data has been modified since client height ~p",
                [ClientHeight]
            ),
            %% get the route data
            Chain = sibyl_mgr:blockchain(),
            Ledger = blockchain:ledger(Chain),
            {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
            case blockchain_ledger_v1:get_routes(Ledger) of
                {ok, Routes} ->
                    RoutesPB = sibyl_utils:encode_routing_update_response(
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

-spec is_data_modified(non_neg_integer(), non_neg_integer()) -> boolean().
is_data_modified(ClientLastHeight, LastModifiedHeight) when
    is_integer(ClientLastHeight); is_integer(LastModifiedHeight)
->
    ClientLastHeight < LastModifiedHeight;
is_data_modified(_ClientLastHeight, _LastModifiedHeight) ->
    true.
