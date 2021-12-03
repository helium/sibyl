-module(helium_unary_txn_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").
-include_lib("helium_proto/include/blockchain_txn_vars_v1_pb.hrl").
-include_lib("helium_proto/include/blockchain_txn_pb.hrl").

-export([
    submit_txn/2,
    query_txn/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_hbvr 'general' callbacks
%% ------------------------------------------------------------------
-spec submit_txn(
    ctx:ctx(),
    gateway_pb:gateway_submit_txn_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
submit_txn(Ctx, #gateway_submit_txn_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    submit_txn(Chain, Ctx, Message).

-spec query_txn(
    ctx:ctx(),
    gateway_pb:gateway_query_txn_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
query_txn(Ctx, #gateway_query_txn_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    query_txn(Chain, Ctx, Message).
%% ------------------------------------------------------------------
%% callback breakout functions
%% ------------------------------------------------------------------
-spec submit_txn(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_submit_txn_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
submit_txn(undefined = _Chain, _Ctx, #gateway_submit_txn_req_v1_pb{} = _Msg) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
submit_txn(
    Chain,
    Ctx,
    #gateway_submit_txn_req_v1_pb{txn = #blockchain_txn_pb{txn = {_TxnType, Txn}}} = _Message
) ->
    lager:info("executing RPC submit_txn with msg ~p", [_Message]),
    {ok, TxnKey} = blockchain_pending_txn_mgr:submit_txn(Txn),
    SelfPubKeyBin = blockchain_swarm:pubkey_bin(),
    Chain = sibyl_mgr:blockchain(),
    RespPB =
        case sibyl_utils:address_data([SelfPubKeyBin]) of
            [] ->
                #gateway_error_resp_pb{
                    error = <<"no_public_route_for_address">>,
                    details = SelfPubKeyBin
                };
            [RoutingAddressPB] ->
                #gateway_submit_txn_resp_v1_pb{
                    key = TxnKey,
                    validator = RoutingAddressPB
                }
        end,
    Resp = sibyl_utils:encode_gateway_resp_v1(
        RespPB,
        sibyl_mgr:sigfun()
    ),
    {ok, Resp, Ctx}.

-spec query_txn(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_query_txn_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
query_txn(undefined = _Chain, _Ctx, #gateway_query_txn_req_v1_pb{} = _Msg) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
query_txn(
    Chain,
    Ctx,
    #gateway_query_txn_req_v1_pb{key = TxnKey} = _Message
) ->
    lager:info("executing RPC query_txn with msg ~p", [_Message]),
    RespPB =
        case blockchain_pending_txn_mgr:get_txn_status(TxnKey) of
            {ok, {cleared, Block}} ->
                #gateway_query_txn_resp_v1_pb{
                    status = cleared,
                    details = integer_to_binary(Block),
                    acceptors = [],
                    rejectors = []
                };
            {ok, {failed, Reason}} ->
                #gateway_query_txn_resp_v1_pb{
                    status = failed,
                    details = Reason,
                    acceptors = [],
                    rejectors = []
                };
            {ok, pending,
                #{
                    acceptors := Acceptors,
                    rejectors := Rejectors
                } = _PendingDetails} ->
                #gateway_query_txn_resp_v1_pb{
                    status = pending,
                    details = undefined,
                    acceptors = encode_acceptors(Acceptors),
                    rejectors = encode_rejectors(Rejectors)
                };
            {error, txn_not_found} ->
                #gateway_error_resp_pb{
                    error = <<"txn_not_found">>,
                    details = TxnKey
                }
        end,

    Chain = sibyl_mgr:blockchain(),
    Resp = sibyl_utils:encode_gateway_resp_v1(
        RespPB,
        sibyl_mgr:sigfun()
    ),
    {ok, Resp, Ctx}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
encode_acceptors(Acceptors) ->
    encode_acceptors(Acceptors, []).
encode_acceptors([], Acc) ->
    Acc;
encode_acceptors([{MemberPubKey, Height, QueuePos} | T], Acc) ->
    Acc1 = [#acceptor_pb{height = Height, queue_pos = QueuePos, pub_key = MemberPubKey} | Acc],
    encode_acceptors(T, Acc1).

encode_rejectors(Acceptors) ->
    encode_rejectors(Acceptors, []).
encode_rejectors([], Data) ->
    Data;
encode_rejectors([{MemberPubKey, Height, RejectReason} | T], Acc) ->
    Acc1 = [#rejector_pb{height = Height, reason = RejectReason, pub_key = MemberPubKey} | Acc],
    encode_rejectors(T, Acc1).
