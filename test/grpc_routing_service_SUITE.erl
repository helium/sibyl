-module(grpc_routing_service_SUITE).

-include("sibyl.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    routing_updates_with_initial_msg_test/1,
    routing_updates_without_initial_msg_test/1
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
        routing_updates_with_initial_msg_test,
        routing_updates_without_initial_msg_test
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

    %% wait till each worker gets the genesis block
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

    %% wait until sibyl mgr gets initialised with the chain
    {ok, SibylSupPid} = sibyl_sup:start_link(),
    sibyl_ct_utils:wait_until(fun() -> sibyl_mgr:blockchain() /= undefined end),

    %% setup an OUI
    [RouterNode, GatewayNode1 | _] = Nodes,
    ct:pal("RouterNode: ~p", [RouterNode]),
    ct:pal("GatewayNode1: ~p", [GatewayNode1]),

    %% Get router chain, swarm and pubkey_bin
    RouterChain = ct_rpc:call(RouterNode, blockchain_worker, blockchain, []),
    RouterSwarm = ct_rpc:call(RouterNode, blockchain_swarm, swarm, []),

    %% setup the meck txn forwarding
    Self = self(),
    ok = sibyl_ct_utils:setup_meck_txn_forwarding(RouterNode, Self),

    %% do same mecking for the local node
    ok = meck_test_util:forward_submit_txn(self()),

    %% Create OUI txn
    SignedOUITxn = sibyl_ct_utils:create_oui_txn(1, RouterNode, [], 8),
    ct:pal("SignedOUITxn: ~p", [SignedOUITxn]),
    %% Add block with oui
    {ok, Block0} = sibyl_ct_utils:add_block(RouterNode, RouterChain, ConsensusMembers, [
        SignedOUITxn
    ]),
    ct:pal("Block0: ~p", [Block0]),

    %% Fake gossip block
    ok = ct_rpc:call(RouterNode, blockchain_gossip_handler, add_block, [
        Block0,
        RouterChain,
        Self,
        RouterSwarm
    ]),

    %% Wait till the block is gossiped to our local node
    ok = sibyl_ct_utils:wait_until_local_height(2),

    %% setup the grpc connection and open a stream
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 10001),
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.gateway_routing',
        routing,
        gateway_client_pb
    ),

    [
        {sup, Sup},
        {local_node_pubkey, LocalNodePubKey},
        {local_node_pubkey_bin, libp2p_crypto:pubkey_to_bin(LocalNodePubKey)},
        {local_node_privkey, LocalNodePrivKey},
        {local_node_sigfun, LocalNodeSigFun},
        {consensus_members, ConsensusMembers},
        {sibyl_sup, SibylSupPid},
        {grpc_connection, Connection},
        {grpc_stream, Stream}
        | InitConfig
    ].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    SibylSup = ?config(sibyl_sup, Config),
    application:stop(erlbus),
    application:stop(grpcbox),
    true = erlang:exit(SibylSup, normal),
    sibyl_ct_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
