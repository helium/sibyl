-module(grpc_txn_SUITE).

-include("sibyl.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").
-include_lib("helium_proto/include/blockchain_txn_pb.hrl").

-define(record_to_map(Rec, Ref),
    maps:from_list(lists:zip(record_info(fields, Rec), tl(tuple_to_list(Ref))))
).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    submit_test/1
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
        submit_test
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
submit_test(Config) ->
    %% exercise the unary API config, supply it with a list of keys
    %% and confirm it returns correct chain val values for each
    Connection = ?config(grpc_connection, Config),
    ConsensusMembers = ?config(consensus_members, Config),
    [{_Addr, PayerPubKey, PayerSigFun} | _] = ConsensusMembers,
    PayerPubKeyBin = libp2p_crypto:pubkey_to_bin(PayerPubKey),
    Chain = blockchain_worker:blockchain(),

    %% use the txn APIs to submit a new txn
    %% in this case a new route
    OUI1 = 1,
    #{public := PubKey1, secret := _PrivKey1} = libp2p_crypto:generate_keys(ed25519),
    Addresses1 = [libp2p_crypto:pubkey_to_bin(PubKey1)],
    {Filter1, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn1 = blockchain_txn_oui_v1:new(OUI1, PayerPubKeyBin, Addresses1, Filter1, 8),
    SignedOUITxn1 = blockchain_txn_oui_v1:sign(OUITxn1, PayerSigFun),
    SignedOUITxn1Map = ?record_to_map(blockchain_txn_oui_v1_pb, SignedOUITxn1),
    ct:pal("txn as map ~p", [SignedOUITxn1Map]),
    {ok, #{
        headers := Headers1,
        result := #{
            msg := {submit_txn_resp, ResponseMsg1},
            height := _ResponseHeight1,
            block_time := _ResponseBlockTime1,
            block_age := _ResponseBlockAge1,
            signature := _ResponseSig1
        } = Result1
    }} = grpc_client:unary(
        Connection,
        #{txn => #{txn => {oui, SignedOUITxn1Map}}},
        'helium.gateway',
        'submit_txn',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers1]),
    ct:pal("Response Body: ~p", [Result1]),
    #{<<":status">> := HttpStatus1} = Headers1,
    ?assertEqual(HttpStatus1, <<"200">>),
    #{key := Txn1Key, validator := Txn1Validator} = ResponseMsg1,

    %% query the txn and check its status
    {ok, #{
        headers := Headers2,
        result := #{
            msg := {query_txn_resp, ResponseMsg2},
            height := _ResponseHeight2,
            block_time := _ResponseBlockTime2,
            block_age := _ResponseBlockAge2,
            signature := _ResponseSig2
        } = Result2
    }} = grpc_client:unary(
        Connection,
        #{key => Txn1Key},
        'helium.gateway',
        'query_txn',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers2]),
    ct:pal("Response Body: ~p", [Result2]),
    #{<<":status">> := HttpStatus2} = Headers2,
    ?assertEqual(HttpStatus2, <<"200">>),
    #{status := pending, details := <<>>, acceptors := [], rejectors := []} = ResponseMsg2,

    %% make a block with the previously submitted txn
    %% force it to clear
    %% and then check its status again
    {ok, Block0} = sibyl_ct_utils:create_block(ConsensusMembers, [SignedOUITxn1]),
    _ = blockchain_gossip_handler:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),
    sibyl_ct_utils:wait_until_local_height(2),

    %% requery the txn and check its status
    {ok, #{
        headers := Headers3,
        result := #{
            msg := {query_txn_resp, ResponseMsg3},
            height := _ResponseHeight3,
            block_time := _ResponseBlockTime3,
            block_age := _ResponseBlockAge3,
            signature := _ResponseSig3
        } = Result3
    }} = grpc_client:unary(
        Connection,
        #{key => Txn1Key},
        'helium.gateway',
        'query_txn',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers3]),
    ct:pal("Response Body: ~p", [Result3]),
    #{<<":status">> := HttpStatus3} = Headers3,
    ?assertEqual(HttpStatus3, <<"200">>),

    %%TODO: details here represents the block in which the txn clears
    %% it should NOTE be zero
    #{status := cleared, details := <<"0">>, acceptors := [], rejectors := []} = ResponseMsg3,
    ok.

%
%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
