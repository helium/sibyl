-module(helium_unary_state_channels_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").
-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-type sc_ledger() :: blockchain_ledger_state_channel_v1 | blockchain_ledger_state_channel_v2.

-export([
    is_active_sc/2,
    is_overpaid_sc/2,
    close_sc/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_bhvr unary callbacks
%% ------------------------------------------------------------------
-spec is_active_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_is_active_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_active_sc(Ctx, #gateway_sc_is_active_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    is_active_sc(Chain, Ctx, Message).

-spec is_overpaid_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_is_overpaid_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_overpaid_sc(Ctx, #gateway_sc_is_overpaid_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    is_overpaid_sc(Chain, Ctx, Message).

-spec close_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_close_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()}.
close_sc(Ctx, #gateway_sc_close_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    close_sc(Chain, Ctx, Message).
%% ------------------------------------------------------------------
%% callback breakout functions
%% ------------------------------------------------------------------
-spec is_active_sc(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_sc_is_active_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_active_sc(undefined = _Chain, _Ctx, #gateway_sc_is_active_req_v1_pb{} = _Msg) ->
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
is_active_sc(
    Chain,
    Ctx,
    #gateway_sc_is_active_req_v1_pb{sc_id = SCID, sc_owner = SCOwner} = _Message
) ->
    lager:debug("executing RPC is_active with msg ~p", [_Message]),
    Ledger = blockchain:ledger(Chain),
    Response0 =
        case get_ledger_state_channel(SCID, SCOwner, Ledger) of
            {ok, Mod, SC} ->
                #gateway_sc_is_active_resp_v1_pb{
                    active = true,
                    sc_id = SCID,
                    sc_owner = SCOwner,
                    sc_expiry_at_block = Mod:expire_at_block(SC),
                    sc_original_dc_amount = get_sc_original(Mod, SC)
                };
            _ ->
                #gateway_sc_is_active_resp_v1_pb{
                    active = false,
                    sc_id = SCID,
                    sc_owner = SCOwner,
                    sc_expiry_at_block = undefined,
                    sc_original_dc_amount = undefined
                }
        end,

    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
        sibyl_mgr:sigfun()
    ),
    {ok, Response1, Ctx}.

-spec is_overpaid_sc(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_sc_is_overpaid_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_overpaid_sc(undefined = _Chain, _Ctx, #gateway_sc_is_overpaid_req_v1_pb{} = _Msg) ->
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
is_overpaid_sc(
    Chain,
    Ctx,
    #gateway_sc_is_overpaid_req_v1_pb{sc_id = SCID, sc_owner = SCOwner, total_dcs = TotalDCs} =
        _Message
) ->
    lager:debug("executing RPC is_overpaid with msg ~p", [_Message]),
    Response0 = #gateway_sc_is_overpaid_resp_v1_pb{
        overpaid = check_is_overpaid_sc(SCID, SCOwner, TotalDCs, Chain),
        sc_id = SCID,
        sc_owner = SCOwner
    },
    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
        sibyl_mgr:sigfun()
    ),
    {ok, Response1, Ctx}.

-spec close_sc(
    blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_sc_close_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()}.
close_sc(undefined = _Chain, _Ctx, #gateway_sc_close_req_v1_pb{} = _Msg) ->
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
close_sc(_Chain, Ctx, #gateway_sc_close_req_v1_pb{close_txn = CloseTxn} = _Message) ->
    lager:info("executing RPC close with msg ~p", [_Message]),
    %% TODO, maybe validate the SC exists ? but then if its a v1 it could already have been
    %% deleted from the ledger.....
    SC = blockchain_txn_state_channel_close_v1:state_channel(CloseTxn),
    SCID = blockchain_state_channel_v1:id(SC),
    ok = blockchain_worker:submit_txn(CloseTxn),
    Response0 = #gateway_sc_close_resp_v1_pb{sc_id = SCID, response = <<"ok">>},
    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
        sibyl_mgr:sigfun()
    ),
    {ok, Response1, Ctx}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------

-spec check_is_active_sc(
    SCID :: binary(),
    SCOwner :: libp2p_crypto:pubkey_bin(),
    Chain :: blockchain:blockchain()
) -> true | false.
check_is_active_sc(SCID, SCOwner, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case get_ledger_state_channel(SCID, SCOwner, Ledger) of
        {ok, _Mod, _SC} -> true;
        _ -> false
    end.

-spec check_is_overpaid_sc(
    SCID :: binary(),
    SCOwner :: libp2p_crypto:pubkey_bin(),
    TotalDCs :: non_neg_integer(),
    Chain :: blockchain:blockchain()
) -> true | false.
check_is_overpaid_sc(SCID, SCOwner, TotalDCs, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case get_ledger_state_channel(SCID, SCOwner, Ledger) of
        {ok, blockchain_ledger_state_channel_v2, SC} ->
            blockchain_ledger_state_channel_v2:original(SC) < TotalDCs;
        _ ->
            false
    end.

-spec get_ledger_state_channel(binary(), binary(), blockchain_ledger_v1:ledger()) ->
    {ok, sc_ledger(), blockchain_state_channel_v1:state_channel()} | {error, any()}.
get_ledger_state_channel(SCID, Owner, Ledger) ->
    case blockchain_ledger_v1:find_state_channel_with_mod(SCID, Owner, Ledger) of
        {ok, Mod, SC} -> {ok, Mod, SC};
        _ -> {error, inactive_sc}
    end.

-spec get_sc_original(
    blockchain_ledger_state_channel_v1
    | blockchain_ledger_state_channel_v2,
    blockchain_ledger_state_channel_v1:state_channel()
    | blockchain_ledger_state_channel_v2:state_channel()
) -> non_neg_integer().
get_sc_original(blockchain_ledger_state_channel_v1, _SC) ->
    0;
get_sc_original(blockchain_ledger_state_channel_v2, SC) ->
    blockchain_ledger_state_channel_v2:original(SC).
