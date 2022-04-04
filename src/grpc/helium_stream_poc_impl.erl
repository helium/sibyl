-module(helium_stream_poc_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").

-type handler_state() :: #{
    mod => atom(),
    streaming_initialized => boolean()
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
    pocs(Chain, StreamingInitialized, Msg, StreamState).

-spec handle_info(sibyl_mgr:event() | any(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(
    {event, _EventTopic, _Payload} = Event,
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
            %% topic key for POC streams is the pub key bin
            %% streamed msgs will be received & published by the sibyl_poc_mgr
            %% streamed POC msgs will be potential challenge notifications
            Topic = sibyl_utils:make_poc_topic(Addr),
            lager:debug("subscribing to poc events for gw ~p", [Addr]),
            ok = sibyl_bus:sub(Topic, self()),
            HandlerState = grpcbox_stream:stream_handler_state(StreamState),
            NewStreamState = grpcbox_stream:stream_handler_state(
                StreamState,
                HandlerState#{
                    streaming_initialized => true
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
    {event, _EventType, _Payload} = _Event,
    StreamState
) ->
    lager:warning("received unhandled event ~p", [_Event]),
    StreamState.

-spec check_if_reactivated_gw(libp2p_crypto:pubkey_bin(), blockchain:blockchain()) -> ok.
check_if_reactivated_gw(GWAddr, Chain) ->
    Ledger = blockchain:ledger(Chain),
    CurHeight = blockchain_ledger_v1:current_height(Ledger),
    case blockchain:config(poc_activity_filter_enabled, Ledger) of
        {ok, true} ->
            case blockchain_ledger_v1:find_gateway_last_challenge(GWAddr, Ledger) of
                {ok, undefined} ->
                    %% No activity set, so include in list to reactivate
                    %% this means it will become available for POC
                    true = sibyl_poc_mgr:cache_reactivated_gw(GWAddr);
                {ok, C} ->
                    {ok, MaxActivityAge} = blockchain:config(poc_v4_target_challenge_age, Ledger),
                    case (CurHeight - C) > MaxActivityAge of
                        true -> true = sibyl_poc_mgr:cache_reactivated_gw(GWAddr);
                        false -> ok
                    end
            end;
        _ ->
            %% activity filter not set, do nothing
            ok
    end.
