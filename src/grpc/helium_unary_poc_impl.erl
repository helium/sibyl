-module(helium_unary_poc_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").
-include_lib("blockchain/include/blockchain_utils.hrl").

-export([
    check_challenge_target/2,
    send_report/2,
    poc_key_to_public_uri/2
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
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
check_challenge_target(
    _Chain,
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
    lager:debug("executing RPC check_challenge_target with msg ~p", [Request]),
    PubKey = libp2p_crypto:bin_to_pubkey(ChallengeePubKeyBin),
    %% verify the signature of the request
    BaseReq = Request#gateway_poc_check_challenge_target_req_v1_pb{challengee_sig = <<>>},
    EncodedReq = gateway_pb:encode_msg(BaseReq),
    case libp2p_crypto:verify(EncodedReq, Signature, PubKey) of
        false ->
            {grpc_error, {grpcbox_stream:code_to_status(14), <<"bad signature">>}};
        true ->
            %% are we the target  ?
            lager:info(
                "checking if GW ~p is target for poc key ~p",
                [?TO_ANIMAL_NAME(ChallengeePubKeyBin), POCKey]
            ),
            {ok, POCMgr} = application:get_env(sibyl, poc_mgr_mod),
            Response0 =
                case POCMgr:check_target(ChallengeePubKeyBin, BlockHash, POCKey) of
                    {error, Reason} ->
                        #gateway_error_resp_pb{
                            error = Reason,
                            details = POCKey
                        };
                    false ->
                        %% nope, we are not the target
                        #gateway_poc_check_challenge_target_resp_v1_pb{
                            target = false,
                            onion = <<>>
                        };
                    {true, Onion} ->
                        lager:debug("target identified as ~p for poc ~p", [
                            ChallengeePubKeyBin, POCKey
                        ]),
                        %% we are the target, return the onion
                        #gateway_poc_check_challenge_target_resp_v1_pb{
                            target = true,
                            onion = Onion
                        }
                end,
            Response1 = sibyl_utils:encode_gateway_resp_v1(
                Response0,
                sibyl_mgr:sigfun()
            ),
            {ok, Response1, Ctx}
    end.

-spec send_report(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_poc_report_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
send_report(undefined = _Chain, _Ctx, #gateway_poc_report_req_v1_pb{} = _Msg) ->
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
send_report(
    Chain,
    Ctx,
    #gateway_poc_report_req_v1_pb{
        msg = {ReportType, Report}, onion_key_hash = OnionKeyHash
    } =
        Request
) ->
    lager:debug("executing RPC send_report with msg ~p", [Request]),
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    %% get the addr of the reportee from the witness or receipt report
    Peer = reportee_addr(Report),
    RespPB =
        case verify_report_sig(Report) of
            {false, SignedReq} ->
                #gateway_error_resp_pb{
                    error = <<"bad_signature">>,
                    details = SignedReq
                };
            true ->
                %% find the POC in the ledger using onionkeyhash as key
                case blockchain_ledger_v1:find_public_poc(OnionKeyHash, Ledger) of
                    {ok, PublicPoC} ->
                        Challenger = blockchain_ledger_poc_v3:challenger(PublicPoC),
                        SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
                        PeerP2PAddr = libp2p_crypto:pubkey_bin_to_p2p(Peer),
                        case SelfPubKeyBin =:= Challenger of
                            true ->
                                {ok, POCMgr} = application:get_env(sibyl, poc_mgr_mod),
                                ok = POCMgr:report(
                                    {ReportType, Report}, OnionKeyHash, Peer, PeerP2PAddr
                                ),
                                #gateway_success_resp_pb{};
                            false ->
                                lager:warning(
                                    "received report when not challenger. Report: ~p, OnionKeyHash: ~p",
                                    [
                                        Report, OnionKeyHash
                                    ]
                                ),
                                #gateway_error_resp_pb{
                                    error = <<"invalid_challenger">>, details = OnionKeyHash
                                }
                        end;
                    _ ->
                        lager:warning(
                            "received report for unknown POC. Report: ~p, OnionKeyHash: ~p",
                            [
                                Report, OnionKeyHash
                            ]
                        ),
                        #gateway_error_resp_pb{
                            error = <<"invalid onion key hash">>, details = OnionKeyHash
                        }
                end
        end,
    Resp = sibyl_utils:encode_gateway_resp_v1(
        RespPB,
        sibyl_mgr:sigfun()
    ),
    lager:debug("send_report response for OnionKeyHash ~p: ~p", [OnionKeyHash, Resp]),
    {ok, Resp, Ctx}.

-spec poc_key_to_public_uri(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_poc_key_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
poc_key_to_public_uri(undefined = _Chain, _Ctx, #gateway_poc_key_routing_data_req_v1_pb{} = _Msg) ->
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
poc_key_to_public_uri(
    Chain,
    Ctx,
    #gateway_poc_key_routing_data_req_v1_pb{key = OnionKeyHash} = _Message
) ->
    lager:debug("executing RPC poc_key_to_public_uri with msg ~p", [_Message]),
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    RespPB =
        case blockchain_ledger_v1:find_public_poc(OnionKeyHash, Ledger) of
            {error, not_found} ->
                #gateway_error_resp_pb{
                    error = <<"poc_not_found">>,
                    details = OnionKeyHash
                };
            {ok, PoC} ->
                Challenger = blockchain_ledger_poc_v3:challenger(PoC),
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
        sibyl_mgr:sigfun()
    ),
    {ok, Resp, Ctx}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec reportee_addr(#blockchain_poc_receipt_v1_pb{} | #blockchain_poc_witness_v1_pb{}) ->
    libp2p_crypto:pubkey_bin().
reportee_addr(#blockchain_poc_receipt_v1_pb{gateway = Addr}) ->
    Addr;
reportee_addr(#blockchain_poc_witness_v1_pb{gateway = Addr}) ->
    Addr.

-spec verify_report_sig(#blockchain_poc_receipt_v1_pb{} | #blockchain_poc_witness_v1_pb{}) ->
    true | {false, binary()}.
verify_report_sig(#blockchain_poc_receipt_v1_pb{gateway = Addr, signature = SignedReq} = Report) ->
    BaseReq = Report#blockchain_poc_receipt_v1_pb{signature = <<>>},
    do_verify_report_sign(Addr, BaseReq, SignedReq);
verify_report_sig(#blockchain_poc_witness_v1_pb{gateway = Addr, signature = SignedReq} = Report) ->
    BaseReq = Report#blockchain_poc_witness_v1_pb{signature = <<>>},
    do_verify_report_sign(Addr, BaseReq, SignedReq).
-spec do_verify_report_sign(
    libp2p_crypto:pubkey_bin(),
    #blockchain_poc_receipt_v1_pb{} | #blockchain_poc_witness_v1_pb{},
    binary()
) -> true | {false, binary()}.
do_verify_report_sign(Addr, BaseReq, SignedReq) ->
    PubKey = libp2p_crypto:bin_to_pubkey(Addr),
    EncodedReq = gateway_pb:encode_msg(BaseReq),
    case libp2p_crypto:verify(EncodedReq, SignedReq, PubKey) of
        false ->
            {false, SignedReq};
        true ->
            true
    end.
