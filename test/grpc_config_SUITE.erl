-module(grpc_config_SUITE).

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
    config_update_test/1
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
        config_update_test
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
    {error, #{
        error_type := grpc,
        trailers := #{<<"grpc-status">> := <<"2">>}
    }} =
        _Result3 = grpc_client:unary(
            Connection,
            #{keys => ["key1", "key2", "key3", "key4", "key5", "key6"]},
            'helium.gateway',
            'config',
            gateway_client_pb,
            []
        ),
    ok.

config_update_test(Config) ->
    %% exercise the streaming API config_update
    %% when initiated, the client will be streamed notifications of updated chain vars
    %% the received payload will contain a list of each modified chainvar
    %% no values will be returned to avoid unnecessary data transfer to light GWs
    %% instead a client can pull the updated value using the unary config API
    %% should it be interested in the updated var
    ConsensusMembers = ?config(consensus_members, Config),
    [GatewayNode1 | _] = ?config(nodes, Config),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),

    Connection = ?config(grpc_connection, Config),
    {Priv, _} = ?config(master_key, Config),

    %% Get a gateway chain & swarm
    GatewayNode1Chain = ct_rpc:call(GatewayNode1, blockchain_worker, blockchain, []),
    GatewayNode1Swarm = ct_rpc:call(GatewayNode1, blockchain_swarm, swarm, []),
    Self = self(),
    LocalChain = blockchain_worker:blockchain(),
    LocalSwarm = blockchain_swarm:swarm(),

    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.gateway',
        config_update,
        gateway_client_pb
    ),

    %% subscribe to config updates, msg payoad is empty

    grpc_client:send(Stream, #{msg => {config_update_req, #{}}}),
    %% confirm we got our grpc headers
    {headers, Headers0} = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Headers0: ~p", [Headers0]),
    #{<<":status">> := Headers0HttpStatus} = Headers0,
    ?assertEqual(Headers0HttpStatus, <<"200">>),

    %% update a chain var value and confirm we get notified of it being modified
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
    {data, #{height := _Height0, msg := {config_update_streamed_resp, #{keys := ConfigUpdateMsg0}}}} =
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
%
%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