routing_updates_with_initial_msg_test(Config) ->
    %%
    %% subscribe to the routing data and supply an initial height value less than the height at which
    %% the route data was last modified
    %% the server wil then return the full list of current routes, as it sees the client data as potentiall stale
    %% server will subsequently send route updates when routing data is modified/added to
    %%
    [RouterNode1, RouterNode2 | _] = ?config(nodes, Config),
    ConsensusMembers = ?config(consensus_members, Config),
    Connection = ?config(grpc_connection, Config),
    Stream = ?config(grpc_stream, Config),

    %% Get router chain, swarm and pubkey_bin
    RouterChain = ct_rpc:call(RouterNode1, blockchain_worker, blockchain, []),
    RouterSwarm = ct_rpc:call(RouterNode1, blockchain_swarm, swarm, []),

    LocalChain = blockchain_worker:blockchain(),
    LocalLedger = blockchain:ledger(LocalChain),

    %% send the initial msg from the client with its safe height value
    grpc_client:send(Stream, #{height => 1}),

    %% we expect to receive a response containing all the added routes from the init_per_testcase step
    %% we will receive this as our client height value is less that the last modified height for route updates
    %% we wont get streaming updates for those as the grpc connection was established after those routes were added

    %% NOTE: the server will send the headers first before any data msg
    %%       but will only send them at the point of the first data msg being sent
    %% the headers will come in first, so assert those
    {headers, Headers} = grpc_client:rcv(Stream, 15000),

    ct:pal("Response Headers: ~p", [Headers]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),

    %% now check for and assert the first data msg sent by the server,
    %% In this case the first data msg will be a route_v1_update msg containing all current routes

    %% get all expected routes from the ledger to compare against the msg streamed to client
    {ok, ExpRoutes} = blockchain_ledger_v1:get_routes(LocalLedger),
    ct:pal("Expected routes ~p", [ExpRoutes]),

    %% confirm the received first data msg matches above routes
    {data, RouteRespPB} = grpc_client:rcv(Stream, 5000),
    ct:pal("Route Update: ~p", [RouteRespPB]),
    assert_route_update(RouteRespPB, ExpRoutes),

    %% update the existing route - confirm we get a streamed update of the updated route - should remain a single route
    RouterPubkeyBin2 = ct_rpc:call(RouterNode2, blockchain_swarm, pubkey_bin, []),
    NewAddresses1 = [RouterPubkeyBin2],
    ct:pal("New Addressses1: ~p", [NewAddresses1]),
    UpdateOUITxn1 = update_oui_address_txn(1, RouterNode1, NewAddresses1, 1),

    %% Add block with oui
    {ok, Block1} = sibyl_ct_utils:add_block(RouterNode1, RouterChain, ConsensusMembers, [
        UpdateOUITxn1
    ]),
    ct:pal("Block1: ~p", [Block1]),

    %% Fake gossip block
    ok = ct_rpc:call(RouterNode1, blockchain_gossip_handler, add_block, [
        Block1,
        RouterChain,
        self(),
        RouterSwarm
    ]),

    %% Wait till the block is gossiped
    ok = sibyl_ct_utils:wait_until_local_height(3),

    %% get expected route data from the ledger to compare against the msg streamed to client
    %% confirm the ledger route has the updated addresses
    {ok, [ExpRoute1] = ExpRoutes1} = blockchain_ledger_v1:get_routes(LocalLedger),
    ct:pal("Expected routes 1 ~p", [ExpRoutes1]),
    ?assertEqual(blockchain_ledger_routing_v1:addresses(ExpRoute1), NewAddresses1),

    %% confirm the received routes matches that in the ledger
    {data, Routes1} = grpc_client:rcv(Stream, 15000),
    ct:pal("Route Update: ~p", [Routes1]),
    assert_route_update(Routes1, ExpRoutes1),

    %%
    %% add a new route - and then confirm we get a streamed update of same containing the two routes
    %%

    %% Create the OUI txn
    SignedOUI2Txn = sibyl_ct_utils:create_oui_txn(2, RouterNode1, [], 8),
    ct:pal("SignedOUI2Txn: ~p", [SignedOUI2Txn]),
    %% Add block with oui
    {ok, Block2} = sibyl_ct_utils:add_block(RouterNode1, RouterChain, ConsensusMembers, [
        SignedOUI2Txn
    ]),
    ct:pal("Block2: ~p", [Block2]),

    %% Fake gossip block
    ok = ct_rpc:call(RouterNode1, blockchain_gossip_handler, add_block, [
        Block2,
        RouterChain,
        self(),
        RouterSwarm
    ]),

    %% Wait till the block is gossiped to our local node
    ok = sibyl_ct_utils:wait_until_local_height(4),

    %% get expected route data from the ledger to compare against the msg streamed to client
    {ok, ExpRoutes2} = blockchain_ledger_v1:get_routes(LocalLedger),
    ct:pal("Expected routes 1 ~p", [ExpRoutes2]),

    {data, Routes2} = grpc_client:rcv(Stream, 15000),
    ct:pal("Route Update: ~p", [Routes2]),
    assert_route_update(Routes2, ExpRoutes2),

    grpc_client:stop_stream(Stream),
    grpc_client:stop_connection(Connection),

    ok.

routing_updates_without_initial_msg_test(Config) ->
    %%
    %% subscribe to the routing data and supply an initial height value equal to the current chain height
    %% in doing so we are telling the server we are up to data with the current route data and
    %% thus it will not send the initial full list of routes
    %% server will only send route updates when routing data is subsequently modified/added to
    %%
    [RouterNode1, RouterNode2 | _] = ?config(nodes, Config),
    ConsensusMembers = ?config(consensus_members, Config),
    Connection = ?config(grpc_connection, Config),
    Stream = ?config(grpc_stream, Config),

    %% Get router chain, swarm and pubkey_bin
    RouterChain = ct_rpc:call(RouterNode1, blockchain_worker, blockchain, []),
    RouterSwarm = ct_rpc:call(RouterNode1, blockchain_swarm, swarm, []),

    LocalChain = blockchain_worker:blockchain(),
    LocalLedger = blockchain:ledger(LocalChain),

    %% get current height and add 1 and use for client header
    {ok, CurHeight0} = blockchain:height(LocalChain),
    ct:pal("curheight0: ~p", [CurHeight0]),
    ClientHeaderHeight = CurHeight0 + 1,

    %% send the initial msg from the client with its safe height value
    grpc_client:send(Stream, #{height => ClientHeaderHeight}),

    %% we do not expect to receive a response containing all the added routes from the init_per_testcase step
    %% this is because the client supplied a height value greater than the height at which routes were last modified
    %% we wont get streaming updates for those as the grpc connection was established after those routes were added

    %% give a lil time for the handler to spawn on the peer and then confirm we get no msgs from the handler
    %% we will only receive our first data msg after the next route update
    timer:sleep(200),
    empty = grpc_client:get(Stream),

    %% update the existing route - confirm we get a streamed update of the updated route - should remain a single route
    RouterPubkeyBin2 = ct_rpc:call(RouterNode2, blockchain_swarm, pubkey_bin, []),
    NewAddresses1 = [RouterPubkeyBin2],
    ct:pal("New Addressses1: ~p", [NewAddresses1]),
    UpdateOUITxn1 = update_oui_address_txn(1, RouterNode1, NewAddresses1, 1),

    %% Add block with oui
    {ok, Block1} = sibyl_ct_utils:add_block(RouterNode1, RouterChain, ConsensusMembers, [
        UpdateOUITxn1
    ]),
    ct:pal("Block1: ~p", [Block1]),

    %% Fake gossip block
    ok = ct_rpc:call(RouterNode1, blockchain_gossip_handler, add_block, [
        Block1,
        RouterChain,
        self(),
        RouterSwarm
    ]),

    %% Wait till the block is gossiped
    ok = sibyl_ct_utils:wait_until_local_height(3),

    %% get expected route data from the ledger to compare against the msg streamed to client
    %% confirm the ledger route has the updated addresses
    {ok, [ExpRoute1] = ExpRoutes1} = blockchain_ledger_v1:get_routes(LocalLedger),
    ct:pal("Expected routes 1 ~p", [ExpRoutes1]),
    ?assertEqual(blockchain_ledger_routing_v1:addresses(ExpRoute1), NewAddresses1),

    %% NOTE: the server will send the headers first before any data msg
    %%       but will only send them at the point of the first data msg being sent
    %% the headers will come in first, so assert those
    {headers, Headers1} = grpc_client:rcv(Stream, 15000),
    ct:pal("Response Headers: ~p", [Headers1]),
    #{<<":status">> := HttpStatus} = Headers1,
    ?assertEqual(HttpStatus, <<"200">>),

    %% confirm the received routes matches that in the ledger
    {data, Routes1} = grpc_client:rcv(Stream, 15000),
    ct:pal("Route Update: ~p", [Routes1]),
    assert_route_update(Routes1, ExpRoutes1),

    grpc_client:stop_stream(Stream),
    grpc_client:stop_connection(Connection),

    ok.

%
%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
assert_route_update(
    #{
        msg := {routing_streamed_resp, ResponseMsg},
        height := _ResponseHeight,
        signature := _ResponseSig
    } = _RouteUpdate,
    ExpectedRoutes
) ->
    #{routings := Routes} = ResponseMsg,
    lists:foldl(
        fun(R, Acc) ->
            assert_route(R, lists:nth(Acc, ExpectedRoutes)),
            Acc + 1
        end,
        1,
        Routes
    ).

assert_route(Route, ExpectedRoute) ->
    ?assertEqual(blockchain_ledger_routing_v1:oui(ExpectedRoute), maps:get(oui, Route)),
    ?assertEqual(
        blockchain_ledger_routing_v1:owner(ExpectedRoute),
        maps:get(owner, Route)
    ),
    ?assertEqual(
        blockchain_ledger_routing_v1:filters(ExpectedRoute),
        maps:get(filters, Route)
    ),
    ?assertEqual(
        blockchain_ledger_routing_v1:subnets(ExpectedRoute),
        maps:get(subnets, Route)
    ),
    %% validate the addresses
    ExpectedRouterPubKeyAddresses = blockchain_ledger_routing_v1:addresses(ExpectedRoute),
    Addresses = maps:get(addresses, Route),
    lists:foreach(
        fun(Address) -> validate_address(ExpectedRouterPubKeyAddresses, Address) end,
        Addresses
    ).

%% somewhat pointless this validation but there ya go...
validate_address(ExpectedRouterPubKeyAddresses, #{pub_key := PubKey, uri := URI}) ->
    ?assert(lists:member(PubKey, ExpectedRouterPubKeyAddresses)),
    #{host := _IP, port := Port, scheme := Scheme} = uri_string:parse(URI),
    ?assert(is_integer(Port)),
    ?assert((Scheme =:= <<"http">> orelse Scheme =:= <<"https">>)).


update_oui_address_txn(OUI, RouterNode, NewAddresses, Nonce) ->
    {ok, RouterPubkey, RouterSigFun, _} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    OUITxn1 = blockchain_txn_routing_v1:update_router_addresses(OUI, RouterPubkeyBin, NewAddresses, Nonce),
    blockchain_txn_routing_v1:sign(OUITxn1, RouterSigFun).


