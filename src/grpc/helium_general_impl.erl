-module(helium_general_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").

-ifdef(TEST).
-define(MAX_KEY_SIZE, 5).
-else.
-define(MAX_KEY_SIZE, 50).
-endif.

-ifdef(TEST).
-define(VALIDATOR_LIMIT, 5).
-else.
-define(VALIDATOR_LIMIT, 50).
-endif.

-type handler_state() :: #{
    mod => atom()
}.
-export_type([handler_state/0]).

-export([
    init/2,
    handle_info/2
]).

-export([
    address_to_public_uri/2,
    config/2,
    validators/2,
    config_update/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_hbvr 'general' callbacks
%% ------------------------------------------------------------------
-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    lager:info("handler init, stream state ~p", [StreamState]),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #{config_streaming_initialized => false, mod => ?MODULE}
    ),
    NewStreamState.

-spec address_to_public_uri(
    ctx:ctx(),
    gateway_pb:gateway_address_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
address_to_public_uri(Ctx, #gateway_address_routing_data_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    address_to_public_uri(Chain, Ctx, Message).

-spec config(
    ctx:ctx(),
    gateway_pb:gateway_config_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
config(Ctx, #gateway_config_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    config(Chain, Ctx, Message).

-spec config_update(
    gateway_pb:gateway_config_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
config_update(#gateway_config_update_req_v1_pb{} = Msg, StreamState) ->
    Chain = sibyl_mgr:blockchain(),
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    StreamState0 = maybe_init_stream_state(pocs, HandlerState, StreamState),
    #{config_streaming_initialized := IsAlreadyStreamingConfigUpdates} = grpcbox_stream:stream_handler_state(
        StreamState0
    ),
    config_update(Chain, IsAlreadyStreamingConfigUpdates, Msg, StreamState0).

-spec validators(
    ctx:ctx(),
    gateway_pb:gateway_validators_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
validators(Ctx, #gateway_validators_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    validators(Chain, Ctx, Message).

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
-spec address_to_public_uri(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_address_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
address_to_public_uri(undefined = _Chain, _Ctx, #gateway_address_routing_data_req_v1_pb{} = _Msg) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
address_to_public_uri(
    Chain,
    Ctx,
    #gateway_address_routing_data_req_v1_pb{address = Address} = _Message
) ->
    lager:info("executing RPC address_to_public_uri with msg ~p", [_Message]),
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    RespPB =
        case sibyl_utils:address_data([Address]) of
            [] ->
                #gateway_error_resp_pb{
                    error = <<"no_public_route_for_address">>,
                    details = Address
                };
            [RoutingAddress] ->
                #gateway_public_routing_data_resp_v1_pb{
                    address = Address,
                    public_uri = RoutingAddress
                }
        end,
    Resp = sibyl_utils:encode_gateway_resp_v1(
        RespPB,
        CurHeight,
        sibyl_mgr:sigfun()
    ),
    {ok, Resp, Ctx}.

-spec config(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_config_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
config(
    undefined = _Chain,
    _Ctx,
    #gateway_config_req_v1_pb{} = _Msg
) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
config(
    Chain,
    Ctx,
    #gateway_config_req_v1_pb{
        keys = Keys
    } = Request
) ->
    lager:info("executing RPC config with msg ~p", [Request]),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    NumKeys = length(Keys),
    Response0 =
        case NumKeys > ?MAX_KEY_SIZE of
            true ->
                #gateway_error_resp_pb{
                    error = <<"max_key_size_exceeded">>,
                    details = list_to_binary(
                        lists:concat(["limit ", ?MAX_KEY_SIZE, ". keys presented ", NumKeys])
                    )
                };
            false ->
                %% iterate over the keys submitted in the request and retrieve
                %% current chain var value for each
                Res =
                    lists:reverse(
                        lists:foldl(
                            fun(Key, Acc) ->
                                try
                                    case
                                        blockchain_ledger_v1:config(
                                            binary_to_existing_atom(Key, utf8),
                                            Ledger
                                        )
                                    of
                                        {ok, V} ->
                                            [
                                                #key_val_v1_pb{
                                                    key = Key,
                                                    val = sibyl_utils:ensure(binary, V)
                                                }
                                                | Acc
                                            ];
                                        {error, _} ->
                                            [
                                                #key_val_v1_pb{key = Key, val = <<"non_existent">>}
                                                | Acc
                                            ]
                                    end
                                catch
                                    _:_ ->
                                        [#key_val_v1_pb{key = Key, val = <<"non_existent">>} | Acc]
                                end
                            end,
                            [],
                            Keys
                        )
                    ),
                #gateway_config_resp_v1_pb{result = Res}
        end,

    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
        CurHeight,
        sibyl_mgr:sigfun()
    ),
    {ok, Response1, Ctx}.

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
    true = _IsAlreadyStreamingConfigUpdates,
    #gateway_config_update_req_v1_pb{} = _Msg,
    StreamState
) ->
    %% we are already streaming POCs so do nothing further here
    {ok, StreamState};
config_update(
    _Chain,
    false = _IsAlreadyStreamingConfigUpdates,
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
            config_streaming_initialized => true
        }
    ),
    lager:info("*** config update complete", []),
    {ok, NewStreamState}.

-spec validators(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_validators_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
validators(
    undefined = _Chain,
    _Ctx,
    #gateway_validators_req_v1_pb{} = _Msg
) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
validators(
    Chain,
    Ctx,
    #gateway_validators_req_v1_pb{
        quantity = NumVals
    } = Request
) ->
    lager:info("executing RPC validators with msg ~p", [Request]),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    %% get list of current validators from the cache
    %% and then get a random selection of these with size
    %% equal to NumVals
    Vals = sibyl_mgr:validators(),
    RandomVals = blockchain_utils:shuffle(Vals),
    SelectedVals = lists:sublist(RandomVals, max(1, min(NumVals, ?VALIDATOR_LIMIT))),
    lager:info("randomly selected validators: ~p", [SelectedVals]),
    EncodedVals = [
        #routing_address_pb{pub_key = Addr, uri = Routing}
        || {Addr, Routing} <- SelectedVals
    ],
    Response = sibyl_utils:encode_gateway_resp_v1(
        #gateway_validators_resp_v1_pb{result = EncodedVals},
        CurHeight,
        sibyl_mgr:sigfun()
    ),
    {ok, Response, Ctx}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec maybe_init_stream_state(atom(), undefined | handler_state(), grpcbox_stream:t()) ->
    grpcbox_stream:t().
maybe_init_stream_state(RPC, undefined, StreamState) ->
    lager:debug("handler init, stream state ~p", [StreamState]),
    NewStreamState = init(RPC, StreamState),
    NewStreamState;
maybe_init_stream_state(_RPC, _HandlerState, StreamState) ->
    StreamState.
