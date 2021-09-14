-module(grpc_state_channels_service_SUITE).

-include("sibyl.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("helium_proto/include/blockchain_txn_state_channel_close_v1_pb.hrl").

-define(record_to_map(Rec, Ref),
    maps:from_list(lists:zip(record_info(fields, Rec), tl(tuple_to_list(Ref))))
).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    is_active_sc_test/1,
    is_overpaid_sc_test/1,
    close_sc_test/1,
    follow_sc_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%-include("../include/sibyl.hrl").
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
        is_active_sc_test,
        is_overpaid_sc_test,
        close_sc_test,
        follow_sc_test
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

    %% accumulate the address of each node
    PubKeyBins = lists:foldl(
        fun(Node, Acc) ->
            Addr = ct_rpc:call(Node, blockchain_swarm, pubkey_bin, []),
            [Addr | Acc]
        end,
        [],
        Nodes
    ),

    %% the SC tests use the first two nodes as the gateway and router
    %% for the GRPC group to work we need to ensure these two nodes are connected to each other
    %% in blockchain_ct_utils:init_per_testcase the nodes are connected to a majority of the group
    %% but that does not guarantee these two nodes will be connected
    [RouterNode, GatewayNode | _] = Nodes,
    [RouterNodeAddr, GatewayNodeAddr | _] = PubKeyBins,
    ok = sibyl_ct_utils:wait_until(
        fun() ->
            lists:all(
                fun({Node, AddrToConnectToo}) ->
                    try
                        GossipPeers = ct_rpc:call(Node, blockchain_swarm, gossip_peers, [], 500),
                        ct:pal("~p connected to peers ~p", [Node, GossipPeers]),
                        case
                            lists:member(
                                libp2p_crypto:pubkey_bin_to_p2p(AddrToConnectToo),
                                GossipPeers
                            )
                        of
                            true ->
                                true;
                            false ->
                                ct:pal("~p is not connected to desired peer ~p", [
                                    Node,
                                    AddrToConnectToo
                                ]),
                                Swarm = ct_rpc:call(Node, blockchain_swarm, swarm, [], 500),
                                CRes = ct_rpc:call(
                                    Node,
                                    libp2p_swarm,
                                    connect,
                                    [Swarm, AddrToConnectToo],
                                    500
                                ),
                                ct:pal("Connecting ~p to ~p: ~p", [Node, AddrToConnectToo, CRes]),
                                false
                        end
                    catch
                        _C:_E ->
                            false
                    end
                end,
                [{RouterNode, GatewayNodeAddr}, {GatewayNode, RouterNodeAddr}]
            )
        end,
        200,
        150
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
is_active_sc_test(Config) ->
    %% exercise the unary API is_active, supply it with an active SC and it should
    %% confirm it is active
    Connection = ?config(grpc_connection, Config),
    [RouterNode, GatewayNode1 | _] = ?config(nodes, Config),
    ct:pal("RouterNode: ~p", [RouterNode]),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),
    ConsensusMembers = ?config(consensus_members, Config),

    %% Get router chain, swarm and pubkey_bin
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    RouterPubkeyBin = ct_rpc:call(RouterNode, blockchain_swarm, pubkey_bin, []),

    %% setup meck txn forwarding
    Self = self(),
    ok = sibyl_ct_utils:setup_meck_txn_forwarding(RouterNode, Self),

    %% Create OUI txn
    SignedOUITxn = sibyl_ct_utils:create_oui_txn(1, RouterNode, [], 8),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),

    %% Create state channel open txn
    ID = crypto:strong_rand_bytes(24),
    ExpireWithin = 11,
    Nonce = 1,
    SignedSCOpenTxn = create_sc_open_txn(RouterNode, ID, ExpireWithin, 1, Nonce),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn]),

    %% Add block with oui and sc open txns
    {ok, Block0} = sibyl_ct_utils:add_block(RouterNode, RouterChain, ConsensusMembers, [
        SignedOUITxn,
        SignedSCOpenTxn
    ]),
    ct:pal("Block0: ~p", [Block0]),

    %% Get sc open block hash for verification later
    _SCOpenBlockHash = blockchain_block:hash_block(Block0),

    %% Fake gossip block
    ok = ct_rpc:call(RouterNode, blockchain_gossip_handler, add_block, [
        Block0,
        RouterChain,
        Self,
        RouterSwarm
    ]),

    %% Wait till the block is gossiped
    ok = sibyl_ct_utils:wait_until_local_height(2),

    %% Checking that state channel got created properly
    {true, _SC1} = check_sc_open(RouterNode, RouterChain, RouterPubkeyBin, ID),

    %% Check that the nonce of the sc server is okay
    ok = sibyl_ct_utils:wait_until(
        fun() ->
            {ok, 0} == ct_rpc:call(RouterNode, blockchain_state_channels_server, nonce, [ID])
        end,
        30,
        timer:seconds(1)
    ),

    [ActiveSCID] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_ids, []),
    %% pull the active SC from the router node, confirm it has same ID as one from ledger
    %% and then use it to test the is_valid GRPC api
    [ActiveSCPB] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_scs, []),
    ct:pal("ActiveSCPB: ~p", [ActiveSCPB]),
    SCOwner = blockchain_state_channel_v1:owner(ActiveSCPB),
    SCID = blockchain_state_channel_v1:id(ActiveSCPB),

    %% use the grpc APIs to confirm the state channel is active
    {ok, #{
        headers := Headers1,
        result := #{
            msg := {is_active_resp, ResponseMsg1},
            height := _ResponseHeight1,
            signature := _ResponseSig1
        } = Result1
    }} = grpc_client:unary(
        Connection,
        #{sc_id => SCID, sc_owner => SCOwner},
        'helium.gateway',
        'is_active_sc',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers1]),
    ct:pal("Response Body: ~p", [Result1]),
    #{<<":status">> := HttpStatus1} = Headers1,
    ?assertEqual(HttpStatus1, <<"200">>),
    ?assertEqual(
        ResponseMsg1#{sc_id := ActiveSCID, sc_owner := SCOwner, active := true, sc_expiry_at_block := 12, sc_original_dc_amount := 20},
        ResponseMsg1
    ),

    %% use the grpc APIs to confirm a non existent state channel is not active
    %% expiry at block and original dc amount values for an inactive SC will default to zero
    {ok, #{
        headers := Headers2,
        result := #{
            msg := {is_active_resp, ResponseMsg2},
            height := _ResponseHeight2,
            signature := _ResponseSig2
        } = Result2
    }} = grpc_client:unary(
        Connection,
        #{sc_id => <<"bad_id">>, sc_owner => SCOwner},
        'helium.gateway',
        'is_active_sc',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers2]),
    ct:pal("Response Body: ~p", [Result2]),
    #{<<":status">> := HttpStatus2} = Headers2,
    ?assertEqual(HttpStatus2, <<"200">>),
    ?assertEqual(
        ResponseMsg2#{sc_id := <<"bad_id">>, sc_owner := SCOwner, active := false, sc_expiry_at_block := 0, sc_original_dc_amount := 0},
        ResponseMsg2
    ),
    ok.

