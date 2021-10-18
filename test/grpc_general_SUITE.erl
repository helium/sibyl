-module(grpc_general_SUITE).

-include("sibyl.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-define(record_to_map(Rec, Ref),
    maps:from_list(lists:zip(record_info(fields, Rec), tl(tuple_to_list(Ref))))
).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    config_test/1
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
        config_test
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
config_test(Config) ->
    %% exercise the unary API config, supply it with a list of keys
    %% and confirm it returns correct chain val values for each
    Connection = ?config(grpc_connection, Config),

    %% use the grpc APIs to confirm the state channel is active
%%    {ok, #{
%%        headers := Headers1,
%%        result := #{
%%            msg := {config_resp, ResponseMsg1},
%%            height := _ResponseHeight1,
%%            signature := _ResponseSig1
%%        } = Result1
%%    }} = grpc_client:unary(
    Res = grpc_client:unary(
        Connection,
        #{keys => [<<"sc_grace_blocks">>, <<"dc_payload_size">>]},
        'helium.gateway',
        'config',
        gateway_client_pb,
        []
    ),
    ct:pal("Response: ~p", [Res]),
%%    ct:pal("Response Headers: ~p", [Headers1]),
%%    ct:pal("Response Body: ~p", [Result1]),
%%    #{<<":status">> := HttpStatus1} = Headers1,
%%    ?assertEqual(HttpStatus1, <<"200">>),
%%    #{result := KeyVals} = ResponseMsg1,
%%    ?assertEqual(
%%        [#{key => <<"sc_grace_blocks">>, val => 5}, #{key => <<"dc_payload_size">>, val => 24}],
%%        KeyVals
%%    ),
    ?assertEqual(1, 0),
    ok.

%
%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
