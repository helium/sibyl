-module(grpc_general_SUITE).

-include("sibyl.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").

-define(record_to_map(Rec, Ref),
    maps:from_list(lists:zip(record_info(fields, Rec), tl(tuple_to_list(Ref))))
).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    config_test/1,
    config_update_test/1,
    validators_test/1,
    version_test/1
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
        config_test,
        config_update_test,
        validators_test,
        version_test
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
config_test(Config) ->
    %% exercise the unary API config, supply it with a list of keys
    %% and confirm it returns correct chain val values for each
    Connection = ?config(grpc_connection, Config),

    %% use the grpc APIs to get some chain var config vales
    {ok, #{
        headers := Headers1,
        result := #{
            msg := {config_resp, ResponseMsg1},
            height := _ResponseHeight1,
            block_time := _ResponseBlockTime1,
            block_age := _ResponseBlockAge1,
            signature := _ResponseSig1
        } = Result1
    }} = grpc_client:unary(
        Connection,
        #{keys => ["sc_grace_blocks", "dc_payload_size"]},
        'helium.gateway',
        'config',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers1]),
    ct:pal("Response Body: ~p", [Result1]),
    #{<<":status">> := HttpStatus1} = Headers1,
    ?assertEqual(HttpStatus1, <<"200">>),
    #{result := KeyVals} = ResponseMsg1,
    ?assertEqual(
        [
            #{name => "sc_grace_blocks", type => "int", value => <<"5">>},
            #{name => "dc_payload_size", type => "int", value => <<"24">>}
        ],
        KeyVals
    ),

    %% test a request with invalid keys
    {ok, #{
        headers := Headers2,
        result := #{
            msg := {config_resp, ResponseMsg2},
            height := _ResponseHeight2,
            block_time := _ResponseBlockTime2,
            block_age := _ResponseBlockAge2,
            signature := _ResponseSig2
        } = Result2
    }} = grpc_client:unary(
        Connection,
        #{keys => ["bad_key1", "bad_key2"]},
        'helium.gateway',
        'config',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers2]),
    ct:pal("Response Body: ~p", [Result2]),
    #{<<":status">> := HttpStatus2} = Headers2,
    ?assertEqual(HttpStatus2, <<"200">>),
    #{result := KeyVals2} = ResponseMsg2,
    ?assertEqual(
        [
            #{name => "bad_key1", type => [], value => <<>>},
            #{name => "bad_key2", type => [], value => <<>>}
        ],
        KeyVals2
    ),

    %% test a request with too many keys
    %% in test mode, max keys is 5, non test mode its 50
    {ok, #{
        headers := Headers3,
        result := #{
            msg := {error_resp, ResponseMsg3},
            height := _ResponseHeight3,
            block_time := _ResponseBlockTime3,
            block_age := _ResponseBlockAge3,
            signature := _ResponseSig3
        } = Result3
    }} = grpc_client:unary(
        Connection,
        #{keys => ["key1", "key2", "key3", "key4", "key5", "key6"]},
        'helium.gateway',
        'config',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers3]),
    ct:pal("Response Body: ~p", [Result3]),
    #{<<":status">> := HttpStatus3} = Headers3,
    ?assertEqual(HttpStatus3, <<"200">>),
    #{error := ErrorMsg3, details := ErrorDetails3} = ResponseMsg3,
    ?assertEqual(<<"max_key_size_exceeded">>, ErrorMsg3),
    ?assertEqual(<<"limit 5. keys presented 6">>, ErrorDetails3),

    %% test a request with zero keys
    %% it should return an empty list response payload
    {ok, #{
        headers := Headers4,
        result := #{
            msg := {config_resp, ResponseMsg4},
            height := _ResponseHeight4,
            block_time := _ResponseBlockTime4,
            block_age := _ResponseBlockAge4,
            signature := _ResponseSig4
        } = Result4
    }} = grpc_client:unary(
        Connection,
        #{keys => []},
        'helium.gateway',
        'config',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers4]),
    ct:pal("Response Body: ~p", [Result4]),
    #{<<":status">> := HttpStatus4} = Headers4,
    ?assertEqual(HttpStatus4, <<"200">>),
    #{result := KeyVals4} = ResponseMsg4,
    ?assertEqual(
        [],
        KeyVals4
    ),

    ok.