is_overpaid_sc_test(Config) ->
    %% exercise the unary API is_overpaid, supply it with an SC details and it should
    %% confirm if it is overpaid or not
    Connection = ?config(grpc_connection, Config),
    [RouterNode, GatewayNode1 | _] = ?config(nodes, Config),
    ct:pal("RouterNode: ~p", [RouterNode]),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),
    ConsensusMembers = ?config(consensus_members, Config),

    %% Get router chain, swarm and pubkey_bin
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    RouterPubkeyBin = ct_rpc:call(RouterNode, blockchain_swarm, pubkey_bin, []),

    %% setup meck txn forwarding
    Self = self(),
    ok = sibyl_ct_utils:setup_meck_txn_forwarding(RouterNode, Self),

    %% Create OUI txn
    SignedOUITxn = sibyl_ct_utils:create_oui_txn(1, RouterNode, [], 8),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),

    %% Create state channel open txn
    ID = crypto:strong_rand_bytes(24),
    ExpireWithin = 11,
    Nonce = 1,
    SignedSCOpenTxn = create_sc_open_txn(RouterNode, ID, ExpireWithin, 1, Nonce),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn]),

    %% Add block with oui and sc open txns
    {ok, Block0} = sibyl_ct_utils:add_block(RouterNode, RouterChain, ConsensusMembers, [
        SignedOUITxn,
        SignedSCOpenTxn
    ]),
    ct:pal("Block0: ~p", [Block0]),

    %% Get sc open block hash for verification later
    _SCOpenBlockHash = blockchain_block:hash_block(Block0),

    %% Fake gossip block
    ok = ct_rpc:call(RouterNode, blockchain_gossip_handler, add_block, [
        Block0,
        RouterChain,
        Self,
        RouterSwarm
    ]),

    %% Wait till the block is gossiped
    ok = sibyl_ct_utils:wait_until_local_height(2),

    %% Checking that state channel got created properly
    {true, _SC1} = check_sc_open(RouterNode, RouterChain, RouterPubkeyBin, ID),

    %% Check that the nonce of the sc server is okay
    ok = sibyl_ct_utils:wait_until(
        fun() ->
            {ok, 0} == ct_rpc:call(RouterNode, blockchain_state_channels_server, nonce, [ID])
        end,
        30,
        timer:seconds(1)
    ),

    [ActiveSCID] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_ids, []),
    %% pull the active SC from the router node, confirm it has same ID as one from ledger
    %% and then use it to test the is_valid GRPC api
    [ActiveSCPB] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_scs, []),
    ct:pal("ActiveSCPB: ~p", [ActiveSCPB]),
    SCOwner = blockchain_state_channel_v1:owner(ActiveSCPB),
    SCID = blockchain_state_channel_v1:id(ActiveSCPB),

    %% use the grpc APIs to confirm the state channel is overpaid
    {ok, #{
        headers := Headers1,
        result := #{
            msg := {is_overpaid_resp, ResponseMsg1},
            height := _ResponseHeight1,
            signature := _ResponseSig1
        } = Result1
    }} = grpc_client:unary(
        Connection,
        #{sc_id => SCID, sc_owner => SCOwner, total_dcs => 10},
        'helium.gateway',
        'is_overpaid_sc',
        gateway_client_pb,
        []
    ),
    ct:pal("Response1 Headers1: ~p", [Headers1]),
    ct:pal("Response1 Body1: ~p", [Result1]),
    #{<<":status">> := HttpStatus1} = Headers1,
    ?assertEqual(HttpStatus1, <<"200">>),
    ?assertEqual(
        ResponseMsg1#{sc_id := ActiveSCID, sc_owner := SCOwner, overpaid := false},
        ResponseMsg1
    ),

    {ok, #{
        headers := Headers2,
        result := #{
            msg := {is_overpaid_resp, ResponseMsg2},
            height := _ResponseHeight2,
            signature := _ResponseSig2
        } = Result2
    }} = grpc_client:unary(
        Connection,
        #{sc_id => SCID, sc_owner => SCOwner, total_dcs => 30},
        'helium.gateway',
        'is_overpaid_sc',
        gateway_client_pb,
        []
    ),

    ct:pal("Response Headers2: ~p", [Headers2]),
    ct:pal("Response Body2: ~p", [Result2]),
    #{<<":status">> := HttpStatus2} = Headers2,
    ?assertEqual(HttpStatus2, <<"200">>),
    ?assertEqual(
        ResponseMsg2#{sc_id := ActiveSCID, sc_owner := SCOwner, overpaid := true},
        ResponseMsg2
    ),

    ok.

