-module(helium_unary_general_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").
-include_lib("helium_proto/include/blockchain_txn_vars_v1_pb.hrl").

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
    validators/2,
    version/2
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

-spec version(
    ctx:ctx(),
    gateway_pb:gateway_version_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
version(Ctx, #gateway_version_req_v1_pb{} = _Message) ->
    lager:debug("executing RPC vrsion with msg ~p", [_Message]),
    Version = miner:version(),
    Response = sibyl_utils:encode_gateway_resp_v1(
        #gateway_version_resp_v1_pb{version = Version},
        sibyl_mgr:sigfun()
    ),
    {ok, Response, Ctx}.

%% ------------------------------------------------------------------
%% callback breakout functions
%% ------------------------------------------------------------------
-spec address_to_public_uri(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_address_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
address_to_public_uri(undefined = _Chain, _Ctx, #gateway_address_routing_data_req_v1_pb{} = _Msg) ->
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
address_to_public_uri(
    Chain,
    Ctx,
    #gateway_address_routing_data_req_v1_pb{address = Address} = _Message
) ->
    lager:debug("executing RPC address_to_public_uri with msg ~p", [_Message]),
    Chain = sibyl_mgr:blockchain(),
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
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
config(
    Chain,
    Ctx,
    #gateway_config_req_v1_pb{
        keys = Keys
    } = Request
) ->
    lager:debug("executing RPC config with msg ~p", [Request]),
    Ledger = blockchain:ledger(Chain),
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
                    lists:map(
                        fun(Key) ->
                            try
                                case
                                    blockchain_ledger_v1:config(
                                        list_to_existing_atom(Key),
                                        Ledger
                                    )
                                of
                                    {ok, V} -> to_var(Key, V);
                                    {error, _} -> to_var(Key, undefined)
                                end
                            catch
                                _:_ -> to_var(Key, undefined)
                            end
                        end,
                        Keys
                    ),
                #gateway_config_resp_v1_pb{result = Res}
        end,

    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
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
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
validators(
    _Chain,
    Ctx,
    #gateway_validators_req_v1_pb{
        quantity = NumVals
    } = Request
) ->
    lager:debug("executing RPC validators with msg ~p", [Request]),
    %% get list of current validators from the cache
    %% and then get a random sub set of these with size
    %% equal to NumVals
    IgnoreVals = application:get_env(sibyl, validator_ignore_list, []),
    lager:debug("ignoring validators: ~p", [IgnoreVals]),
    Vals = sibyl_mgr:validators(),
    Vals1 = lists:filter(
        fun({PubKeyBin, _URL}) -> not lists:member(PubKeyBin, IgnoreVals) end,
        Vals
    ),
    RandomVals = blockchain_utils:shuffle(Vals1),
    SelectedVals = lists:sublist(RandomVals, max(1, min(NumVals, ?VALIDATOR_LIMIT))),
    lager:debug("randomly selected validators: ~p", [SelectedVals]),

    EncodedVals = [
        #routing_address_pb{pub_key = Addr, uri = Routing}
     || {Addr, Routing} <- SelectedVals
    ],
    Response = sibyl_utils:encode_gateway_resp_v1(
        #gateway_validators_resp_v1_pb{result = EncodedVals},
        sibyl_mgr:sigfun()
    ),
    {ok, Response, Ctx}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
to_var(Key, undefined) ->
    #blockchain_var_v1_pb{
        name = Key,
        type = undefined,
        value = undefined
    };
to_var(Key, V) ->
    blockchain_txn_vars_v1:to_var(Key, V).
