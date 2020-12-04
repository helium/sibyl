-module(http2_api_SUITE).

-include("sibyl.hrl").

-define(CLIENT_REF_NAME, <<"x-client-id">>).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    get_routes_test/1,
    get_routes_negative_test/1,
    route_updates_test/1,
    route_updates_negative_test/1
]).

-include_lib("helium_proto/include/routing_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("chatterbox/include/http2.hrl").

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
        get_routes_negative_test,
        route_updates_test,
        route_updates_negative_test
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
    test_utils:end_per_testcase(TestCase, Config),
    grpc:stop_server(grpc),
    catch exit(whereis(sibyl_sup)).


%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

get_routes_test(Config) ->
    %% verify the get request to pull all routing data
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

    %% check we get the expected routing data returned via the http2 api
    {ok, Pid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(Pid),

    StreamRef = gun:get(Pid, "/v1/routes", [
        {<<"host">>, <<"localhost">>},
        {<<"accept">>, <<"*/*">>},
        {?CLIENT_HEIGHT_HEADER, sibyl_utils:ensure(binary, 1)}
    ]),

    {response, nofin, 200, ResponseHeaders} = gun:await(Pid, StreamRef),
    {data, fin, ResponseData} = gun:await(Pid, StreamRef),

    ct:pal("Response Headers: ~p", [ResponseHeaders]),
    ct:pal("Response Body: ~p", [ResponseData]),

    assert_route_response(base64:decode(ResponseData), [Routing0]),

    %% get the routes again, this time present the client last height header
    %% we will set this to a height equal to the current height
    %% we should get a 304 not modified response
    {ok, CurHeight} = blockchain:height(Chain),
    StreamRef2 = gun:get(Pid, "/v1/routes", [
        {<<"host">>, <<"localhost">>},
        {<<"accept">>, <<"*/*">>},
        {?CLIENT_HEIGHT_HEADER, sibyl_utils:ensure(binary, CurHeight)}
    ]),

    {response, nofin, 304, ResponseHeaders} = gun:await(Pid, StreamRef2),
    ok.

get_routes_negative_test(_Config) ->
    {ok, Pid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(Pid),

    %% send a request with an invalid method, should fail with a 405 error
    StreamRef1 = gun:put(Pid, "/v1/routes", [], <<>>),
    case gun:await(Pid, StreamRef1) of
        {response, fin, _Status1, _Headers1} ->
            ct:fail(no_response);
        {response, nofin, Status1, Headers1} ->
            ct:pal("Response Headers: ~p", [Headers1]),
            ?assertEqual(405, Status1)
    end,

    %% send a request whilst chain is unavailable
    %% need to meck out the chain check
    meck:new(sibyl_mgr, [no_link, passthrough]),
    meck:expect(sibyl_mgr, blockchain, fun() -> undefined end),

    StreamRef2 = gun:get(Pid, "/v1/routes", [
        {<<"host">>, <<"localhost">>},
        {<<"accept">>, <<"*/*">>}
    ]),
    case gun:await(Pid, StreamRef2) of
        {response, fin, _Status2, _Headers2} ->
            ct:fail(no_response);
        {response, nofin, Status2, Headers2} ->
            ct:pal("Response Headers: ~p", [Headers2]),
            ?assertEqual(503, Status2)
    end,

    gun:close(Pid),
    ok.

route_updates_test(Config) ->
    %% add a bunch of routing data and confirm client receives streaming updates for each update
    ConsensusMembers = ?config(consensus_members, Config),
    Swarm = ?config(swarm, Config),

    Chain = blockchain_worker:blockchain(),
    Ledger = blockchain:ledger(Chain),

    [_, {Payer, {_, PayerPrivKey, _}} | _] = ConsensusMembers,
    SigFun = libp2p_crypto:mk_sig_fun(PayerPrivKey),

    %% setup the streaming SSE connection
    {ok, Pid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(Pid),

    StreamRef = gun:get(Pid, "/v1/events/route_updates", [
        {<<"host">>, <<"localhost">>},
        {<<"accept">>, <<"text/event-stream">>}
    ]),

    %% confirm we get the event-stream content type response
    %% events will then come in thereafter as they happen
    {response, nofin, 200, ResponseHeaders} = gun:await(Pid, StreamRef),
    {_, <<"text/event-stream">>} =
        lists:keyfind(<<"content-type">>, 1, ResponseHeaders),

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
    {sse, #{last_event_id := _EventId0, event_type := _Type0, data := [Data0]} = _Event0} = gun:await(
        Pid,
        StreamRef
    ),
    ct:pal("got event ~p", [_Event0]),
    assert_route_update(base64:decode(Data0), Routing0),

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
    {sse, #{last_event_id := _EventId1, event_type := _Type1, data := [Data1]} = _Event1} = gun:await(
        Pid,
        StreamRef
    ),
    ct:pal("got event ~p", [_Event1]),
    assert_route_update(base64:decode(Data1), Routing1),

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
    {sse, #{last_event_id := _EventId2, event_type := _Type2, data := [Data2]} = _Event2} = gun:await(
        Pid,
        StreamRef
    ),
    ct:pal("got event ~p", [_Event2]),
    assert_route_update(base64:decode(Data2), Routing2),

    gun:cancel(Pid, StreamRef),
    meck:unload(blockchain_txn_oui_v1),
    ok.

route_updates_negative_test(_Config) ->
    {ok, Pid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(Pid),

    %% send a request with an invalid method, should fail with a 405 error
    StreamRef1 = gun:put(Pid, "/v1/events/route_updates", [], <<>>),
    case gun:await(Pid, StreamRef1) of
        {response, fin, _Status1, _Headers1} ->
            ct:fail(no_response);
        {response, nofin, Status1, Headers1} ->
            ct:pal("Response Headers: ~p", [Headers1]),
            ?assertEqual(405, Status1)
    end,

    gun:close(Pid),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------
assert_route_update(Update, ExpectedRoute) ->
    try
        routing_v1_pb:decode_msg(
            Update,
            routing_v1_update_pb
        )
    of
        #routing_v1_update_pb{route = Route, signature = _Sig, height = _Height} = _Resp ->
            assert_route(Route, ExpectedRoute)
    catch
        _E:_R ->
            ct:fail(" failed to decode response update ~p ~p", [Update, {_E, _R}])
    end.

assert_route_response(Response, ExpectedRoutes) ->
    try
        routing_v1_pb:decode_msg(
            Response,
            routing_v1_response_pb
        )
    of
        #routing_v1_response_pb{routes = Routes, signature = _Sig, height = _Height} = _Resp ->
            lists:foldl(
                fun(R, Acc) -> assert_route(R, lists:nth(Acc, ExpectedRoutes)) end,
                1,
                Routes
            )
    catch
        _E:_R ->
            ct:fail(" failed to decode response update ~p ~p", [Response, {_E, _R}])
    end.

assert_route(Route, ExpectedRoute) ->
    ?assertEqual(blockchain_ledger_routing_v1:oui(ExpectedRoute), Route#routing_v1_pb.oui),
    ?assertEqual(
        blockchain_ledger_routing_v1:owner(ExpectedRoute),
        Route#routing_v1_pb.owner
    ),
    ?assertEqual(
        blockchain_ledger_routing_v1:filters(ExpectedRoute),
        Route#routing_v1_pb.filters
    ),
    ?assertEqual(
        blockchain_ledger_routing_v1:subnets(ExpectedRoute),
        Route#routing_v1_pb.subnets
    ).
