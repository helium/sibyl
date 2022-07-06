-module(helium_stream_poc_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain_utils.hrl").

-type handler_state() :: #{
    mod => atom(),
    streaming_initialized => boolean(),
    addr => libp2p_crypto:pubkey_bin(),
    location => undefined | pos_integer()
}.
-export_type([handler_state/0]).

-export([
    init/2,
    handle_info/2
]).

-export([
    pocs/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_poc_bhvr callbacks
%% ------------------------------------------------------------------
-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    lager:debug("handler init, stream state ~p", [StreamState]),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #{streaming_initialized => false, mod => ?MODULE, location => undefined}
    ),
    NewStreamState.

-spec pocs(
    gateway_pb:gateway_poc_req_v1(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
pocs(#gateway_poc_req_v1_pb{} = Msg, StreamState) ->
    Chain = sibyl_mgr:blockchain(),
    #{streaming_initialized := StreamingInitialized} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    pocs(Chain, StreamingInitialized, Msg, StreamState);
pocs(_Msg, StreamState) ->
    lager:warning("unhandled msg ~p", [_Msg]),
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
    {event, _EventTopic} = Event,
    StreamState
) ->
    lager:debug("received event ~p", [Event]),
    NewStreamState = handle_event(Event, StreamState),
    NewStreamState;
handle_info(
    {poc_notify, Msg},
    StreamState
) ->
    lager:debug("received poc msg, sending to client ~p", [Msg]),
    %% received a poc notification event, we simply have to forward this unmodified to the client
    %% the payload is fully formed and encoded
    NewStreamState = grpcbox_stream:send(false, Msg, StreamState),
    NewStreamState;
handle_info(
    {asserted_gw_notify, Addr},
    StreamState
) ->
    lager:debug("got asserted_gw_notify for addr ~p, resubscribing to new hex", [Addr]),
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    #{location := OldLoc} =
        HandlerState =
        grpcbox_stream:stream_handler_state(StreamState),
    NewHandlerState =
        case blockchain_ledger_v1:find_gateway_location(Addr, Ledger) of
            {ok, NewLoc} when OldLoc == undefined ->
                %% first time assert for GW
                %% need to sub all our things
                ok = subscribe_to_events(NewLoc, Addr, Ledger),
                %% save new location to state
                HandlerState#{location => NewLoc};
            {ok, NewLoc} when NewLoc /= OldLoc ->
                %% gw has reasserted to new location
                %% unsub from old location, sub to new
                _ = sibyl_bus:leave(location_topic(OldLoc, Ledger), self()),
                _ = sibyl_bus:sub(location_topic(NewLoc, Ledger), self()),
                %% save new location to state
                HandlerState#{location => NewLoc};
            _ ->
                %% hmm
                HandlerState
        end,
    NewStreamState =
        grpcbox_stream:stream_handler_state(
            StreamState, NewHandlerState
        ),
    NewStreamState;
handle_info(
    _Msg,
    StreamState
) ->
    lager:warning("unhandled info msg: ~p", [_Msg]),
    StreamState.

%% ------------------------------------------------------------------
%% callback breakout functions
%% ------------------------------------------------------------------
-spec pocs(
    blockchain:blockchain(),
    boolean(),
    gateway_pb:gateway_poc_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
pocs(
    undefined = _Chain,
    _StreamingInitialized,
    #gateway_poc_req_v1_pb{} = _Msg,
    _StreamState
) ->
    %% if chain not up we have no way to retrieve data so just return a 14/503
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
pocs(
    _Chain,
    true = _StreamingInitialized,
    #gateway_poc_req_v1_pb{} = _Msg,
    StreamState
) ->
    %% we are already streaming POCs so do nothing further here
    {ok, StreamState};
pocs(
    Chain,
    false = _StreamingInitialized,
    #gateway_poc_req_v1_pb{address = Addr, signature = Sig} = Msg,
    StreamState
) ->
    lager:debug("executing RPC pocs with msg ~p", [Msg]),
    %% start a POC stream
    %% confirm the sig is valid
    PubKey = libp2p_crypto:bin_to_pubkey(Addr),
    BaseReq = Msg#gateway_poc_req_v1_pb{signature = <<>>},
    EncodedReq = gateway_pb:encode_msg(BaseReq),
    case libp2p_crypto:verify(EncodedReq, Sig, PubKey) of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(14), <<"bad signature">>}};
        true ->
            Ledger = blockchain:ledger(Chain),
            HandlerState = grpcbox_stream:stream_handler_state(StreamState),
            NewHandlerState =
                case blockchain_ledger_v1:find_gateway_location(Addr, Ledger) of
                    {ok, Loc} when Loc /= undefined ->
                        lager:info("gw ~p is subscribing to poc events", [?TO_ANIMAL_NAME(Addr)]),
                        %% GW is asserted, we are good to proceed
                        ok = subscribe_to_events(Loc, Addr, Ledger),
                        ok = check_if_reactivated_gw(Addr, Ledger),
                        HandlerState#{location => Loc};
                    _ ->
                        lager:info("unasserted gw ~p is subscribing to poc events", [
                            ?TO_ANIMAL_NAME(Addr)
                        ]),
                        HandlerState
                end,
            NewStreamState = grpcbox_stream:stream_handler_state(
                StreamState,
                NewHandlerState#{
                    streaming_initialized => true,
                    addr => Addr
                }
            ),
            {ok, NewStreamState}
    end.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec handle_event(sibyl_mgr:event(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_event(
    {event, ?EVENT_ACTIVITY_CHECK_NOTIFICATION} = _Event,
    StreamState
) ->
    %% check if the connected GW has gone inactive
    %% this can happen if the GW connects to the poc stream
    %% & stays connected for a long period but fails
    %% to get selected for a POC or fails to witness
    %% a POC ( or maybe get their witnesses reports
    %% filtered out )
    %% To counter this we run a periodic check on
    %% each GW to see if they have fallen inactive
    %% if so reactivate them
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    #{addr := GWAddr} = grpcbox_stream:stream_handler_state(StreamState),
    _ = check_if_reactivated_gw(GWAddr, Ledger),
    StreamState;
handle_event(
    {event, _EventType, _Payload} = _Event,
    StreamState
) ->
    lager:warning("received unhandled event ~p", [_Event]),
    StreamState.

-spec check_if_reactivated_gw(
    libp2p_crypto:pubkey_bin(),
    blockchain_ledger_v1:ledger()
) -> ok.
check_if_reactivated_gw(GWAddr, Ledger) ->
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    DenyListFn = application:get_env(sibyl, denylist_fn, fun(_) -> false end),
    case DenyListFn(GWAddr) of
        true ->
            lager:info("connection from denylist hotspot ~p", [?TO_ANIMAL_NAME(GWAddr)]),
            ok;
        false ->
            case blockchain:config(poc_activity_filter_enabled, Ledger) of
                {ok, true} ->
                    case blockchain_ledger_v1:find_gateway_last_challenge(GWAddr, Ledger) of
                        {error, _Reason} ->
                            %% if GW not found or some other issue, ignore
                            ok;
                        {ok, undefined} ->
                            %% No activity set, so include in list to reactivate
                            %% this means it will become available for POC
                            true = sibyl_poc_mgr:cache_reactivated_gw(GWAddr),
                            ok;
                        {ok, C} ->
                            {ok, MaxActivityAge} =
                                case
                                    blockchain:config(
                                        ?harmonize_activity_on_hip17_interactivity_blocks, Ledger
                                    )
                                of
                                    {ok, true} ->
                                        blockchain:config(?hip17_interactivity_blocks, Ledger);
                                    _ ->
                                        blockchain:config(?poc_v4_target_challenge_age, Ledger)
                                end,
                            case (CurHeight - C) > MaxActivityAge of
                                true ->
                                    lager:debug("reactivating gw ~p", [?TO_ANIMAL_NAME(GWAddr)]),
                                    true = sibyl_poc_mgr:cache_reactivated_gw(GWAddr),
                                    ok;
                                false ->
                                    ok
                            end
                    end;
                _ ->
                    %% activity filter not set, do nothing
                    ok
            end
    end.

-spec subscribe_to_events(
    Loc :: pos_integer(),
    Addr :: libp2p_crypto:pubkey_bin(),
    Ledger :: blockchain_ledger_v1:ledger()
) -> ok.
subscribe_to_events(Loc, Addr, Ledger) ->
    %% topic key for POC streams is the hex of their asserted location
    %% streamed POC notification is published by sibyl_poc_mgr
    _ = sibyl_bus:sub(location_topic(Loc, Ledger), self()),
    %% subscribe activity check events
    _ = sibyl_bus:sub(?EVENT_ACTIVITY_CHECK_NOTIFICATION, self()),
    %% subscribe to reassert notifications
    ReassertTopic = sibyl_utils:make_asserted_gw_topic(Addr),
    _ = sibyl_bus:sub(ReassertTopic, self()),
    ok.

-spec location_topic(
    Loc :: pos_integer(),
    Ledger :: blockchain_ledger_v1:ledger()
) -> binary().
location_topic(Loc, Ledger) ->
    {ok, Res} = blockchain:config(?poc_target_hex_parent_res, Ledger),
    Hex = h3:parent(Loc, Res),
    sibyl_utils:make_poc_topic(Hex).
