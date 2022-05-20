-module(grpc_region_params_SUITE).

-include("sibyl.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").

-define(record_to_map(Rec, Ref),
    maps:from_list(lists:zip(record_info(fields, Rec), tl(tuple_to_list(Ref))))
).

-define(TEST_LOCATION, 631210968840687103).
-define(TEST_LOCATION2, 631210968910285823).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    streaming_region_params_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("../src/grpc/autogen/server/gateway_pb.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        streaming_region_params_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    %% setup test dirs
    Config0 = sibyl_ct_utils:init_base_dir_config(?MODULE, TestCase, Config),

    application:ensure_all_started(lager),
    application:ensure_all_started(grpc_client),
    application:ensure_all_started(grpcbox),

    Config1 = sibyl_ct_utils:init_per_testcase(TestCase, Config0),

    LogDir = ?config(log_dir, Config1),
    lager:set_loglevel(lager_console_backend, info),
    lager:set_loglevel({lager_file_backend, LogDir}, debug),

    Nodes = ?config(nodes, Config1),
    GenesisBlock = ?config(genesis_block, Config1),

    %% start a local blockchain
    #{public := LocalNodePubKey, secret := LocalNodePrivKey} = libp2p_crypto:generate_keys(
        ecc_compact
    ),
    BaseDir = ?config(base_dir, Config1),
    LocalNodeSigFun = libp2p_crypto:mk_sig_fun(LocalNodePrivKey),
    LocalNodeECDHFun = libp2p_crypto:mk_ecdh_fun(LocalNodePrivKey),
    Opts = [
        {key, {LocalNodePubKey, LocalNodeSigFun, LocalNodeECDHFun}},
        {seed_nodes, []},
        {port, 0},
        {num_consensus_members, 7},
        {base_dir, BaseDir}
    ],
    application:set_env(blockchain, peer_cache_timeout, 10000),
    application:set_env(blockchain, peerbook_update_interval, 200),
    application:set_env(blockchain, peerbook_allow_rfc1918, true),
    application:set_env(blockchain, listen_interface, "127.0.0.1"),
    application:set_env(blockchain, max_inbound_connections, length(Nodes) * 2),
    application:set_env(blockchain, outbound_gossip_connections, length(Nodes) * 2),

    {ok, Sup} = blockchain_sup:start_link(Opts),

    %% load the genesis block on the local node
    blockchain_worker:integrate_genesis_block(GenesisBlock),

    %% wait until the local node has the genesis block
    ok = sibyl_ct_utils:wait_until_local_height(1),

    {ok, SibylSupPid} = sibyl_sup:start_link(),
    %% give time for the mgr to be initialised with chain
    sibyl_ct_utils:wait_until(fun() -> sibyl_mgr:blockchain() /= undefined end),

    %% connect the local node to the slaves
    LocalSwarm = blockchain_swarm:tid(),
    ok = lists:foreach(
        fun(Node) ->
            NodeSwarm = ct_rpc:call(Node, blockchain_swarm, swarm, [], 2000),
            [H | _] = ct_rpc:call(Node, libp2p_swarm, listen_addrs, [NodeSwarm], 2000),
            libp2p_swarm:connect(LocalSwarm, H)
        end,
        Nodes
    ),
    %% wait until the local node is well connected
    sibyl_ct_utils:wait_until(
        fun() ->
            LocalGossipPeers = blockchain_swarm:gossip_peers(),
            ct:pal("local node connected to ~p peers", [length(LocalGossipPeers)]),
            length(LocalGossipPeers) >= (length(Nodes) / 2) + 1
        end
    ),

    %% setup the grpc connection
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 10001),

    Chain = blockchain_worker:blockchain(),
    [
        {sup, Sup},
        {local_node_pubkey, LocalNodePubKey},
        {local_node_pubkey_bin, libp2p_crypto:pubkey_to_bin(LocalNodePubKey)},
        {local_node_privkey, LocalNodePrivKey},
        {local_node_sigfun, LocalNodeSigFun},
        {sibyl_sup, SibylSupPid},
        {grpc_connection, Connection},
        {chain, Chain}
        | Config1
    ].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    blockchain_utils:teardown_var_cache(),
    Connection = ?config(grpc_connection, Config),
    grpc_client:stop_connection(Connection),
    BlockchainSup = ?config(sup, Config),
    SibylSup = ?config(sibyl_sup, Config),
    true = erlang:exit(BlockchainSup, normal),
    true = erlang:exit(SibylSup, normal),
    application:stop(grpcbox),
    application:stop(grpc_client),
    sibyl_ct_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
