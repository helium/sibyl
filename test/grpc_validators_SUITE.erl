-module(grpc_validators_SUITE).

-include("sibyl.hrl").

-define(record_to_map(Rec, Ref),
    maps:from_list(lists:zip(record_info(fields, Rec), tl(tuple_to_list(Ref))))
).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    validators_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("../src/grpc/autogen/server/gateway_pb.hrl").
-include_lib("blockchain/include/blockchain.hrl").
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
        validators_test
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
    LocalSwarm = blockchain_swarm:swarm(),
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

    [
        {sup, Sup},
        {local_node_pubkey, LocalNodePubKey},
        {local_node_pubkey_bin, libp2p_crypto:pubkey_to_bin(LocalNodePubKey)},
        {local_node_privkey, LocalNodePrivKey},
        {local_node_sigfun, LocalNodeSigFun},
        {sibyl_sup, SibylSupPid},
        {grpc_connection, Connection}
        | Config1
    ].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    Connection = ?config(grpc_connection, Config),
    grpc_client:stop_connection(Connection),
    BlockchainSup = ?config(sup, Config),
    SibylSup = ?config(sibyl_sup, Config),
    application:stop(grpcbox),
    application:stop(grpc_client),
    true = erlang:exit(BlockchainSup, normal),
    true = erlang:exit(SibylSup, normal),
    sibyl_ct_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

validators_test(Config) ->
    %% exercise the validators api
    %% client can request to be returned data on one or more random validators
    %% the pubkey and the URI will be returned for each validator
    Connection = ?config(grpc_connection, Config),
    [GatewayNode1 | _] = ?config(nodes, Config),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),
    ConsensusMembers = ?config(consensus_members, Config),
    LocalChain = blockchain_worker:blockchain(),
    LocalSwarm = blockchain_swarm:swarm(),

    %% Get a gateway chain, swarm and pubkey_bin
    GatewayNode1Chain = ct_rpc:call(GatewayNode1, blockchain_worker, blockchain, []),
    GatewayNode1Swarm = ct_rpc:call(GatewayNode1, blockchain_swarm, swarm, []),
    Self = self(),

    %% get an owner for our validators
    [{OwnerPubkeyBin, _OwnerPubkey, OwnerSigFun} | _] = ?config(consensus_members, Config),

    %% make a bunch of validators and stake em
    Keys = sibyl_ct_utils:generate_keys(10),
    Txns = [
        blockchain_txn_stake_validator_v1:new(
            StakePubkeyBin,
            OwnerPubkeyBin,
            ?bones(10000),
            ?bones(5)
        )
     || {StakePubkeyBin, {_StakePub, _StakePriv, _StakeSigFun}} <- Keys
    ],
    SignedTxns = [blockchain_txn_stake_validator_v1:sign(Txn, OwnerSigFun) || Txn <- Txns],

    %% Add block with with txns
    {ok, Block0} = sibyl_ct_utils:add_block(
        GatewayNode1,
        GatewayNode1Chain,
        ConsensusMembers,
        SignedTxns
    ),
    ct:pal("Block0: ~p", [Block0]),

    %% Fake gossip block
    ok = ct_rpc:call(GatewayNode1, blockchain_gossip_handler, add_block, [
        Block0,
        GatewayNode1Chain,
        Self,
        GatewayNode1Swarm
    ]),

    %% hardcode aliases for our validators
    %% sibyl will not return routing data unless a validator/gw has a public address
    %% so force an alias for each of our validators to a public IP
    ValAliases = lists:foldl(
        fun({PubKeyBin, {_, _, _}}, Acc) ->
            P2PAddr = libp2p_crypto:pubkey_bin_to_p2p(PubKeyBin),
            %% just give each val the same public ip...wont be used for anything
            [{P2PAddr, "/ip4/52.8.80.146/tcp/2154"} | Acc]
        end,
        [],
        Keys
    ),
    ct:pal("validator aliases ~p", [ValAliases]),
    %% set the aliases env var on our local node
    %% if no peerbook entries exist for our validators ( which they wont )
    %% then the node aliases env var will be checked
    application:set_env(libp2p, node_aliases, ValAliases),

    %% Wait till the block is gossiped
    %% and give the sibyl mgr time to refresh the cached list of validators
    ok = sibyl_ct_utils:local_add_and_gossip_fake_blocks(
        5,
        ConsensusMembers,
        LocalSwarm,
        LocalChain,
        Self
    ),
    ok = sibyl_ct_utils:wait_until_local_height(6),

    %% test the validators RPC
    {ok, #{
        headers := Headers1,
        result := #{
            msg := {validators_resp, ResponseMsg1},
            height := _ResponseHeight1,
            signature := _ResponseSig1
        } = Result1
    }} = grpc_client:unary(
        Connection,
        #{quantity => 2},
        'helium.gateway',
        'validators',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers1]),
    ct:pal("Response Body: ~p", [Result1]),
    #{<<":status">> := HttpStatus1} = Headers1,
    ?assertEqual(HttpStatus1, <<"200">>),
    #{result := Validators1} = ResponseMsg1,
    ?assertEqual(2, length(Validators1)),
    #{pub_key := V1PubKeyBin, uri := V1URI} = lists:nth(1, Validators1),
    #{pub_key := V2PubKeyBin, uri := V2URI} = lists:nth(2, Validators1),
    %% all validators will have the same URI due to our aliases above
    ?assertEqual(<<"http://52.8.80.146:10001/">>, V1URI),
    ?assertEqual(<<"http://52.8.80.146:10001/">>, V2URI),
    %% check the pub keys are from our list of validator keys
    ?assert(lists:keymember(V1PubKeyBin, 1, Keys)),
    ?assert(lists:keymember(V2PubKeyBin, 1, Keys)),

    %% test the validators RPC max validators limit
    {ok, #{
        headers := Headers2,
        result := #{
            msg := {validators_resp, ResponseMsg2},
            height := _ResponseHeight2,
            signature := _ResponseSig2
        } = Result2
    }} = grpc_client:unary(
        Connection,
        #{quantity => 10},
        'helium.gateway',
        'validators',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers2]),
    ct:pal("Response Body: ~p", [Result2]),
    #{<<":status">> := HttpStatus2} = Headers2,
    ?assertEqual(HttpStatus2, <<"200">>),
    #{result := Validators2} = ResponseMsg2,
    ?assertEqual(5, length(Validators2)),

    %% test the validators RPC min validators limit
    {ok, #{
        headers := Headers3,
        result := #{
            msg := {validators_resp, ResponseMsg3},
            height := _ResponseHeight3,
            signature := _ResponseSig3
        } = Result3
    }} = grpc_client:unary(
        Connection,
        #{quantity => 0},
        'helium.gateway',
        'validators',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers3]),
    ct:pal("Response Body: ~p", [Result3]),
    #{<<":status">> := HttpStatus3} = Headers3,
    ?assertEqual(HttpStatus3, <<"200">>),
    #{result := Validators3} = ResponseMsg3,
    ?assertEqual(1, length(Validators3)),
    ok.
%
%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------