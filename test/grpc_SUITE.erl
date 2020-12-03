-module(grpc_SUITE).

-include("sibyl.hrl").

-define(CLIENT_REF_NAME, <<"x-client-id">>).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    get_routes_test/1,
    route_updates_test/1
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
        get_routes_test,
        route_updates_test
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

    Config1 = test_utils:init_per_testcase(TestCase, Config0),

    sibyl_sup:start_link(),
    %% give time for the mgr to be initialised with chain
    test_utils:wait_until(fun() -> sibyl_mgr:blockchain() =/= undefined end),

    Config1.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(TestCase, Config) ->
    test_utils:end_per_testcase(TestCase, Config).

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

get_routes_test(Config) ->
    %% verify the grpc get request to pull all routing data
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

    %% connect via grpc and get the current route data
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 10000),
    {ok, #{headers := Headers, result := Result} = _Resp} = routes_v1_client:get_routes(
        Connection,
        #{},
        []
    ),
    ct:pal("Response Headers: ~p", [Headers]),
    ct:pal("Response Body: ~p", [Result]),
    #{<<":status">> := HttpStatus} = Headers,
    ?assertEqual(HttpStatus, <<"200">>),
    assert_route_response(Result, [Routing0]),

    %% get the routes again, this time present the client last height header
    %% we will set this to a height equal to the current height
    %% we should get a 304 not modified response
    %% TODO - Add this support

    ok.

route_updates_test(Config) ->
    %% add a bunch of routing data and confirm client receives streaming updates for each update
    ConsensusMembers = ?config(consensus_members, Config),
    Swarm = ?config(swarm, Config),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    [_, {Payer, {_, PayerPrivKey, _}} | _] = ConsensusMembers,
    SigFun = libp2p_crypto:mk_sig_fun(PayerPrivKey),

    %% setup the grpc connection and open a stream
    %% the stream requires an empty msg to be sent in order to initialise the service
    %% TODO - any way around having to send the empty msg ?
    {ok, Connection} = grpc_client:connect(tcp, "localhost", 10000),
    {ok, Stream} = grpc_client:new_stream(Connection, routes_v1, stream_route_updates, routes_v1),
    grpc_client:send(Stream, #{}),

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

    %% confirm we received an event associated with the above change
    %% as this will be the first msg sent by the server over the steam
    %% the headers will be included, so assert those first
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

    %% check for the received event/update
    {ok, RouteUpdate0} = test_utils:wait_for(
        fun() ->
            case grpc_client:get(Stream) of
                empty ->
                    false;
                {data, Data} ->
                    {true, Data}
            end
        end
    ),
    ct:pal("Route Update: ~p", [RouteUpdate0]),
    assert_route_update(RouteUpdate0, Routing0),

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
    assert_route_update(RouteUpdate1, Routing1),

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
    assert_route_update(RouteUpdate2, Routing2),

    meck:unload(blockchain_txn_oui_v1),
    ok.

%%route_updates_negative_test(_Config) ->
%% TODO
%%    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
assert_route_update(RouteUpdate, ExpectedRoute) ->
    #{route := Route, signature := _Sig, height := _Height} = RouteUpdate,
    assert_route(Route, ExpectedRoute).

assert_route_response(Response, ExpectedRoutes) ->
    #{routes := Routes, signature := _Sig, height := _Height} = Response,
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