config_update_test(Config) ->
    %% exercise the streaming API config_update
    %% when initiated, the client will be streamed any updates to chain vars
    %% the received payload will contain a list of each modified chainvar and its value
    ConsensusMembers = ?config(consensus_members, Config),
    [GatewayNode1 | _] = ?config(nodes, Config),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),

    Connection = ?config(grpc_connection, Config),
    {Priv, _} = ?config(master_key, Config),

    %% Get a gateway chain & swarm
    GatewayNode1Chain = ct_rpc:call(GatewayNode1, blockchain_worker, blockchain, []),
    GatewayNode1Swarm = ct_rpc:call(GatewayNode1, blockchain_swarm, tid, []),
    Self = self(),
    LocalChain = blockchain_worker:blockchain(),
    LocalSwarm = blockchain_swarm:tid(),

    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.gateway',
        config_update,
        gateway_client_pb
    ),

    %% subscribe to config updates, msg payoad is empty
    grpc_client:send(Stream, #{}),
    %% confirm we got our grpc headers
    {headers, Headers0} = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Headers0: ~p", [Headers0]),
    #{<<":status">> := Headers0HttpStatus} = Headers0,
    ?assertEqual(Headers0HttpStatus, <<"200">>),

    %% update a chain var value and confirm we get its updated value streamed
    Vars = #{sc_grace_blocks => 8, max_open_sc => 4},
    VarTxn = blockchain_txn_vars_v1:new(Vars, 3),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, VarTxn),
    VarTxn1 = blockchain_txn_vars_v1:proof(VarTxn, Proof),

    %% Add block with with txns
    {ok, Block0} = sibyl_ct_utils:add_block(GatewayNode1, GatewayNode1Chain, ConsensusMembers, [
        VarTxn1
    ]),
    ct:pal("Block0: ~p", [Block0]),

    %% Fake gossip block
    ok = ct_rpc:call(GatewayNode1, blockchain_gossip_handler, add_block, [
        Block0,
        GatewayNode1Chain,
        Self,
        GatewayNode1Swarm
    ]),

    %% Wait till the block is gossiped
    ok = sibyl_ct_utils:local_add_and_gossip_fake_blocks(
        2,
        ConsensusMembers,
        LocalSwarm,
        LocalChain,
        Self
    ),
    ok = sibyl_ct_utils:wait_until_local_height(3),

    %% confirm we receive a config update with the two new chain vars
    {data, #{
        height := _Height0,
        block_time := _ResponseBlockTime0,
        block_age := _ResponseBlockAge0,
        msg := {config_update_streamed_resp, #{keys := ConfigUpdateMsg0}}
    }} =
        Data0 = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Data0: ~p", [Data0]),
    ?assertEqual(
        [
            "max_open_sc",
            "sc_grace_blocks"
        ],
        ConfigUpdateMsg0
    ),
    ok.

validators_test(Config) ->
    %% exercise the validators api
    %% client can request to be returned data on one or more random validators
    %% the pubkey and the URI will be returned for each validator
    Connection = ?config(grpc_connection, Config),
    [GatewayNode1 | _] = ?config(nodes, Config),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),
    ConsensusMembers = ?config(consensus_members, Config),
    LocalChain = blockchain_worker:blockchain(),
    LocalSwarm = blockchain_swarm:tid(),

    %% Get a gateway chain, swarm and pubkey_bin
    GatewayNode1Chain = ct_rpc:call(GatewayNode1, blockchain_worker, blockchain, []),
    GatewayNode1Swarm = ct_rpc:call(GatewayNode1, blockchain_swarm, tid, []),
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
            block_time := _ResponseBlockTime1,
            block_age := _ResponseBlockAge1,
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
            block_time := _ResponseBlockTime2,
            block_age := _ResponseBlockAge2,
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
            block_time := _ResponseBlockTime3,
            block_age := _ResponseBlockAge3,
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

version_test(Config) ->
    %% exercise the unary API version
    Connection = ?config(grpc_connection, Config),

    %% use the grpc APIs to get some chain var config vales
    {ok, #{
        headers := Headers1,
        result := #{
            msg := {version, ResponseMsg1},
            height := _ResponseHeight1,
            block_time := _ResponseBlockTime1,
            block_age := _ResponseBlockAge1,
            signature := _ResponseSig1
        } = Result1
    }} = grpc_client:unary(
        Connection,
        #{},
        'helium.gateway',
        'version',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers1]),
    ct:pal("Response Body: ~p", [Result1]),
    #{<<":status">> := HttpStatus1} = Headers1,
    ?assertEqual(HttpStatus1, <<"200">>),
    #{version := Version} = ResponseMsg1,
    ?assertEqual(sibyl_utils:default_version(), Version),
    ok.

%
%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
