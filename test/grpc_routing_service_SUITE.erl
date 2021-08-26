-module(grpc_routing_service_SUITE).

-include("sibyl.hrl").
-include("../src/grpc/autogen/server/gateway_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    routing_updates_with_initial_msg_test/1,
    routing_updates_without_initial_msg_test/1
]).

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
    Config0 = sibyl_ct_utils:init_base_dir_config(?MODULE, TestCase, Config),
    LogDir = ?config(log_dir, Config0),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, LogDir}, debug),

    application:ensure_all_started(grpcbox),

    Config1 = sibyl_ct_utils:init_per_testcase(TestCase, Config0),
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
    LocalGossipPeers = blockchain_swarm:gossip_peers(),
    ct:pal("local node connected to ~p peers", [length(LocalGossipPeers)]),

    %% now that all nodes are up and connected, start sibyl
    {ok, SibylSupPid} = sibyl_sup:start_link(),
    %% give time for the mgr to be initialised with chain
    ok = sibyl_ct_utils:wait_until(
        fun() ->
            sibyl_mgr:blockchain() =/= undefined
        end,
        100,
        100
    ),

    %% setup come onchain requirements for the local node
    Swarm = blockchain_swarm:swarm(),
    ConsensusMembers = ?config(consensus_members, Config1),
    Chain = blockchain_worker:blockchain(),
    ct:pal("localchain : ~p", [Chain]),
    Ledger = blockchain:ledger(Chain),
    [{_Addr, PayerPubKey, PayerSigFun} | _] = ConsensusMembers,
    PayerPubKeyBin = libp2p_crypto:pubkey_to_bin(PayerPubKey),

    meck:new(blockchain_txn_oui_v1, [no_link, passthrough]),
    meck:expect(blockchain_ledger_v1, check_dc_or_hnt_balance, fun(_, _, _, _) -> ok end),
    meck:expect(blockchain_ledger_v1, debit_fee, fun(_, _, _, _) -> ok end),

    OUI1 = 1,
    Addresses0 = [libp2p_swarm:pubkey_bin(Swarm)],
    {Filter, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn0 = blockchain_txn_oui_v1:new(OUI1, PayerPubKeyBin, Addresses0, Filter, 8),
    SignedOUITxn0 = blockchain_txn_oui_v1:sign(OUITxn0, PayerSigFun),

    %% confirm we have no routing data at this point
    %% then add the OUI block
    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    {ok, Block0} = sibyl_ct_utils:create_block(ConsensusMembers, [SignedOUITxn0]),
    _ = blockchain_gossip_handler:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),

    ok = sibyl_ct_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    Routing0 = blockchain_ledger_routing_v1:new(
        OUI1,
        PayerPubKeyBin,
        Addresses0,
        Filter,
        <<0:25/integer-unsigned-big,
            (blockchain_ledger_routing_v1:subnet_size_to_mask(8)):23/integer-unsigned-big>>,
        0
    ),
    ?assertEqual({ok, Routing0}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    %% wait until the ledger hook for the OUI above has fired and been processed by sibyl mgr
    ok = sibyl_ct_utils:wait_until(fun() ->
        2 == sibyl_mgr:get_last_modified(?EVENT_ROUTING_UPDATES_END)
    end),

    %% setup the grpc connection and open a stream
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 10001),
    %% routes_v1 = service, stream_route_updates = RPC call, routes_v1 = decoder, ie the PB generated encode/decode file
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.gateway',
        routing,
        gateway_client_pb
    ),

    [
        {sup, Sup},
        {sibyl_sup, SibylSupPid},
        {payer, PayerPubKeyBin},
        {payer_sig_fun, PayerSigFun},
        {chain, Chain},
        {ledger, Ledger},
        {grpc_connection, Connection},
        {grpc_stream, Stream},
        {oui1, OUI1},
        {filter, Filter}
        | Config1
    ].

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    meck:unload(blockchain_txn_oui_v1),
    meck:unload(blockchain_ledger_v1),
    SibylSup = ?config(sibyl_sup, Config),
    application:stop(grpcbox),
    true = erlang:exit(SibylSup, normal),
    sibyl_ct_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

