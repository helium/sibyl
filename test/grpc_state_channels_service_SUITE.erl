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
    is_valid_sc_test/1,
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
        is_valid_sc_test,
        close_sc_test,
        follow_sc_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(TestCase, Config) ->
    %% setup test dirs
    InitConfig0 = sibyl_ct_utils:init_base_dir_config(?MODULE, TestCase, Config),

    application:ensure_all_started(lager),
    application:ensure_all_started(erlbus),
    application:ensure_all_started(grpcbox),

    InitConfig = sibyl_ct_utils:init_per_testcase(TestCase, InitConfig0),
    Nodes = ?config(nodes, InitConfig),

    LogDir = ?config(log_dir, InitConfig0),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, LogDir}, debug),

    %% start a local blockchain
    #{public := LocalNodePubKey, secret := LocalNodePrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    BaseDir = ?config(base_dir, InitConfig),
    LocalNodeSigFun = libp2p_crypto:mk_sig_fun(LocalNodePrivKey),
    LocalNodeECDHFun = libp2p_crypto:mk_ecdh_fun(LocalNodePrivKey),
    Opts = [
        {key, {LocalNodePubKey, LocalNodeSigFun, LocalNodeECDHFun}},
        {seed_nodes, []},
        {port, 0},
        {num_consensus_members, 7},
        {base_dir, BaseDir}
    ],
    {ok, Sup} = blockchain_sup:start_link(Opts),

    %% connect the local node to the others
    [First | _Rest] = Nodes,

    FirstSwarm = ct_rpc:call(First, blockchain_swarm, swarm, []),
    FirstListenAddr = hd(ct_rpc:call(First, libp2p_swarm, listen_addrs, [FirstSwarm])),
    LocalSwarm = blockchain_swarm:swarm(),
    ct:pal("local node connection to ~p on addr ~p", [First, FirstListenAddr]),
    libp2p_swarm:connect(LocalSwarm, FirstListenAddr),

    %% have other nodes connect to local node, to ensure it is properly connected
    LocalListenAddr = hd(libp2p_swarm:listen_addrs(LocalSwarm)),
    ok = lists:foreach(
        fun(Node) ->
            NodeSwarm = ct_rpc:call(Node, blockchain_swarm, swarm, []),
            ct_rpc:call(Node, libp2p_swarm, connect, [NodeSwarm, LocalListenAddr])
        end,
        Nodes
    ),

    GossipGroup = libp2p_swarm:gossip_group(LocalSwarm),
    sibyl_ct_utils:wait_until(
        fun() ->
            ConnectedAddrs = libp2p_group_gossip:connected_addrs(GossipGroup, all),
            length(ConnectedAddrs) == length(Nodes)
        end,
        50,
        20
    ),

    {ok, SibylSupPid} = sibyl_sup:start_link(),
    %% give time for the mgr to be initialised with chain
    sibyl_ct_utils:wait_until(fun() -> sibyl_mgr:blockchain() /= undefined end),

    Balance = 5000,
    NumConsensusMembers = ?config(num_consensus_members, InitConfig),

    %% accumulate the address of each node
    Addrs = lists:foldl(
        fun(Node, Acc) ->
            Addr = ct_rpc:call(Node, blockchain_swarm, pubkey_bin, []),
            [Addr | Acc]
        end,
        [],
        Nodes
    ),

    ConsensusAddrs = lists:sublist(lists:sort(Addrs), NumConsensusMembers),
    DefaultVars = #{num_consensus_members => NumConsensusMembers},
    ExtraVars = #{
        max_open_sc => 2,
        min_expire_within => 10,
        max_xor_filter_size => 1024 * 100,
        max_xor_filter_num => 5,
        max_subnet_size => 65536,
        min_subnet_size => 8,
        max_subnet_num => 20,
        sc_grace_blocks => 5,
        dc_payload_size => 24
    },

    {InitialVars, _Config} = sibyl_ct_utils:create_vars(maps:merge(DefaultVars, ExtraVars)),

    % Create genesis block
    GenPaymentTxs = [blockchain_txn_coinbase_v1:new(Addr, Balance) || Addr <- Addrs],
    GenDCsTxs = [blockchain_txn_dc_coinbase_v1:new(Addr, Balance) || Addr <- Addrs],
    GenConsensusGroupTx = blockchain_txn_consensus_group_v1:new(ConsensusAddrs, <<"proof">>, 1, 0),

    %% Make one consensus member the owner of all gateways
    GenGwTxns = [
        blockchain_txn_gen_gateway_v1:new(
            Addr,
            hd(ConsensusAddrs),
            h3:from_geo({37.780586, -122.469470}, 13),
            0
        )
        || Addr <- Addrs
    ],

    Txs = InitialVars ++ GenPaymentTxs ++ GenDCsTxs ++ GenGwTxns ++ [GenConsensusGroupTx],
    GenesisBlock = blockchain_block:new_genesis_block(Txs),

    %% tell each node to integrate the genesis block
    lists:foreach(
        fun(Node) ->
            ?assertMatch(
                ok,
                ct_rpc:call(Node, blockchain_worker, integrate_genesis_block, [GenesisBlock])
            )
        end,
        Nodes
    ),

    %% do the same for local node
    blockchain_worker:integrate_genesis_block(GenesisBlock),

    %% wait till each worker gets the gensis block
    ok = lists:foreach(
        fun(Node) ->
            ok = sibyl_ct_utils:wait_until(
                fun() ->
                    C0 = ct_rpc:call(Node, blockchain_worker, blockchain, []),
                    {ok, Height} = ct_rpc:call(Node, blockchain, height, [C0]),
                    ct:pal("node ~p height ~p", [Node, Height]),
                    Height == 1
                end,
                100,
                100
            )
        end,
        Nodes
    ),

    %% wait until the local node has the genesis block
    ok = sibyl_ct_utils:wait_until(fun() ->
            C0 = blockchain_worker:blockchain(),
            {ok, Height} = blockchain:height(C0),
            ct:pal("local node height ~p", [Height]),
            Height == 1
        end, 100, 100),

    ok = sibyl_ct_utils:check_genesis_block(InitConfig, GenesisBlock),
    ConsensusMembers = sibyl_ct_utils:get_consensus_members(InitConfig, ConsensusAddrs),

    %% setup the grpc connection
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 10001),

    [
        {sup, Sup},
        {local_node_pubkey, LocalNodePubKey},
        {local_node_pubkey_bin, libp2p_crypto:pubkey_to_bin(LocalNodePubKey)},
        {local_node_privkey, LocalNodePrivKey},
        {local_node_sigfun, LocalNodeSigFun},
        {consensus_members, ConsensusMembers},
        {sibyl_sup, SibylSupPid},
        {grpc_connection, Connection}
        | InitConfig
    ].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    Connection = ?config(grpc_connection, Config),
    grpc_client:stop_connection(Connection),
    SibylSup = ?config(sibyl_sup, Config),
    application:stop(erlbus),
    application:stop(grpcbox),
    true = erlang:exit(SibylSup, normal),
    sibyl_ct_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
