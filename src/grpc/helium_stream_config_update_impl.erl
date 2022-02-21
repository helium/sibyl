-module(helium_stream_config_update_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").

-type handler_state() :: #{
    mod => atom()
}.
-export_type([handler_state/0]).

-export([
    init/2,
    handle_info/2,
    config_update/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_hbvr 'stream_config_update' callbacks
%% ------------------------------------------------------------------
-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    lager:info("handler init, stream state ~p", [StreamState]),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #{streaming_initialized => false, mod => ?MODULE}
    ),
    NewStreamState.

-spec config_update(
    gateway_pb:gateway_config_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
config_update(#gateway_config_update_req_v1_pb{} = Msg, StreamState) ->
    Chain = sibyl_mgr:blockchain(),
    #{streaming_initialized := StreamingInitialized} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    config_update(Chain, StreamingInitialized, Msg, StreamState).

handle_info(
    {config_update_notify, Msg},
    StreamState
) ->
    lager:info("received config_update_notify msg, sending to client ~p", [Msg]),
    %% received a config update notification event, we simply have to forward this unmodified to the client
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

-spec config_update(
    blockchain:blockchain(),
    boolean(),
    gateway_pb:gateway_config_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
config_update(
    undefined = _Chain,
    _IsAlreadyStreamingPOCs,
    #gateway_config_update_req_v1_pb{} = _Msg,
    _StreamState
) ->
    %% if chain not up we have no way to retrieve data so just return a 14/503
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
config_update(
    _Chain,
    true = _StreamingInitialized,
    #gateway_config_update_req_v1_pb{} = _Msg,
    StreamState
) ->
    %% we are already streaming POCs so do nothing further here
    {ok, StreamState};
config_update(
    _Chain,
    false = _StreamingInitialized,
    #gateway_config_update_req_v1_pb{} = Msg,
    StreamState
) ->
    lager:info("executing RPC config_update with msg ~p", [Msg]),
    %% start a config updates stream
    %% generate a topic key for config updates
    %% this key is global, ie not client specific
    %% any process subscribed to it will receive chain var updates
    Topic = sibyl_utils:make_config_update_topic(),
    ok = sibyl_bus:sub(Topic, self()),
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        HandlerState#{
            streaming_initialized => true
        }
    ),
    lager:info("*** config update complete", []),
    {ok, NewStreamState}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