close_sc_test(Config) ->
    %% exercise the unary API close, supply it with an active SC ID and its owner
    %% A close SC txn will be submitted to the chain and the resulting SC will be closed
    Connection = ?config(grpc_connection, Config),
    LocalNodePubKeyBin = ?config(local_node_pubkey_bin, Config),
    LocalNodeSigFun = ?config(local_node_sigfun, Config),
    [RouterNode, GatewayNode1 | _] = ?config(nodes, Config),
    ct:pal("RouterNode: ~p", [RouterNode]),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),
    ConsensusMembers = ?config(consensus_members, Config),

    %% Get router chain, swarm and pubkey_bin
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    RouterPubkeyBin = ct_rpc:call(RouterNode, blockchain_swarm, pubkey_bin, []),

    %% Check that the meck txn forwarding works
    Self = self(),
    ok = sibyl_ct_utils:setup_meck_txn_forwarding(RouterNode, Self),

    %% do same mecking for the local node
    ok = meck_test_util:forward_submit_txn(self()),

    %% Create OUI txn
    SignedOUITxn = sibyl_ct_utils:create_oui_txn(1, RouterNode, [], 8),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),

    %% Create state channel open txn
    ID = crypto:strong_rand_bytes(24),
    ExpireWithin = 11,
    Nonce = 1,
    SignedSCOpenTxn = create_sc_open_txn(RouterNode, ID, ExpireWithin, 1, Nonce),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn]),

    %% Add block with oui and sc open txns
    {ok, Block0} = sibyl_ct_utils:add_block(RouterNode, RouterChain, ConsensusMembers, [
        SignedOUITxn,
        SignedSCOpenTxn
    ]),
    ct:pal("Block0: ~p", [Block0]),

    %% Get sc open block hash for verification later
    _SCOpenBlockHash = blockchain_block:hash_block(Block0),

    %% Fake gossip block
    ok = ct_rpc:call(RouterNode, blockchain_gossip_handler, add_block, [
        Block0,
        RouterChain,
        Self,
        RouterSwarm
    ]),

    %% Wait till the block is gossiped
    ok = sibyl_ct_utils:wait_until_local_height(2),

    %% Checking that state channel got created properly
    {true, _SC1} = check_sc_open(RouterNode, RouterChain, RouterPubkeyBin, ID),

    %% Check that the nonce of the sc server is okay
    ok = sibyl_ct_utils:wait_until(
        fun() ->
            {ok, 0} == ct_rpc:call(RouterNode, blockchain_state_channels_server, nonce, [ID])
        end,
        30,
        timer:seconds(1)
    ),

    %% get the open state channels ID
    [ActiveSCID] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_ids, []),
    %% pull the active SC from the router node, we will need it in for our close txn
    [ActiveSCPB] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_scs, []),
    ct:pal("ActiveSCPB: ~p", [ActiveSCPB]),

    %% setup the close txn, first as records
    SCClose = blockchain_state_channel_v1:state(closed, ActiveSCPB),
    SignedSCClose = blockchain_state_channel_v1:sign(SCClose, LocalNodeSigFun),
    Txn = blockchain_txn_state_channel_close_v1:new(SignedSCClose, LocalNodePubKeyBin),
    SignedTxn = blockchain_txn_state_channel_close_v1:sign(Txn, LocalNodeSigFun),

    %% then convert the records to maps ( current grpc client only supports maps )
    SignedSCCloseMap = ?record_to_map(blockchain_state_channel_v1_pb, SignedSCClose),
    SignedTxnMap = ?record_to_map(blockchain_txn_state_channel_close_v1_pb, SignedTxn),
    SignedTxnMap2 = SignedTxnMap#{state_channel := SignedSCCloseMap},

    %% use the grpc APIs to close the SC
    {ok, #{
        headers := Headers,
        result := #{
            msg := {close_resp, ResponseMsg},
            height := _ResponseHeight,
            signature := _ResponseSig
        } = Result
    }} = grpc_client:unary(
        Connection,
        #{close_txn => SignedTxnMap2},
        'helium.gateway',
        'close_sc',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg#{sc_id := ActiveSCID, response := <<"ok">>}, ResponseMsg),

    %% confirm we see the close txn
    ok = check_all_closed([ActiveSCID]),

    ok.

follow_sc_test(Config) ->
    %% exercise the streaming API follow, supply it with SC IDs we want to follow
    %% and confirm the client receives events relating to the closed status of each
    %% closable event will be sent when a followed SCs expire at height equals current block height
    %% closing event will be sent when a followed SC is not yet closed but current block height > SC expire at height and within the SC's grace period
    %% closed event will be sent when a followed SC is closed
    %% dispute event will be sent when a followed SC enters a dispute state
    Connection = ?config(grpc_connection, Config),
    _LocalNodePubKeyBin = ?config(local_node_pubkey_bin, Config),
    _LocalNodeSigFun = ?config(local_node_sigfun, Config),
    [RouterNode, GatewayNode1 | _] = ?config(nodes, Config),
    ct:pal("RouterNode: ~p", [RouterNode]),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),
    ConsensusMembers = ?config(consensus_members, Config),

    %% Get router chain, swarm and pubkey_bin
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),
    RouterPubkeyBin = ct_rpc:call(RouterNode, blockchain_swarm, pubkey_bin, []),

    %% Get local chain, swarm and pubkey_bin
    LocalChain = blockchain_worker:blockchain(),
    LocalSwarm = blockchain_swarm:swarm(),
    _LocalPubkeyBin = blockchain_swarm:pubkey_bin(),

    %% Check that the meck txn forwarding works
    Self = self(),
    ok = sibyl_ct_utils:setup_meck_txn_forwarding(RouterNode, Self),

    %% do same mecking for the local node
    ok = meck_test_util:forward_submit_txn(self()),

    %% Create OUI txn
    SignedOUI1Txn = sibyl_ct_utils:create_oui_txn(1, RouterNode, [], 8),
    ct:pal("SignedOUI1Txn: ~p", [SignedOUI1Txn]),

    SignedOUI2Txn = sibyl_ct_utils:create_oui_txn(2, RouterNode, [], 8),
    ct:pal("SignedOUI2Txn: ~p", [SignedOUI2Txn]),

    %% Create state channel open txn for oui 1
    ID1 = crypto:strong_rand_bytes(24),
    ExpireWithin1 = 12,
    Nonce1 = 1,
    SignedSCOpenTxn1 = create_sc_open_txn(RouterNode, ID1, ExpireWithin1, 1, Nonce1),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn1]),

    %% Create state channel open txn for oui 2
    ID2 = crypto:strong_rand_bytes(24),
    ExpireWithin2 = 18,
    Nonce2 = 2,
    SignedSCOpenTxn2 = create_sc_open_txn(RouterNode, ID2, ExpireWithin2, 2, Nonce2),
    ct:pal("SignedSCOpenTxn: ~p", [SignedSCOpenTxn2]),

    %% Add block with oui and sc open txns
    {ok, Block0} = sibyl_ct_utils:add_block(RouterNode, RouterChain, ConsensusMembers, [
        SignedOUI1Txn,
        SignedSCOpenTxn1,
        SignedOUI2Txn,
        SignedSCOpenTxn2
    ]),
    ct:pal("Block0: ~p", [Block0]),
    %% Fake gossip block
    ok = ct_rpc:call(RouterNode, blockchain_gossip_handler, add_block, [
        Block0,
        RouterChain,
        Self,
        RouterSwarm
    ]),

    %% Wait till the block is gossiped
    ok = sibyl_ct_utils:wait_until_height(RouterNode, 2),
    ok = sibyl_ct_utils:wait_until_local_height(2),

    %% Checking that state channel 1 got created properly
    {true, SC1} = check_sc_open(RouterNode, RouterChain, RouterPubkeyBin, ID1),
    %% Checking that state channel 2 got created properly
    {true, SC2} = check_sc_open(RouterNode, RouterChain, RouterPubkeyBin, ID2),

    %% Check that the nonce of the sc server is okay
    ok = sibyl_ct_utils:wait_until(
        fun() ->
            {ok, 0} == ct_rpc:call(RouterNode, blockchain_state_channels_server, nonce, [ID1])
        end,
        30,
        timer:seconds(1)
    ),

    %% get the open state channels ID
    [ActiveSCID] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_ids, []),
    %% pull the active SC from the router node, we will need it in for our close txn
    [ActiveSCPB] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_scs, []),
    ct:pal("ActiveSCPB: ~p", [ActiveSCPB]),

    %% setup a 'follow' streamed connection to server
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.gateway',
        follow_sc,
        gateway_client_pb
    ),

    %% setup the follows for the two SCs
    ?assertEqual(ID1, ActiveSCID),
    ok = grpc_client:send(Stream, #{
        sc_id => ID1,
        sc_owner => blockchain_ledger_state_channel_v2:owner(SC1)
    }),
    ok = grpc_client:send(Stream, #{
        sc_id => ID2,
        sc_owner => blockchain_ledger_state_channel_v2:owner(SC2)
    }),
    ok = timer:sleep(timer:seconds(2)),

    %% Adding fake blocks to get the state channel 1 to hit the various follow events
    %% we will push the height 1 block beyond the height at which we expect the event
    %% to be triggered at
    ok = sibyl_ct_utils:add_and_gossip_fake_blocks(
        11,
        ConsensusMembers,
        RouterNode,
        RouterSwarm,
        RouterChain,
        Self
    ),
    ok = sibyl_ct_utils:wait_until_height(RouterNode, 13),
    ok = sibyl_ct_utils:wait_until_local_height(13),

    %% confirm we got our grpc headers
    {headers, Headers0} = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Headers0: ~p", [Headers0]),
    #{<<":status">> := Headers0HttpStatus} = Headers0,
    ?assertEqual(Headers0HttpStatus, <<"200">>),

    %%
    %% we should receive 3 stream msgs for SC1, closable, closing and closed
    %%

    %% closable
    {data, #{height := 13, msg := {follow_streamed_resp, Data0FollowMsg}}} =
        Data0 = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Data0: ~p", [Data0]),
    #{sc_id := Data0SCID1, close_state := Data0CloseState} = Data0FollowMsg,
    ?assertEqual(ActiveSCID, Data0SCID1),
    ?assertEqual(close_state_closable, Data0CloseState),

    %% add additional blocks to trigger the closing state
    ok = sibyl_ct_utils:add_and_gossip_fake_blocks(
        1,
        ConsensusMembers,
        RouterNode,
        RouterSwarm,
        RouterChain,
        Self
    ),
    ok = sibyl_ct_utils:wait_until_height(RouterNode, 14),
    ok = sibyl_ct_utils:wait_until_local_height(14),

    %% closing
    {data, #{height := 14, msg := {follow_streamed_resp, Data1FollowMsg}}} =
        Data1 = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Data1: ~p", [Data1]),
    #{sc_id := Data1SCID1, close_state := Data1CloseState} = Data1FollowMsg,
    ?assertEqual(ActiveSCID, Data1SCID1),
    ?assertEqual(close_state_closing, Data1CloseState),

    %% wait until we see a close txn for SC1
    %% then push it to the router node and have it gossip it around
    %% this will force the closed event to be triggered at that block height
    receive
        {txn, Txn1} ->
            ?assertEqual(blockchain_txn_state_channel_close_v1, blockchain_txn:type(Txn1)),
            {ok, B1} = sibyl_ct_utils:create_block(
                ConsensusMembers,
                [Txn1]
            ),
            _ = blockchain_gossip_handler:add_block(
                B1,
                LocalChain,
                Self,
                LocalSwarm
            )
    after 10000 -> ct:fail("txn timeout")
    end,
    ok = sibyl_ct_utils:wait_until_local_height(15),

    %% we expect the closed at block height 15, push 1 beyond and confirm the height in the payload is as expected
    ok = sibyl_ct_utils:local_add_and_gossip_fake_blocks(
        1,
        ConsensusMembers,
        LocalSwarm,
        LocalChain,
        Self
    ),
    ok = sibyl_ct_utils:wait_until_height(RouterNode, 16),
    ok = sibyl_ct_utils:wait_until_local_height(16),

    {data, #{height := 15, msg := {follow_streamed_resp, Data2FollowMsg}}} =
        Data2 = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Data2: ~p", [Data2]),
    #{sc_id := Data2SCID1, close_state := Data2CloseState} = Data2FollowMsg,
    ?assertEqual(ActiveSCID, Data2SCID1),
    ?assertEqual(close_state_closed, Data2CloseState),

    %%
    %% SC1 is now closed, SC2 should be the active SC
    %%
    [ActiveSCID2] = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_ids, []),
    ct:pal("ActiveSCID2: ~p", [ActiveSCID2]),
    %% check that the ids differ, make sure we have a new SC
    ?assertNotEqual(ActiveSCID, ActiveSCID2),

    %% Adding fake blocks to get state channel 2 to expire
    ok = sibyl_ct_utils:local_add_and_gossip_fake_blocks(
        8,
        ConsensusMembers,
        LocalSwarm,
        LocalChain,
        Self
    ),
    ok = sibyl_ct_utils:wait_until_height(RouterNode, 24),
    ok = sibyl_ct_utils:wait_until_local_height(24),

    %%
    %% we should receive 3 stream msgs for SC2, closable, closing and closed
    %%

    {data, #{height := 19, msg := {follow_streamed_resp, Data3FollowMsg}}} =
        Data3 = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Data3: ~p", [Data3]),
    #{sc_id := Data3SCID2, close_state := Data3CloseState} = Data3FollowMsg,
    ?assertEqual(ActiveSCID2, Data3SCID2),
    ?assertEqual(Data3CloseState, close_state_closable),

    ok = sibyl_ct_utils:local_add_and_gossip_fake_blocks(
        1,
        ConsensusMembers,
        LocalSwarm,
        LocalChain,
        Self
    ),
    ok = sibyl_ct_utils:wait_until_height(RouterNode, 25),
    ok = sibyl_ct_utils:wait_until_local_height(25),

    {data, #{height := 20, msg := {follow_streamed_resp, Data4FollowMsg}}} =
        Data4 = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Data4: ~p", [Data4]),
    #{sc_id := Data4SCID2, close_state := Data4CloseState} = Data4FollowMsg,
    ?assertEqual(ActiveSCID2, Data4SCID2),
    ?assertEqual(Data4CloseState, close_state_closing),

    %% wait until we see a close txn for SC2
    %% then push it to the router node and have it gossip it around
    %% this will force the closed event to be triggered at that block height
    receive
        {txn, Txn2} ->
            ?assertEqual(blockchain_txn_state_channel_close_v1, blockchain_txn:type(Txn2)),
            {ok, B2} = sibyl_ct_utils:create_block(
                ConsensusMembers,
                [Txn2]
            ),
            _ = blockchain_gossip_handler:add_block(
                B2,
                LocalChain,
                Self,
                LocalSwarm
            )
    after 10000 -> ct:fail("txn timeout")
    end,
    %% we expect the closed at block height 21, push 1 beyond and confirm the height in the payload is as expected
    ok = sibyl_ct_utils:local_add_and_gossip_fake_blocks(
        1,
        ConsensusMembers,
        LocalSwarm,
        LocalChain,
        Self
    ),
    ok = sibyl_ct_utils:wait_until_height(RouterNode, 27),
    ok = sibyl_ct_utils:wait_until_local_height(27),

    {data, #{height := 26, msg := {follow_streamed_resp, Data5FollowMsg}}} =
        Data5 = grpc_client:rcv(Stream, 8000),
    ct:pal("Response Data5: ~p", [Data5]),
    #{sc_id := Data5SCID2, close_state := Data5CloseState} = Data5FollowMsg,
    ?assertEqual(ActiveSCID2, Data5SCID2),
    ?assertEqual(Data5CloseState, close_state_closed),

    ok.

%
%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
create_sc_open_txn(RouterNode, ID, Expiry, OUI, Nonce) ->
    {ok, RouterPubkey, RouterSigFun, _} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    SCOpenTxn = blockchain_txn_state_channel_open_v1:new(
        ID,
        RouterPubkeyBin,
        Expiry,
        OUI,
        Nonce,
        20
    ),
    blockchain_txn_state_channel_open_v1:sign(SCOpenTxn, RouterSigFun).

check_sc_open(RouterNode, RouterChain, RouterPubkeyBin, ID) ->
    RouterLedger = blockchain:ledger(RouterChain),
    {ok, SC} = ct_rpc:call(RouterNode, blockchain_ledger_v1, find_state_channel, [
        ID,
        RouterPubkeyBin,
        RouterLedger
    ]),
    C1 = ID == blockchain_ledger_state_channel_v2:id(SC),
    C2 = RouterPubkeyBin == blockchain_ledger_state_channel_v2:owner(SC),
    {C1 andalso C2, SC}.

check_all_closed([]) ->
    ok;
check_all_closed(IDs) ->
    receive
        {txn, Txn} ->
            check_all_closed([
                ID
                || ID <- IDs,
                   ID /=
                       blockchain_state_channel_v1:id(
                           blockchain_txn_state_channel_close_v1:state_channel(Txn)
                       )
            ])
    after 10000 -> ct:fail("still unclosed ~p", [IDs])
    end.
