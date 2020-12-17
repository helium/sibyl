-module(grpc_SUITE).

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
    Config0 = test_utils:init_base_dir_config(?MODULE, TestCase, Config),
    LogDir = ?config(log_dir, Config0),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, LogDir}, debug),

    application:ensure_all_started(gun),
    application:ensure_all_started(throttle),
    application:ensure_all_started(erlbus),
    application:ensure_all_started(grpcbox),

    Config1 = test_utils:init_per_testcase(TestCase, Config0),

    sibyl_sup:start_link(),
    %% give time for the mgr to be initialised with chain
    test_utils:wait_until(fun() -> sibyl_mgr:blockchain() =/= undefined end),

    Config1.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config),
    grpc:stop_server(grpc),
    catch exit(whereis(sibyl_sup)).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

routing_updates_with_initial_msg_test(Config) ->
    %% add a bunch of routing data and confirm client receives streaming updates for each update
    ConsensusMembers = ?config(consensus_members, Config),
    Swarm = ?config(swarm, Config),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    [_, {Payer, {_, PayerPrivKey, _}} | _] = ConsensusMembers,
    SigFun = libp2p_crypto:mk_sig_fun(PayerPrivKey),

    meck:new(blockchain_txn_oui_v1, [no_link, passthrough]),
    meck:expect(blockchain_ledger_v1, check_dc_or_hnt_balance, fun(_, _, _, _) -> ok end),
    meck:expect(blockchain_ledger_v1, debit_fee, fun(_, _, _, _) -> ok end),

    OUI1 = 1,
    Addresses0 = [libp2p_swarm:pubkey_bin(Swarm)],
    {Filter, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn0 = blockchain_txn_oui_v1:new(OUI1, Payer, Addresses0, Filter, 8),
    SignedOUITxn0 = blockchain_txn_oui_v1:sign(OUITxn0, SigFun),

    %% confirm we have no routing data at this point
    %% then add the OUI block
    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn0]),
    _ = blockchain_gossip_handler:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    Routing0 = blockchain_ledger_routing_v1:new(
        OUI1,
        Payer,
        Addresses0,
        Filter,
        <<0:25/integer-unsigned-big,
            (blockchain_ledger_routing_v1:subnet_size_to_mask(8)):23/integer-unsigned-big>>,
        0
    ),
    ?assertEqual({ok, Routing0}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    %% setup the grpc connection and open a stream
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 10001),
    %% routes_v1 = service, stream_route_updates = RPC call, routes_v1 = decoder, ie the PB generated encode/decode file
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.validator',
        routing,
        validator_client_pb
    ),
    %% the stream requires an empty msg to be sent in order to initialise the service
    %% TODO - any way around having to send the empty msg ?
    grpc_client:send(Stream, #{height => 1}),

    %% NOTE: we established this connection *after* the above route update, so there should be a single route on the ledger
    %% and as we established the connection after, we will not get a streamed update msg for this route change

    %%    {ok, Stream} = grpcbox_routes_v1_service_client:stream_route_updates(#{}),

    %% NOTE: the server will send the headers first before any data msg
    %%       but will only send them at the point of the first data msg being sent
    %% the headers will come in first, so assert those
    {ok, Headers} = test_utils:wait_for(
        fun() ->
            case grpc_client:get(Stream) of
                empty ->
                    false;
                {headers, Headers} ->
                    {true, Headers}
            end
        end
    ),

    %%    {ok, Headers} = grpcbox_client:recv_headers(Stream),
    ct:pal("Response Headers: ~p", [Headers]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),

    %% now check for and assert the first data msg sent by the server,
    %% In this case the first data msg will be a route_v1_update msg containing all current routes

    %% this is because the client specified a height of 1
    %% this can be used by the client to tell the server that it has all known routes at the specified height
    %% so if the client already has known routes up to a known height and doesnt need the same
    %% data back, then the client can use this header to tell the server
    %% the server will then only respond with all routes if the routes have been modified
    %% since the presented height

    %% get all expected routes from the ledger to compare against the msg streamed to client
    {ok, ExpRoutes} = blockchain_ledger_v1:get_routes(Ledger),
    ct:pal("Expected routes ~p", [ExpRoutes]),

    %% confirm the received first data msg matches above routes
    {data, RouteRespPB} = grpc_client:rcv(Stream, 5000),
    ct:pal("Route Update: ~p", [RouteRespPB]),
    assert_route_update(RouteRespPB, ExpRoutes),

    %% add a new route - and then confirm we get a streamed update of same
    #{public := NewPubKey, secret := _PrivKey} = libp2p_crypto:generate_keys(ed25519),
    Addresses1 = [libp2p_crypto:pubkey_to_bin(NewPubKey)],
    OUITxn2 = blockchain_txn_routing_v1:update_router_addresses(OUI1, Payer, Addresses1, 1),
    SignedOUITxn2 = blockchain_txn_routing_v1:sign(OUITxn2, SigFun),
    {ok, Block1} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn2]),
    _ = blockchain_gossip_handler:add_block(Block1, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 3} == blockchain:height(Chain) end),

    Routing1 = blockchain_ledger_routing_v1:new(
        OUI1,
        Payer,
        Addresses1,
        Filter,
        <<0:25/integer-unsigned-big,
            (blockchain_ledger_routing_v1:subnet_size_to_mask(8)):23/integer-unsigned-big>>,
        1
    ),
    ?assertEqual({ok, Routing1}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    %% confirm we received an event associated with the above change
    {data, RouteUpdate1} = grpc_client:rcv(Stream, 5000),
    ct:pal("Route Update: ~p", [RouteUpdate1]),
    assert_route_update(RouteUpdate1, [Routing1]),

    %% add a new route - and then confirm we get a streamed update of same
    OUITxn3 = blockchain_txn_routing_v1:request_subnet(OUI1, Payer, 32, 2),
    SignedOUITxn3 = blockchain_txn_routing_v1:sign(OUITxn3, SigFun),
    {Filter2, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn4 = blockchain_txn_routing_v1:update_xor(OUI1, Payer, 0, Filter2, 3),
    SignedOUITxn4 = blockchain_txn_routing_v1:sign(OUITxn4, SigFun),
    {Filter2a, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn4a = blockchain_txn_routing_v1:new_xor(OUI1, Payer, Filter2a, 4),
    SignedOUITxn4a = blockchain_txn_routing_v1:sign(OUITxn4a, SigFun),

    {ok, Block2} = blockchain_test_utils:create_block(ConsensusMembers, [
        SignedOUITxn3,
        SignedOUITxn4,
        SignedOUITxn4a
    ]),
    _ = blockchain_gossip_handler:add_block(Block2, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 4} == blockchain:height(Chain) end),

    {ok, Routing2} = blockchain_ledger_v1:find_routing(OUI1, Ledger),

    %% confirm we received an event associated with the above change
    {ok, RouteUpdate2} = test_utils:wait_for(
        fun() ->
            case grpc_client:get(Stream) of
                empty ->
                    false;
                {data, Data} ->
                    {true, Data}
            end
        end
    ),
    ct:pal("Route Update: ~p", [RouteUpdate2]),
    assert_route_update(RouteUpdate2, [Routing2]),

    meck:unload(blockchain_txn_oui_v1),
    ok.

routing_updates_without_initial_msg_test(Config) ->
    %% add a bunch of routing data and confirm client receives streaming updates for each update
    ConsensusMembers = ?config(consensus_members, Config),
    Swarm = ?config(swarm, Config),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    [_, {Payer, {_, PayerPrivKey, _}} | _] = ConsensusMembers,
    SigFun = libp2p_crypto:mk_sig_fun(PayerPrivKey),

    meck:new(blockchain_txn_oui_v1, [no_link, passthrough]),
    meck:expect(blockchain_ledger_v1, check_dc_or_hnt_balance, fun(_, _, _, _) -> ok end),
    meck:expect(blockchain_ledger_v1, debit_fee, fun(_, _, _, _) -> ok end),

    OUI1 = 1,
    Addresses0 = [libp2p_swarm:pubkey_bin(Swarm)],
    {Filter, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn0 = blockchain_txn_oui_v1:new(OUI1, Payer, Addresses0, Filter, 8),
    SignedOUITxn0 = blockchain_txn_oui_v1:sign(OUITxn0, SigFun),

    %% confirm we have no routing data at this point
    %% then add the OUI block
    ?assertEqual({error, not_found}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    {ok, Block0} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn0]),
    _ = blockchain_gossip_handler:add_block(Block0, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 2} == blockchain:height(Chain) end),

    Routing0 = blockchain_ledger_routing_v1:new(
        OUI1,
        Payer,
        Addresses0,
        Filter,
        <<0:25/integer-unsigned-big,
            (blockchain_ledger_routing_v1:subnet_size_to_mask(8)):23/integer-unsigned-big>>,
        0
    ),
    ?assertEqual({ok, Routing0}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    %% get current height and add 1 and use for client header
    {ok, CurHeight0} = blockchain:height(Chain),
    ClientHeaderHeight = CurHeight0 + 1,

    %% setup the grpc connection and open a stream
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 10001),
    %% routes_v1 = service, stream_route_updates = RPC call, routes_v1 = decoder, ie the PB generated encode/decode file
    {ok, Stream} = grpc_client:new_stream(
        Connection,
        'helium.validator',
        routing,
        validator_client_pb
    ),
    %% the stream requires an empty msg to be sent in order to initialise the service
    grpc_client:send(Stream, #{height => ClientHeaderHeight}),

    %% NOTE: we established this connection *after* the above route update, so there should be a single route on the ledger
    %% and as we established the connection after, we will not get a streamed update msg for this route change

    %% now check for and assert the first data msg sent by the server,
    %% as the stream was opened with the x-client-height header present with a value of 3
    %% the server will not have sent us the initial dataset of routes
    %% as the height specified in the header is equal to the height the routes were last updated
    %% as such when we check for streamed msgs at this point it should return empty

    %%    %% sleep to give the router_update_server to spawn
    timer:sleep(1000),
    empty = grpc_client:get(Stream),

    %% we will only receive our first data msg after the next route update

    %% add a new route - and then confirm we get a streamed update of same
    #{public := NewPubKey, secret := _PrivKey} = libp2p_crypto:generate_keys(ed25519),
    Addresses1 = [libp2p_crypto:pubkey_to_bin(NewPubKey)],
    OUITxn2 = blockchain_txn_routing_v1:update_router_addresses(OUI1, Payer, Addresses1, 1),
    SignedOUITxn2 = blockchain_txn_routing_v1:sign(OUITxn2, SigFun),
    {ok, Block1} = blockchain_test_utils:create_block(ConsensusMembers, [SignedOUITxn2]),
    _ = blockchain_gossip_handler:add_block(Block1, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 3} == blockchain:height(Chain) end),

    Routing1 = blockchain_ledger_routing_v1:new(
        OUI1,
        Payer,
        Addresses1,
        Filter,
        <<0:25/integer-unsigned-big,
            (blockchain_ledger_routing_v1:subnet_size_to_mask(8)):23/integer-unsigned-big>>,
        1
    ),
    ?assertEqual({ok, Routing1}, blockchain_ledger_v1:find_routing(OUI1, Ledger)),

    %% NOTE: the server will send the headers first before any data msg
    %%       but will only send them at the point of the first data msg being sent
    %% the headers will come in first, so assert those
    {ok, Headers} = test_utils:wait_for(
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

    %% confirm we received an event associated with the above change
    {ok, RouteUpdate1} = test_utils:wait_for(
        fun() ->
            case grpc_client:get(Stream) of
                empty ->
                    false;
                {data, Data} ->
                    {true, Data}
            end
        end
    ),
    ct:pal("Route Update: ~p", [RouteUpdate1]),
    assert_route_update(RouteUpdate1, [Routing1]),

    %% add a new route - and then confirm we get a streamed update of same
    OUITxn3 = blockchain_txn_routing_v1:request_subnet(OUI1, Payer, 32, 2),
    SignedOUITxn3 = blockchain_txn_routing_v1:sign(OUITxn3, SigFun),
    {Filter2, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn4 = blockchain_txn_routing_v1:update_xor(OUI1, Payer, 0, Filter2, 3),
    SignedOUITxn4 = blockchain_txn_routing_v1:sign(OUITxn4, SigFun),
    {Filter2a, _} = xor16:to_bin(xor16:new([], fun xxhash:hash64/1)),
    OUITxn4a = blockchain_txn_routing_v1:new_xor(OUI1, Payer, Filter2a, 4),
    SignedOUITxn4a = blockchain_txn_routing_v1:sign(OUITxn4a, SigFun),

    {ok, Block2} = blockchain_test_utils:create_block(ConsensusMembers, [
        SignedOUITxn3,
        SignedOUITxn4,
        SignedOUITxn4a
    ]),
    _ = blockchain_gossip_handler:add_block(Block2, Chain, self(), blockchain_swarm:swarm()),

    ok = test_utils:wait_until(fun() -> {ok, 4} == blockchain:height(Chain) end),

    {ok, Routing2} = blockchain_ledger_v1:find_routing(OUI1, Ledger),

    %% confirm we received an event associated with the above change
    {ok, RouteUpdate2} = test_utils:wait_for(
        fun() ->
            case grpc_client:get(Stream) of
                empty ->
                    false;
                {data, Data} ->
                    {true, Data}
            end
        end
    ),
    ct:pal("Route Update: ~p", [RouteUpdate2]),
    assert_route_update(RouteUpdate2, [Routing2]),

    meck:unload(blockchain_txn_oui_v1),
    ok.

%%route_updates_negative_test(_Config) ->
%% TODO
%%    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
assert_route_update(RouteUpdate, ExpectedRoutes) ->
    #{routings := Routes, signature := _Sig, height := _Height} = RouteUpdate,
    lists:foldl(
        fun(R, Acc) -> assert_route(R, lists:nth(Acc, ExpectedRoutes)) end,
        1,
        Routes
    ).

assert_route_response(Response, ExpectedRoutes) ->
    #{routings := Routes, signature := _Sig, height := _Height} = Response,
    lists:foldl(
        fun(R, Acc) -> assert_route(R, lists:nth(Acc, ExpectedRoutes)) end,
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
    ).