streaming_region_params_test(Config) ->
    %% add a gateway, assert its location
    %% subscribe to streaming region param updates
    %% reassert the GWs location
    %% confirm we receive a streaming update upon connect
    %% and then again after the reassert

    Chain = ?config(chain, Config),
    Connection = ?config(grpc_connection, Config),
    ConsensusMembers = ?config(consensus_members, Config),
    [GatewayNode1 | _] = ?config(nodes, Config),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),

    [_, {Payer, _PayerPubKey, PayerSigFun}, {Owner, _OwnerPubKey, OwnerSigFun} | _] =
        ConsensusMembers,

    %% add new gateway 1
    #{public := GatewayPubKey, secret := GatewayPrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    Gateway = libp2p_crypto:pubkey_to_bin(GatewayPubKey),
    GatewaySigFun = libp2p_crypto:mk_sig_fun(GatewayPrivKey),
    AddGatewayTx = blockchain_txn_add_gateway_v1:new(Owner, Gateway, Payer),
    SignedAddGatewayTx0 = blockchain_txn_add_gateway_v1:sign(AddGatewayTx, OwnerSigFun),
    SignedAddGatewayTx1 = blockchain_txn_add_gateway_v1:sign_request(
        SignedAddGatewayTx0, GatewaySigFun
    ),
    SignedAddGatewayTx2 = blockchain_txn_add_gateway_v1:sign_payer(
        SignedAddGatewayTx1, PayerSigFun
    ),
    ?assertEqual(ok, blockchain_txn_add_gateway_v1:is_valid(SignedAddGatewayTx2, Chain)),

    %% assert gateway 1
    AssertLocationRequestTx = blockchain_txn_assert_location_v2:new(
        Gateway, Owner, Payer, ?TEST_LOCATION, 1
    ),
    AssertLocationRequestTx1 = blockchain_txn_assert_location_v2:gain(AssertLocationRequestTx, 50),
    SignedAssertLocationTx0 = blockchain_txn_assert_location_v2:sign(
        AssertLocationRequestTx1, OwnerSigFun
    ),
    SignedAssertLocationTx1 = blockchain_txn_assert_location_v2:sign_payer(
        SignedAssertLocationTx0, PayerSigFun
    ),

    {ok, Block1} = sibyl_ct_utils:create_block(ConsensusMembers, [
        SignedAddGatewayTx2, SignedAssertLocationTx1
    ]),
    _ = blockchain_gossip_handler:add_block(Block1, Chain, self(), blockchain_swarm:tid()),
    ok = sibyl_ct_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.gateway',
        region_params_update,
        gateway_client_pb
    ),

    %% send the regions param update msg to subscribe
    Req = build_region_params_update_req(Gateway, GatewaySigFun),
    ok = grpc_client:send(Stream, Req),

    %% NOTE: the server will send the headers first before any data msg
    %%       but will only send them at the point of the first data msg being sent
    %% the headers will come in first, so assert those
    {ok, _Headers} = sibyl_ct_utils:wait_for(
        fun() ->
            case grpc_client:get(Stream) of
                empty ->
                    false;
                {headers, Headers} ->
                    {true, Headers}
            end
        end
    ),
    ct:pal("Headers : ~p", [_Headers]),

    %% confirm we receive a region params update
    {data, Result1} = grpc_client:rcv(Stream, 5000),
    ct:pal("Result1: ~p", [Result1]),
    #{
        msg := {region_params_streamed_resp, ResponseMsg1},
        height := _ResponseHeight1,
        block_time := _ResponseBlockTime1,
        block_age := _ResponseBlockAge1,
        signature := _ResponseSig1
    } = Result1,
    #{
        region := ReturnedRegion,
        params := _ReturnedParams,
        address := Gateway,
        gain := Gain
    } = ResponseMsg1,
    ?assertEqual(ReturnedRegion, 'US915'),
    ?assertEqual(Gain, 50),

    %% now reassert the GW and confirm we get a streams region params update
    AssertLocation2RequestTx = blockchain_txn_assert_location_v2:new(
        Gateway, Owner, Payer, ?TEST_LOCATION2, 2
    ),
    AssertLocation2RequestTx1 = blockchain_txn_assert_location_v2:gain(
        AssertLocation2RequestTx, 80
    ),
    SignedAssertLocation2Tx1 = blockchain_txn_assert_location_v2:sign(
        AssertLocation2RequestTx1, OwnerSigFun
    ),
    SignedAssertLocation2Tx2 = blockchain_txn_assert_location_v2:sign_payer(
        SignedAssertLocation2Tx1, PayerSigFun
    ),

    {ok, Block2} = sibyl_ct_utils:create_block(ConsensusMembers, [
        SignedAssertLocation2Tx2
    ]),

    {ok, CurHeight1} = blockchain:height(Chain),
    _ = blockchain_gossip_handler:add_block(Block2, Chain, self(), blockchain_swarm:tid()),
    ok = sibyl_ct_utils:wait_until(fun() ->
        {ok, NewHeight} = blockchain:height(Chain),
        NewHeight == CurHeight1 + 1
    end),

    %% confirm we receive a region params update
    {data, Result2} = grpc_client:rcv(Stream, 5000),
    ct:pal("Result2: ~p", [Result2]),
    #{
        msg := {region_params_streamed_resp, ResponseMsg2},
        height := _ResponseHeight2,
        block_time := _ResponseBlockTime2,
        block_age := _ResponseBlockAge2,
        signature := _ResponseSig2
    } = Result2,
    #{
        region := ReturnedRegion2,
        params := _ReturnedParams2,
        address := Gateway,
        gain := Gain2
    } = ResponseMsg2,
    ?assertEqual(ReturnedRegion2, 'US915'),
    ?assertEqual(Gain2, 80),
    ok.
%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
-spec build_region_params_update_req(libp2p_crypto:pubkey_bin(), function()) ->
    #gateway_region_params_update_req_v1_pb{}.
build_region_params_update_req(Address, SigFun) ->
    Req = #{address => Address},
    ReqEncoded = gateway_client_pb:encode_msg(Req, gateway_region_params_update_req_v1_pb),
    Req#{signature => SigFun(ReqEncoded)}.
