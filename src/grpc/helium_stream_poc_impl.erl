-module(helium_stream_poc_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain_utils.hrl").

-type handler_state() :: #{
    mod => atom(),
    streaming_initialized => boolean(),
    addr => libp2p_crypto:pubkey_bin()
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
        #{streaming_initialized => false, mod => ?MODULE}
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
            lager:info("gw ~p is subscribing to poc events", [?TO_ANIMAL_NAME(Addr)]),
            ok = subscribe_to_events(Addr),
            HandlerState = grpcbox_stream:stream_handler_state(StreamState),
            NewStreamState = grpcbox_stream:stream_handler_state(
                StreamState,
                HandlerState#{
                    streaming_initialized => true,
                    addr => Addr
                }
            ),
            _ = check_if_reactivated_gw(Addr, Chain),
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
    #{addr := GWAddr} = grpcbox_stream:stream_handler_state(StreamState),
    _ = check_if_reactivated_gw(GWAddr, Chain),
    StreamState;
handle_event(
    {event, _EventType, _Payload} = _Event,
    StreamState
) ->
    lager:warning("received unhandled event ~p", [_Event]),
    StreamState.

-spec check_if_reactivated_gw(libp2p_crypto:pubkey_bin(), blockchain:blockchain()) -> ok.
check_if_reactivated_gw(GWAddr, Chain) ->
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    case blockchain:config(poc_activity_filter_enabled, Ledger) of
        {ok, true} ->
            %% TODO: quicker to perform two denorm reads that one find_gateway_info?
            GWLocation = get_gateway_location(GWAddr, Ledger),
            GWLastChallenge = get_gateway_last_challenge(GWAddr, Ledger),
            case {GWLocation, GWLastChallenge} of
                {undefined, _} ->
                    %% if GW not asserted then do nothing further
                    ok;
                {error, _} ->
                    %% failed to get gw location
                    %% maybe gw is not on chain - do nothing
                    ok;
                {_, error} ->
                    %% failed to get gw last challenger
                    %% maybe gw is not on chain - do nothing
                    ok;
                {_Loc, undefined} ->
                    %% No activity set, add to reactivation list
                    lager:debug("reactivating gw ~p", [?TO_ANIMAL_NAME(GWAddr)]),
                    true = sibyl_poc_mgr:cache_reactivated_gw(GWAddr);
                {_Loc, LastActivity} when is_integer(LastActivity) ->
                    MaxActivityAge = blockchain_utils:max_activity_age(Ledger),
                    case blockchain_utils:is_gw_active(CurHeight, LastActivity, MaxActivityAge) of
                        false ->
                            lager:debug("reactivating gw ~p", [?TO_ANIMAL_NAME(GWAddr)]),
                            true = sibyl_poc_mgr:cache_reactivated_gw(GWAddr);
                        true ->
                            ok
                    end
            end;
        _ ->
            %% activity filter not set, do nothing
            ok
    end.

-spec subscribe_to_events(libp2p_crypto:pubkey_bin()) -> ok.
subscribe_to_events(Addr) ->
    %% topic key for POC streams is the pub key bin
    %% streamed msgs will be received & published by the sibyl_poc_mgr
    %% streamed POC msgs will be potential challenge notifications
    %% we also want to activity check events
    POCTopic = sibyl_utils:make_poc_topic(Addr),
    [sibyl_bus:sub(E, self()) || E <- [?EVENT_ACTIVITY_CHECK_NOTIFICATION, POCTopic]],
    ok.

-spec get_gateway_last_challenge(libp2p_crypto:pubkey_bin(), blockchain_ledger_v1:ledger()) ->
    error | undefined | pos_integer().
get_gateway_last_challenge(GWAddr, Ledger) ->
    case blockchain_ledger_v1:find_gateway_last_challenge(GWAddr, Ledger) of
        {error, _Reason} -> error;
        {ok, undefined} -> undefined;
        {ok, V} -> V
    end.

-spec get_gateway_location(libp2p_crypto:pubkey_bin(), blockchain_ledger_v1:ledger()) ->
    error | undefined | integer().
get_gateway_location(GWAddr, Ledger) ->
    case blockchain_ledger_v1:find_gateway_location(GWAddr, Ledger) of
        {error, _Reason} -> error;
        {ok, undefined} -> undefined;
        {ok, V} -> V
    end.
