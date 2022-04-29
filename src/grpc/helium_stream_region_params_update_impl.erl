-module(helium_stream_region_params_update_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").

-type handler_state() :: #{
    mod => atom()
}.
-export_type([handler_state/0]).

-export([
    init/2,
    handle_info/2,
    region_params_update/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_hbvr 'stream_region_params_update' callbacks
%% ------------------------------------------------------------------
-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    lager:debug("handler init, stream state ~p", [StreamState]),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #{streaming_initialized => false, mod => ?MODULE}
    ),
    NewStreamState.

-spec region_params_update(
    gateway_pb:gateway_region_params_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
region_params_update(#gateway_region_params_update_req_v1_pb{} = Msg, StreamState) ->
    Chain = sibyl_mgr:blockchain(),
    #{streaming_initialized := StreamingInitialized} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    region_params_update(Chain, StreamingInitialized, Msg, StreamState);
region_params_update(_Msg, StreamState) ->
    lager:warning("unhandled msg ~p", [_Msg]),
    {ok, StreamState}.

handle_info(
    {asserted_gw_notify, Addr},
    StreamState
) ->
    lager:debug("got asserted_gw_notify for addr ~p, sending region params", [Addr]),
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    NewStreamState = send_region_params(Addr, Ledger, StreamState),
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
-spec region_params_update(
    blockchain:blockchain(),
    boolean(),
    gateway_pb:gateway_region_params_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
region_params_update(
    undefined = _Chain,
    _StreamingInitialized,
    #gateway_region_params_update_req_v1_pb{} = _Msg,
    _StreamState
) ->
    %% if chain not up we have no way to retrieve data so just return a 14/503
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
region_params_update(
    _Chain,
    true = _StreamingInitialized,
    #gateway_region_params_update_req_v1_pb{} = _Msg,
    StreamState
) ->
    %% we are already streaming updates so do nothing further here
    {ok, StreamState};
region_params_update(
    _Chain,
    false = _StreamingInitialized,
    #gateway_region_params_update_req_v1_pb{address = Addr, signature = Sig} = Msg,
    StreamState
) ->
    lager:debug("executing RPC region_params_update with msg ~p", [Msg]),
    %% start a region params update stream
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    PubKey = libp2p_crypto:bin_to_pubkey(Addr),
    BaseReq = Msg#gateway_region_params_update_req_v1_pb{signature = <<>>},
    EncodedReq = gateway_pb:encode_msg(BaseReq),
    %% confirm the sig is valid
    case libp2p_crypto:verify(EncodedReq, Sig, PubKey) of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(14), <<"bad signature">>}};
        true ->
            %% topic key for region params streams is the pub key bin
            %% msgs will published by sibyl_mgr when an assert occurs
            Topic = sibyl_utils:make_asserted_gw_topic(Addr),
            lager:debug("subscribing to region params update events for gw ~p", [Addr]),
            ok = sibyl_bus:sub(Topic, self()),
            HandlerState = grpcbox_stream:stream_handler_state(StreamState),
            NewStreamState1 = grpcbox_stream:stream_handler_state(
                StreamState,
                HandlerState#{
                    streaming_initialized => true
                }
            ),
            %% when the stream is first initiated return the current region params
            NewStreamState2 = send_region_params(Addr, Ledger, NewStreamState1),
            {ok, NewStreamState2}
    end.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec region_params_for_addr(libp2p_crypto:pubkey_bin(), blockchain_ledger_v1:ledger()) ->
    {ok, #gateway_region_params_streamed_resp_v1_pb{}} | {error, any()}.
region_params_for_addr(Addr, Ledger) ->
    case blockchain_ledger_v1:find_gateway_info(Addr, Ledger) of
        {ok, GWInfo} ->
            Location = blockchain_ledger_gateway_v2:location(GWInfo),
            case blockchain_region_v1:h3_to_region(Location, Ledger) of
                {ok, Region} ->
                    case blockchain_region_params_v1:for_region(Region, Ledger) of
                        {error, Reason} ->
                            lager:error(
                                "Could not get params for region: ~p, reason: ~p",
                                [Region, Reason]
                            ),
                            {error, no_params_for_region};
                        {ok, Params} ->
                            Gain = blockchain_ledger_gateway_v2:gain(GWInfo),
                            {ok, #gateway_region_params_streamed_resp_v1_pb{
                                address = Addr,
                                gain = Gain,
                                region = normalize_region(Region),
                                params = #blockchain_region_params_v1_pb{
                                    region_params = Params
                                }
                            }}
                    end;
                {error, Reason} ->
                    lager:error(
                        "Could not get h3 region for location ~p, reason: ~p",
                        [Location, Reason]
                    ),
                    {error, region_not_found}
            end;
        {error, _Reason} ->
            {error, gateway_not_asserted}
    end.

-spec send_region_params(
    libp2p_crypto:pubkey_bin(), blockchain_ledger_v1:ledger(), grpcbox_stream:t()
) -> grpcbox_stream:t().
send_region_params(Addr, Ledger, StreamState) ->
    case region_params_for_addr(Addr, Ledger) of
        {ok, ParamsPB} ->
            Msg = sibyl_utils:encode_gateway_resp_v1(
                ParamsPB,
                sibyl_mgr:sigfun()
            ),
            grpcbox_stream:send(false, Msg, StreamState);
        {error, _Reason} ->
            %% if we fail to get region param data, then do nothing
            %% no msg is sent to the client, not even an error msg
            %% doesnt really make sense to stream an error at this point
            StreamState
    end.

%% blockchain_region_v1 returns region as an atom with a 'region_' prefix, ie
%% 'region_us915' etc, we need it without the prefix and capitalised to
%% be compatible with the proto
normalize_region(V) ->
    list_to_atom(string:to_upper(string:slice(atom_to_list(V), 7))).