is_valid_sc_test(Config) ->
    %% exercise the unary API is_valid, supply it with an active SC and it should
    %% confirm it is valid
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
    ok = sibyl_ct_utils:wait_until(fun()->
        C = blockchain_worker:blockchain(),
        {ok, Height} = blockchain:height(C),
        ct:pal("local height ~p", [Height]),
        Height == 2
        end, 100, 100),

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

    ActiveSCID = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, []),
    %% pull the active SC from the router node, confirm it has same ID as one from ledger
    %% and then use it to test the is_valid GRPC api
    ActiveSCPB = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc, []),
    ct:pal("ActiveSCPB: ~p", [ActiveSCPB]),
    ActiveSCMap = ?record_to_map(blockchain_state_channel_v1_pb, ActiveSCPB),

    %% use the grpc APIs to confirm the state channel is valid/sane
    {ok, #{
        headers := Headers,
        result := #{
            msg := {is_valid_resp, ResponseMsg},
            height := _ResponseHeight,
            signature := _ResponseSig
        } = Result
    }} = grpc_client:unary(
        Connection,
        #{sc => ActiveSCMap},
        'helium.gateway_state_channels',
        'is_valid',
        gateway_client_pb,
        []
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    ?assertEqual(ResponseMsg#{sc_id := ActiveSCID, valid := true, reason := <<>>}, ResponseMsg),

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
    ok = sibyl_ct_utils:wait_until(fun()->
        C = blockchain_worker:blockchain(),
        {ok, Height} = blockchain:height(C),
        ct:pal("local height ~p", [Height]),
        Height == 2
        end, 100, 100),

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
    ActiveSCID = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, []),
    %% pull the active SC from the router node, we will need it in for our close txn
    ActiveSCPB = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc, []),
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
    {ok, #{headers := Headers, result := #{msg := {close_resp, ResponseMsg}, height := _ResponseHeight, signature := _ResponseSig} = Result}} = grpc_client:unary(
        Connection,
        #{close_txn => SignedTxnMap2},
        'helium.gateway_state_channels',
        'close',
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
    %% and confirm the client receives events relating to its closed status
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
    ok = sibyl_ct_utils:wait_until(fun()->
        C = blockchain_worker:blockchain(),
        {ok, Height} = blockchain:height(C),
        ct:pal("local height ~p", [Height]),
        Height == 2
        end, 100, 100),

    %% Checking that state channel got created properly
    {true, SC1} = check_sc_open(RouterNode, RouterChain, RouterPubkeyBin, ID1),

    %% Checking that state channel got created properly
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
    ActiveSCID = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, []),
    %% pull the active SC from the router node, we will need it in for our close txn
    ActiveSCPB = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc, []),
    ct:pal("ActiveSCPB: ~p", [ActiveSCPB]),

    %% setup a 'follow' streamed connection to server
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.gateway_state_channels',
        follow,
        gateway_client_pb
    ),

    %% setup the follows for the two SCs
    ?assertEqual(ID1, ActiveSCID),
    ok = grpc_client:send(Stream, #{sc_id => ID1, owner => blockchain_ledger_state_channel_v1:owner(SC1)}),
    ok = grpc_client:send(Stream, #{sc_id => ID2, owner => blockchain_ledger_state_channel_v1:owner(SC2)}),
    timer:sleep(5000),
%%    ok = sibyl_ct_utils:wait_until(fun()->
%%        C = blockchain_worker:blockchain(),
%%        {ok, Height} = blockchain:height(C),
%%        ct:pal("local height ~p", [Height]),
%%        Height == 20
%%        end, 100, 100),

    %% Adding fake blocks to get the state channel 1 to expire
    FakeBlocks = 12,
    ok = sibyl_ct_utils:add_and_gossip_fake_blocks(FakeBlocks, ConsensusMembers, RouterNode, RouterSwarm, RouterChain, self()),
    ok = sibyl_ct_utils:wait_until_height(RouterNode, 14),

    %% wait until we see a close txn for SC1
    %% then check for the expected follow msgs
    %% the msgs will have been sent at different block heights and queued up on the client
    receive
        {txn, Txn1} ->
            ?assertEqual(blockchain_txn_state_channel_close_v1, blockchain_txn:type(Txn1)),
            {ok, B1} = ct_rpc:call(RouterNode, sibyl_ct_utils, create_block, [ConsensusMembers, [Txn1]]),
            _ = ct_rpc:call(RouterNode, blockchain_gossip_handler, add_block, [B1, RouterChain, Self, RouterSwarm])
    after 10000 ->
        ct:fail("txn timeout")
    end,

    %% headers are always sent with the first data msg
    {headers, Headers0} = grpc_client:rcv(Stream, 5000),
    ct:pal("Response Headers0: ~p", [Headers0]),
    #{<<":status">> := Headers0HttpStatus} = Headers0,
    ?assertEqual(Headers0HttpStatus, <<"200">>),

    %% we should receive 3 stream msgs for SC1, closable, closing and closed
    {data, #{height := 13, msg := {follow_streamed_resp, Data0FollowMsg}}} = Data0 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data0: ~p", [Data0]),
    #{sc_id := Data0SCID1, close_state := Data0CloseState} = Data0FollowMsg,
    ?assertEqual(ActiveSCID, Data0SCID1),
    ?assertEqual(closable, Data0CloseState),

    {data, #{height := 14, msg := {follow_streamed_resp, Data1FollowMsg}}} = Data1 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data1: ~p", [Data1]),
    #{sc_id := Data1SCID1, close_state := Data1CloseState} = Data1FollowMsg,
    ?assertEqual(ActiveSCID, Data1SCID1),
    ?assertEqual(closing, Data1CloseState),

    {data, #{height := 15, msg := {follow_streamed_resp, Data2FollowMsg}}} = Data2 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data2: ~p", [Data2]),
    #{sc_id := Data2SCID1, close_state := Data2CloseState} = Data2FollowMsg,
    ?assertEqual(ActiveSCID, Data2SCID1),
    ?assertEqual(closed, Data2CloseState),

    %% confirm SC2 is now the active SC
    ActiveSCID2 = ct_rpc:call(RouterNode, blockchain_state_channels_server, active_sc_id, []),
    ct:pal("ActiveSCID2: ~p", [ActiveSCID2]),
    %% check that the ids differ, make sure we have a new SC
    ?assertNotEqual(ActiveSCID, ActiveSCID2),

    %% Adding fake blocks to get state channel 2 to expire
    FakeBlocks2 = 5,
    ok = sibyl_ct_utils:add_and_gossip_fake_blocks(FakeBlocks2, ConsensusMembers, RouterNode, RouterSwarm, RouterChain, self()),
    ok = sibyl_ct_utils:wait_until_height(RouterNode, 20),

    %% wait until we see a close txn for SC1
    %% then check for the expected follow msgs
    %% the msgs will have been sent at different block heights and queued up on the client
    receive
        {txn, Txn2} ->
            ?assertEqual(blockchain_txn_state_channel_close_v1, blockchain_txn:type(Txn2)),
            {ok, B2} = ct_rpc:call(RouterNode, sibyl_ct_utils, create_block, [ConsensusMembers, [Txn2]]),
            _ = ct_rpc:call(RouterNode, blockchain_gossip_handler, add_block, [B2, RouterChain, Self, RouterSwarm])
    after 10000 ->
        ct:fail("txn timeout")
    end,

    {data, #{height := 19, msg := {follow_streamed_resp, Data3FollowMsg}}} = Data3 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data3: ~p", [Data3]),
    #{sc_id := Data3SCID2, close_state := Data3CloseState} = Data3FollowMsg,
    ?assertEqual(ActiveSCID2, Data3SCID2),
    ?assertEqual(Data3CloseState, closable),

    {data, #{height := 20, msg := {follow_streamed_resp, Data4FollowMsg}}} = Data4 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data4: ~p", [Data4]),
    #{sc_id := Data4SCID2, close_state := Data4CloseState} = Data4FollowMsg,
    ?assertEqual(ActiveSCID2, Data4SCID2),
    ?assertEqual(Data4CloseState, closing),

    {data, #{height := 21, msg := {follow_streamed_resp, Data5FollowMsg}}} = Data5 = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Data5: ~p", [Data5]),
    #{sc_id := Data5SCID2, close_state := Data5CloseState} = Data5FollowMsg,
    ?assertEqual(ActiveSCID2, Data5SCID2),
    ?assertEqual(Data5CloseState, closed),

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
    C1 = ID == blockchain_ledger_state_channel_v1:id(SC),
    C2 = RouterPubkeyBin == blockchain_ledger_state_channel_v1:owner(SC),
    {C1 andalso C2, SC}.

check_all_closed([]) ->
    ok;
check_all_closed(IDs) ->
    receive
        {txn, Txn} ->
            check_all_closed([ ID || ID <- IDs, ID /= blockchain_state_channel_v1:id(blockchain_txn_state_channel_close_v1:state_channel(Txn)) ])
    after 10000 ->
              ct:fail("still unclosed ~p", [IDs])
    end.