routing_updates_with_initial_msg_test(Config) ->
    ConsensusMembers = ?config(consensus_members, Config),
    Chain = ?config(chain, Config),
    Ledger = ?config(ledger, Config),
    Payer = ?config(payer, Config),
    SigFun = ?config(payer_sig_fun, Config),
    Connection = ?config(grpc_connection, Config),
    Stream = ?config(grpc_stream, Config),
    OUI1 = ?config(oui1, Config),

    %% send the initial msg from the client with its safe height value
    grpc_client:send(Stream, #{height => 1}),

    %% we expect to receive a response containing all the added routes from the init_per_testcase step
    %% we will receive this as our client height value is less that the last modified height for route updates
    %% we wont get streaming updates for those as the grpc connection was established after those routes were added

    %% NOTE: the server will send the headers first before any data msg
    %%       but will only send them at the point of the first data msg being sent
    %% the headers will come in first, so assert those
    {ok, Headers} = sibyl_ct_utils:wait_for(
        fun() ->
            case grpc_client:get(Stream) of
                empty ->
                    false;
                {headers, Headers} ->
                    {true, Headers}
            end
        end
    ),

    ct:pal("Response Headers: ~p", [Headers]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),

    %% now check for and assert the first data msg sent by the server,
    %% In this case the first data msg will be a route_v1_update msg containing all current routes

    %% get all expected routes from the ledger to compare against the msg streamed to client
    {ok, ExpRoutes} = blockchain_ledger_v1:get_routes(Ledger),
    ct:pal("Expected routes ~p", [ExpRoutes]),

    %% confirm the received first data msg matches above routes
    {data, RouteRespPB} = grpc_client:rcv(Stream, 5000),
    ct:pal("Route Update: ~p", [RouteRespPB]),
    assert_route_update(RouteRespPB, ExpRoutes),

    %% update the existing route - confirm we get a streamed update of the updated route - should remain a single route
    #{public := PubKey1, secret := _PrivKey1} = libp2p_crypto:generate_keys(ed25519),
    Addresses1 = [libp2p_crypto:pubkey_to_bin(PubKey1)],
    OUITxn1 = blockchain_txn_routing_v1:update_router_addresses(OUI1, Payer, Addresses1, 1),
    SignedOUITxn1 = blockchain_txn_routing_v1:sign(OUITxn1, SigFun),
    {ok, Block1} = sibyl_ct_utils:create_block(ConsensusMembers, [SignedOUITxn1]),
    _ = blockchain_gossip_handler:add_block(Block1, Chain, self(), blockchain_swarm:swarm()),

    ok = sibyl_ct_utils:wait_until(fun() -> {ok, 3} == blockchain:height(Chain) end),

    %% get expected route data from the ledger to compare against the msg streamed to client
    %% confirm the ledger route has the updated addresses
    {ok, [ExpRoute1] = ExpRoutes1} = blockchain_ledger_v1:get_routes(Ledger),
    ct:pal("Expected routes 1 ~p", [ExpRoutes1]),
    ?assertEqual(blockchain_ledger_routing_v1:addresses(ExpRoute1), Addresses1),

    %% confirm the received routes matches that in the ledger
    {data, Routes1} = grpc_client:rcv(Stream, 5000),
    ct:pal("Route Update: ~p", [Routes1]),
    assert_route_update(Routes1, ExpRoutes1),

    %% add a new route - and then confirm we get a streamed update of same containing the two routes
    OUI2 = 2,
    #{public := PubKey2, secret := _PrivKey2} = libp2p_crypto:generate_keys(ed25519),
    Addresses2 = [libp2p_crypto:pubkey_to_bin(PubKey2)],
    {Filter2, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn2 = blockchain_txn_oui_v1:new(OUI2, Payer, Addresses2, Filter2, 8),
    SignedOUITxn2 = blockchain_txn_oui_v1:sign(OUITxn2, SigFun),
    {ok, Block2} = sibyl_ct_utils:create_block(ConsensusMembers, [SignedOUITxn2]),
    _ = blockchain_gossip_handler:add_block(Block2, Chain, self(), blockchain_swarm:swarm()),

    ok = sibyl_ct_utils:wait_until(fun() -> {ok, 4} == blockchain:height(Chain) end),

    %% get expected route data from the ledger to compare against the msg streamed to client
    {ok, ExpRoutes2} = blockchain_ledger_v1:get_routes(Ledger),
    ct:pal("Expected routes 1 ~p", [ExpRoutes2]),

    {data, Routes2} = grpc_client:rcv(Stream, 5000),
    ct:pal("Route Update: ~p", [Routes2]),
    assert_route_update(Routes2, ExpRoutes2),

    grpc_client:stop_stream(Stream),
    grpc_client:stop_connection(Connection),

    ok.

routing_updates_without_initial_msg_test(Config) ->
    ConsensusMembers = ?config(consensus_members, Config),
    Chain = ?config(chain, Config),
    Ledger = ?config(ledger, Config),
    Payer = ?config(payer, Config),
    SigFun = ?config(payer_sig_fun, Config),
    Connection = ?config(grpc_connection, Config),
    Stream = ?config(grpc_stream, Config),
    OUI1 = ?config(oui1, Config),

    %% get current height and add 1 and use for client header
    {ok, CurHeight0} = blockchain:height(Chain),
    ClientHeaderHeight = CurHeight0 + 1,

    %% the stream requires an empty msg to be sent in order to initialise the service
    grpc_client:send(Stream, #{height => ClientHeaderHeight}),

    %% we do not expect to receive a response containing all the added routes from the init_per_testcase step
    %% this is because the client supplied a height value greater than the height at which routes were last modified
    %% we wont get streaming updates for those as the grpc connection was established after those routes were added

    %% give a lil time for the handler to spawn on the peer and then confirm we get the grpc headers
    %% we will only receive our first data msg after the next route update
    timer:sleep(500),
    {ok, Headers1} = sibyl_ct_utils:wait_for(
        fun() ->
            case grpc_client:get(Stream) of
                empty ->
                    false;
                {headers, Headers} ->
                    {true, Headers}
            end
        end
    ),
    ct:pal("Response Headers: ~p", [Headers1]),
    #{<<":status">> := HttpStatus} = Headers1,
    ?assertEqual(HttpStatus, <<"200">>),

    %% update the existing route - confirm we get a streamed update of the updated route - should remain a single route
    #{public := PubKey1, secret := _PrivKey1} = libp2p_crypto:generate_keys(ed25519),
    Addresses1 = [libp2p_crypto:pubkey_to_bin(PubKey1)],
    ct:pal("NewAddresses1: ~p", [Addresses1]),
    OUITxn1 = blockchain_txn_routing_v1:update_router_addresses(OUI1, Payer, Addresses1, 1),
    SignedOUITxn1 = blockchain_txn_routing_v1:sign(OUITxn1, SigFun),
    {ok, Block1} = sibyl_ct_utils:create_block(ConsensusMembers, [SignedOUITxn1]),
    _ = blockchain_gossip_handler:add_block(Block1, Chain, self(), blockchain_swarm:swarm()),

    ok = sibyl_ct_utils:wait_until(fun() -> {ok, 3} == blockchain:height(Chain) end),

    %% get expected route data from the ledger to compare against the msg streamed to client
    %% confirm the ledger route has the updated addresses
    {ok, [ExpRoute1] = ExpRoutes1} = blockchain_ledger_v1:get_routes(Ledger),
    ct:pal("Expected routes 1 ~p", [ExpRoutes1]),
    ?assertEqual(blockchain_ledger_routing_v1:addresses(ExpRoute1), Addresses1),

    %% confirm the received routes matches that in the ledger
    {data, Routes1} = grpc_client:rcv(Stream, 5000),
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
