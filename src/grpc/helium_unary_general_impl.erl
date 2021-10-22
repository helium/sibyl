-module(helium_unary_general_impl).

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

-export([
    address_to_public_uri/2,
    config/2,
    validators/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_hbvr 'general' callbacks
%% ------------------------------------------------------------------
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

-spec validators(
    ctx:ctx(),
    gateway_pb:gateway_validators_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
validators(Ctx, #gateway_validators_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    validators(Chain, Ctx, Message).

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
