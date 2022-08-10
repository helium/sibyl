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
    version/2,
    region_params/2
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
    lager:debug("executing RPC version with msg ~p", [_Message]),
    VersionFn = application:get_env(sibyl, version_fn, fun sibyl_utils:default_version/0),
    Response = sibyl_utils:encode_gateway_resp_v1(
        #gateway_version_resp_v1_pb{version = VersionFn()},
        sibyl_mgr:sigfun()
    ),
    {ok, Response, Ctx}.

-spec region_params(
    ctx:ctx(),
    gateway_pb:gateway_region_params_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
region_params(Ctx, #gateway_region_params_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    region_params(Chain, Ctx, Message).

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
    Chain,
    Ctx,
    #gateway_validators_req_v1_pb{
        quantity = NumVals
    } = Request
) ->
    lager:debug("executing RPC validators with msg ~p", [Request]),
    Ledger = blockchain:ledger(Chain),
    %% get list of current validators from the cache
    %% and then get a random sub set of these with size
    %% equal to NumVals
    {ok, ConsensusAddrs} = blockchain_ledger_v1:consensus_members(Ledger),
    IgnoreVals = application:get_env(sibyl, validator_ignore_list, []),
    lager:debug("ignoring validators: ~p", [IgnoreVals]),
    Vals = sibyl_mgr:validators(),
    Vals1 = lists:filter(
        fun({PubKeyBin, _URL}) -> not lists:member(PubKeyBin, IgnoreVals) end,
        Vals
    ),
    Vals2 = lists:filter(
        fun({PubKeyBin, _URL}) -> not lists:member(PubKeyBin, ConsensusAddrs) end,
        Vals1
    ),
    RandomVals = blockchain_utils:shuffle(Vals2),
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

-spec region_params(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_region_params_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
region_params(
    undefined = _Chain,
    _Ctx,
    #gateway_region_params_req_v1_pb{} = _Msg
) ->
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
region_params(
    Chain,
    Ctx,
    #gateway_region_params_req_v1_pb{
        address = GWAddr,
        region = SpecifiedRegion
    } = Request
) ->
    lager:debug("executing RPC region_params with msg ~p", [Request]),
    Ledger = blockchain:ledger(Chain),
    Response0 =
        case verify_sig(Request) of
            {false, SignedReq} ->
                #gateway_error_resp_pb{
                    error = <<"bad_signature">>,
                    details = SignedReq
                };
            true ->
                %% check if the GW has been asserted and if true use the region & gain included there
                %% if not asserted then use the specified region and default gain to undefined
                {Region, Gain} = maybe_use_asserted_region(
                    GWAddr, sibyl_utils:ensure(atom, SpecifiedRegion), Ledger
                ),
                lager:debug("region: ~p, gain: ~p", [Region, Gain]),
                case region_params_for_region(Region, Ledger) of
                    {error, no_params_for_region = Reason} ->
                        #gateway_error_resp_pb{
                            error = sibyl_utils:ensure(binary, Reason),
                            details = sibyl_utils:ensure(binary, Region)
                        };
                    {ok, Params} ->
                        #gateway_region_params_resp_v1_pb{
                            gain = Gain,
                            region = Region,
                            params = #blockchain_region_params_v1_pb{
                                region_params = Params
                            }
                        }
                end
        end,
    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
        sibyl_mgr:sigfun()
    ),
    {ok, Response1, Ctx}.

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

-spec region_params_for_region(libp2p_crypto:pubkey_bin(), blockchain_ledger_v1:ledger()) ->
    {ok, [blockchain_region_param_v1:region_param_v1()]} | {error, any()}.
region_params_for_region(Region, Ledger) ->
    case blockchain_region_params_v1:for_region(Region, Ledger) of
        {error, Reason} ->
            lager:error(
                "Could not get params for region: ~p, reason: ~p",
                [Region, Reason]
            ),
            {error, no_params_for_region};
        {ok, Params} ->
            {ok, Params}
    end.

-spec maybe_use_asserted_region(libp2p_crypto:pubkey_bin(), atom(), blockchain_ledger_v1:ledger()) ->
    {atom(), non_neg_integer()}.
maybe_use_asserted_region(Addr, DefaultRegion, Ledger) ->
    case blockchain_ledger_v1:find_gateway_info(Addr, Ledger) of
        {ok, GWInfo} ->
            Location = blockchain_ledger_gateway_v2:location(GWInfo),
            case blockchain_region_v1:h3_to_region(Location, Ledger) of
                {ok, Region} ->
                    Gain = blockchain_ledger_gateway_v2:gain(GWInfo),
                    lager:debug("got asserted region: ~p and gain: ~p for gateway: ~p", [
                        Region, Gain, Addr
                    ]),
                    {sibyl_utils:normalize_region(Region), Gain};
                {error, _Reason} ->
                    {DefaultRegion, undefined}
            end;
        {error, _Reason} ->
            {DefaultRegion, undefined}
    end.

-spec verify_sig(#gateway_region_params_req_v1_pb{}) ->
    true | {false, binary()}.
verify_sig(#gateway_region_params_req_v1_pb{address = Addr, signature = SignedReq} = Request) ->
    BaseReq = Request#gateway_region_params_req_v1_pb{signature = <<>>},
    do_verify_sig(Addr, BaseReq, SignedReq).

-spec do_verify_sig(
    libp2p_crypto:pubkey_bin(),
    #gateway_region_params_req_v1_pb{},
    binary()
) -> true | {false, binary()}.
do_verify_sig(Addr, BaseReq, SignedReq) ->
    PubKey = libp2p_crypto:bin_to_pubkey(Addr),
    EncodedReq = gateway_pb:encode_msg(BaseReq),
    case libp2p_crypto:verify(EncodedReq, SignedReq, PubKey) of
        false ->
            {false, SignedReq};
        true ->
            true
    end.
