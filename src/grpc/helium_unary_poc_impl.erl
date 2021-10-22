-module(helium_unary_poc_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").

-export([
    check_challenge_target/2,
    send_report/2,
    poc_key_to_public_uri/2,
    region_params/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_bhvr POC related unary callbacks
%% ------------------------------------------------------------------
-spec check_challenge_target(
    ctx:ctx(),
    gateway_pb:gateway_poc_check_challenge_target_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
check_challenge_target(Ctx, #gateway_poc_check_challenge_target_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    check_challenge_target(Chain, Ctx, Message).

-spec send_report(
    ctx:ctx(),
    gateway_pb:gateway_poc_report_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
send_report(Ctx, #gateway_poc_report_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    send_report(Chain, Ctx, Message).

-spec poc_key_to_public_uri(
    ctx:ctx(),
    gateway_pb:gateway_poc_key_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
poc_key_to_public_uri(Ctx, #gateway_poc_key_routing_data_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    poc_key_to_public_uri(Chain, Ctx, Message).

-spec region_params(
    ctx:ctx(),
    gateway_pb:gateway_poc_region_params_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
region_params(Ctx, #gateway_poc_region_params_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    region_params(Chain, Ctx, Message).
%% ------------------------------------------------------------------
%% callback breakout functions
%% ------------------------------------------------------------------
-spec check_challenge_target(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_poc_check_challenge_target_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
check_challenge_target(
    undefined = _Chain,
    _Ctx,
    #gateway_poc_check_challenge_target_req_v1_pb{} = _Msg
) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
check_challenge_target(
    Chain,
    Ctx,
    #gateway_poc_check_challenge_target_req_v1_pb{
        address = ChallengeePubKeyBin,
        challenger = _ChallengerPubKeyBin,
        height = _ChallengeHeight,
        block_hash = BlockHash,
        onion_key_hash = POCKey,
        notifier = _Notifier,
        challengee_sig = Signature
    } = Request
) ->
    lager:info("executing RPC check_challenge_target with msg ~p", [Request]),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    PubKey = libp2p_crypto:bin_to_pubkey(ChallengeePubKeyBin),
    %% verify the signature of the request
    BaseReq = Request#gateway_poc_check_challenge_target_req_v1_pb{challengee_sig = <<>>},
    EncodedReq = gateway_pb:encode_msg(BaseReq),
    case libp2p_crypto:verify(EncodedReq, Signature, PubKey) of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(14), <<"bad signature">>}};
        true ->
            %% are we the target  ?
            {ok, POCMgr} = application:get_env(sibyl, poc_mgr_mod),
            case POCMgr:check_target(ChallengeePubKeyBin, BlockHash, POCKey) of
                {error, Reason} ->
                    %% something went wrong, return error
                    {grpc_error, {grpcbox_stream:code_to_status(14), Reason}};
                false ->
                    %% nope, we are not the target
                    Response0 = #gateway_poc_check_challenge_target_resp_v1_pb{
                        target = false,
                        onion = <<>>
                    },
                    Response1 = sibyl_utils:encode_gateway_resp_v1(
                        Response0,
                        CurHeight,
                        sibyl_mgr:sigfun()
                    ),
                    {ok, Response1, Ctx};
                {true, Onion} ->
                    %% we are the target, return the onion
                    Response0 = #gateway_poc_check_challenge_target_resp_v1_pb{
                        target = true,
                        onion = Onion
                    },
                    Response1 = sibyl_utils:encode_gateway_resp_v1(
                        Response0,
                        CurHeight,
                        sibyl_mgr:sigfun()
                    ),
                    {ok, Response1, Ctx}
            end
    end.

-spec send_report(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_poc_report_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
send_report(undefined = _Chain, _Ctx, #gateway_poc_report_req_v1_pb{} = _Msg) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
send_report(
    Chain,
    Ctx,
    #gateway_poc_report_req_v1_pb{msg = Report, onion_key_hash = OnionKeyHash} = _Message
) ->
    lager:info("executing RPC send_report with msg ~p", [_Message]),
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    %% find the POC in the ledger using onionkeyhash as key
    RespPB =
        case blockchain_ledger_v1:find_public_poc(OnionKeyHash, Ledger) of
            {ok, PublicPoC} ->
                %% clients send POC reports to their usual validator
                %% we now need to route those reports to the challenger over p2p
                %% clients cannot send a report directly to the challenger as in the case
                %% of a witness report, it has no data on who the challenger is
                spawn(fun() -> send_poc_report(OnionKeyHash, PublicPoC, Report) end),
                #gateway_success_resp_pb{resp = <<"ok">>, details = <<>>};
            _ ->
                #gateway_error_resp_pb{error = <<"invalid onion key hash">>, details = OnionKeyHash}
        end,
    Resp = sibyl_utils:encode_gateway_resp_v1(
        RespPB,
        CurHeight,
        sibyl_mgr:sigfun()
    ),
    {ok, Resp, Ctx}.

-spec poc_key_to_public_uri(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_poc_key_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
poc_key_to_public_uri(undefined = _Chain, _Ctx, #gateway_poc_key_routing_data_req_v1_pb{} = _Msg) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
poc_key_to_public_uri(
    Chain,
    Ctx,
    #gateway_poc_key_routing_data_req_v1_pb{key = OnionKeyHash} = _Message
) ->
    lager:info("executing RPC poc_key_to_public_uri with msg ~p", [_Message]),
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    RespPB =
        case blockchain_ledger_v1:find_public_poc(OnionKeyHash, Ledger) of
            {error, not_found} ->
                #gateway_error_resp_pb{
                    error = <<"poc_not_found">>,
                    details = OnionKeyHash
                };
            {ok, PoC} ->
                Challenger = blockchain_ledger_poc_v2:challenger(PoC),
                case sibyl_utils:address_data([Challenger]) of
                    [] ->
                        #gateway_error_resp_pb{
                            error = <<"no_public_route_for_challenger">>,
                            details = Challenger
                        };
                    [RoutingAddress] ->
                        #gateway_public_routing_data_resp_v1_pb{
                            address = Challenger,
                            public_uri = RoutingAddress
                        }
                end
        end,
    Resp = sibyl_utils:encode_gateway_resp_v1(
        RespPB,
        CurHeight,
        sibyl_mgr:sigfun()
    ),
    {ok, Resp, Ctx}.

-spec region_params(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_poc_region_params_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
region_params(undefined = _Chain, _Ctx, #gateway_poc_region_params_req_v1_pb{} = _Msg) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
region_params(
    Chain,
    Ctx,
    #gateway_poc_region_params_req_v1_pb{address = Addr, signature = Signature} = Request
) ->
    lager:info("executing RPC region_params with msg ~p", [Request]),
    Chain = sibyl_mgr:blockchain(),
    lager:info("*** region params point 1", []),
    Ledger = blockchain:ledger(Chain),
    lager:info("*** region params point 2", []),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    lager:info("*** region params point 3", []),
    PubKey = libp2p_crypto:bin_to_pubkey(Addr),
    lager:info("*** region params point 4", []),
    BaseReq = Request#gateway_poc_region_params_req_v1_pb{signature = <<>>},
    lager:info("*** region params point 5", []),
    EncodedReq = gateway_pb:encode_msg(BaseReq),
    lager:info("*** region params point 6", []),
    RespPB =
        case libp2p_crypto:verify(EncodedReq, Signature, PubKey) of
            false ->
                lager:info("*** region params point 7", []),
                #gateway_error_resp_pb{
                    error = <<"bad_signature">>,
                    details = Signature
                };
            true ->
                lager:info("*** region params point 8", []),
                case blockchain_ledger_v1:find_gateway_location(Addr, Ledger) of
                    {ok, Location} ->
                        case blockchain_region_v1:h3_to_region(Location, Ledger) of
                            {ok, Region} ->
                                case blockchain_region_params_v1:for_region(Region, Ledger) of
                                    {error, Reason} ->
                                        lager:error(
                                            "Could not get params for region: ~p, reason: ~p",
                                            [Region, Reason]
                                        ),
                                        #gateway_error_resp_pb{
                                            error = <<"failed_to_get_region_params">>,
                                            details = Region
                                        };
                                    {ok, Params} ->
                                        #gateway_poc_region_params_resp_v1_pb{
                                            address = Addr,
                                            region = atom_to_binary(Region, utf8),
                                            params = #blockchain_region_params_v1_pb{
                                                region_params = Params
                                            }
                                        }
                                end;
                            {error, Reason} ->
                                lager:error(
                                    "Could not get h3 region for location ~p, reason: ~p",
                                    [Location, Reason]
                                ),
                                #gateway_error_resp_pb{
                                    error = <<"failed_to_find_h3_region_for_location">>,
                                    details = Location
                                }
                        end;
                    {error, _Reason} ->
                        lager:error(
                            "Could not find location for pubkey: ~p",
                            [Addr]
                        ),
                        #gateway_error_resp_pb{
                            error = <<"no_location">>,
                            details = Addr
                        }
                end
        end,
    lager:info("*** region params point 9", []),
    lager:info("region RespPB: ~p", [RespPB]),
    Resp = sibyl_utils:encode_gateway_resp_v1(
        RespPB,
        CurHeight,
        sibyl_mgr:sigfun()
    ),
    lager:info("*** region params point 10", []),
    lager:info("region Resp: ~p", [Resp]),
    {ok, Resp, Ctx}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
send_poc_report(OnionKeyHash, POC, Report) ->
    send_poc_report(OnionKeyHash, POC, Report, 30).
send_poc_report(OnionKeyHash, POC, {ReportType, Report}, Retries) when Retries > 0 ->
    Challenger = blockchain_ledger_poc_v3:challenger(POC),
    SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
    P2PAddr = libp2p_crypto:pubkey_bin_to_p2p(Challenger),
    case SelfPubKeyBin =:= Challenger of
        true ->
            {ok, POCMgr} = application:get_env(sibyl, poc_mgr_mod),
            lager:info("challenger is ourself so sending directly to poc mgr: ~p", [POCMgr]),
            ok = POCMgr:report({ReportType, Report}, OnionKeyHash, SelfPubKeyBin, P2PAddr),
            ok;
        false ->
            {ok, POCReportHandler} = application:get_env(sibyl, poc_report_handler),
            case
                miner_poc:dial_framed_stream(
                    blockchain_swarm:swarm(),
                    P2PAddr,
                    POCReportHandler,
                    []
                )
            of
                {error, _Reason} ->
                    lager:error(
                        "failed to dial challenger ~p (~p).  Will try agai in 30 seconds",
                        [P2PAddr, _Reason]
                    ),
                    timer:sleep(timer:seconds(30)),
                    send_poc_report(OnionKeyHash, POC, {ReportType, Report}, Retries - 1);
                {ok, P2PStream} ->
                    lager:info("sending report to report handler ~p", [POCReportHandler]),
                    Data = blockchain_poc_response_v1:encode(Report),
                    Payload = term_to_binary({OnionKeyHash, Data}),
                    _ = POCReportHandler:send(P2PStream, Payload),
                    ok
            end
    end;
send_poc_report(OnionKeyHash, _POC, _Report, _Retries) ->
    lager:warning("failed to dial challenger, max retry, POC: ~p", [OnionKeyHash]),
    ok.
