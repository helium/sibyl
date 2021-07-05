-module(helium_routing_impl).

-include("../../include/sibyl.hrl").
-include("autogen/server/gateway_pb.hrl").

-record(handler_state, {
    initialized = false :: boolean()
}).

-export([
    handle_info/2,
    routing/2
]).

-spec routing(gateway_pb:gateway_routing_req_v1_pb(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
routing(#gateway_routing_req_v1_pb{height = ClientHeight} = Msg, StreamState) ->
    lager:debug("RPC routing called with height ~p", [ClientHeight]),
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    StreamState0 = maybe_init_stream_state(HandlerState, StreamState),
    #handler_state{initialized = Initialized} = grpcbox_stream:stream_handler_state(StreamState0),
    routing(Initialized, sibyl_mgr:blockchain(), Msg, StreamState0).

-spec routing(
    boolean(),
    blockchain:blockchain(),
    gateway_pb:gateway_routing_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
routing(_Initialized, undefined = _Chain, #gateway_routing_req_v1_pb{} = _Msg, _StreamState) ->
    % if chain not up we have no way to return routing data so just return a 14/503
    lager:debug("chain not ready, returning error response"),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
routing(
    false = _Initialized,
    _Chain,
    #gateway_routing_req_v1_pb{height = ClientHeight} = _Msg,
    StreamState
) ->
    %% not previously initialized, this must be the first msg from the client
    %% we will have some setup to do including subscribing to our required events
    lager:debug("handling first msg from client ~p", [_Msg]),
    ok = sibyl_bus:sub(?EVENT_ROUTING_UPDATES_END, self()),
    NewStreamState = maybe_send_inital_all_routes_msg(ClientHeight, StreamState),
    NewStreamState0 = grpcbox_stream:stream_handler_state(
        NewStreamState,
        #handler_state{
            initialized = true
        }
    ),
    {ok, NewStreamState0};
routing(true = _Initialized, _Chain, #gateway_routing_req_v1_pb{} = _Msg, StreamState) ->
    %% we previously initialized, this must be a subsequent incoming msg from the client - ignore
    lager:debug("ignoring subsequent msg from client ~p", [_Msg]),
    {ok, StreamState}.

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
    {event, ?EVENT_ROUTING_UPDATES_END, ChangedKeys} = _Event,
    StreamState
) ->
    lager:debug("handling routing updates end event. Changed keys:  ~p", [
        ChangedKeys
    ]),
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    %% get the routing for each changed key & send to clients
    %% clients will only receive a single routing update per block epoch
    %% the update will contain 1 or more modified routes
    Routes =
        lists:foldl(
            fun
                ({put, <<OUI:32/integer-unsigned-big>>}, Acc) ->
                    case blockchain_ledger_v1:find_routing(OUI, Ledger) of
                        {ok, Routing} -> [Routing | Acc];
                        _ -> Acc
                    end;
                (_, Acc) ->
                    %% ignoring deletes as routing cannot be deleted
                    Acc
            end,
            [],
            ChangedKeys
        ),

    Msg0 = #gateway_routing_streamed_resp_v1_pb{
        routings = [sibyl_utils:to_routing_pb(R) || R <- Routes]
    },
    Msg1 = sibyl_utils:encode_gateway_resp_v1(
        Msg0,
        CurHeight,
        sibyl_mgr:sigfun()
    ),
    NewStream = grpcbox_stream:send(false, Msg1, StreamState),
    NewStream;
handle_event(
    {event, _EventType, _Payload} = _Event,
    StreamState
) ->
    lager:warning("received unhandled event ~p", [_Event]),
    StreamState.

-spec maybe_send_inital_all_routes_msg(non_neg_integer(), grpcbox_stream:t()) -> grpc:stream().
maybe_send_inital_all_routes_msg(ClientHeight, StreamState) ->
    %% get the height field from the request msg and only return
    %% the initial full set of routes if they were modified since that height
    LastModifiedHeight = sibyl_mgr:get_last_modified(?EVENT_ROUTING_UPDATES_END),
    case is_data_modified(ClientHeight, LastModifiedHeight) of
        false ->
            lager:debug(
                "not sending initial routes msg, data last modified ~p, client height ~p",
                [LastModifiedHeight, ClientHeight]
            ),
            StreamState;
        true ->
            lager:debug(
                "sending initial routes msg, data last modified ~p, client height ~p",
                [LastModifiedHeight, ClientHeight]
            ),
            %% get the route data
            Chain = sibyl_mgr:blockchain(),
            Ledger = blockchain:ledger(Chain),
            {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
            case blockchain_ledger_v1:get_routes(Ledger) of
                {ok, Routes} ->
                    Msg0 = #gateway_routing_streamed_resp_v1_pb{
                        routings = [sibyl_utils:to_routing_pb(R) || R <- Routes]
                    },
                    Msg1 = sibyl_utils:encode_gateway_resp_v1(
                        Msg0,
                        CurHeight,
                        sibyl_mgr:sigfun()
                    ),
                    NewStream = grpcbox_stream:send(false, Msg1, StreamState),
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

-spec maybe_init_stream_state(undefined | #handler_state{}, grpcbox_stream:t()) ->
    grpcbox_stream:t().
maybe_init_stream_state(undefined, StreamState) ->
    lager:debug("handler init, stream state ~p", [StreamState]),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #handler_state{
            initialized = false
        }
    ),
    NewStreamState;
maybe_init_stream_state(_HandlerState, StreamState) ->
    StreamState.
