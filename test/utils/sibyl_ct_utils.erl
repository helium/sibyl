-module(sibyl_ct_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").


-export([
    create_block/2, create_block/3, create_block/4,
    pmap/2,
    wait_until/1,
    wait_until/3,
    wait_until_height/2,
    wait_until_disconnected/2,
    wait_until_local_height/1,
    wait_for/1, wait_for/3,
    start_node/3,
    partition_cluster/2,
    heal_cluster/2,
    connect/1,
    count/2,
    randname/1,
    get_config/2,
    random_n/2,
    init_per_testcase/2,
    init_per_suite/1,
    end_per_testcase/2,
    create_vars/0, create_vars/1,
    raw_vars/1,
    init_base_dir_config/3,
    ledger/2,
    destroy_ledger/0,
    add_and_gossip_fake_blocks/6,
    local_add_and_gossip_fake_blocks/5,
    add_block/4,
    create_oui_txn/4,
    setup_meck_txn_forwarding/2,
    get_consensus_members/2,
    check_genesis_block/2,
    generate_keys/1, generate_keys/2
]).

create_block(ConsensusMembers, Txs) ->
    %% Run validations by default
    create_block(ConsensusMembers, Txs, #{}, true).

create_block(ConsensusMembers, Txs, Override) ->
    %% Run validations by default
    create_block(ConsensusMembers, Txs, Override, true).

create_block(ConsensusMembers, Txs, Override, RunValidation) ->
    Blockchain = blockchain_worker:blockchain(),
    STxs = lists:sort(fun blockchain_txn:sort/2, Txs),
    case RunValidation of
        false ->
            %% Just make a block without validation
            {ok, make_block(Blockchain, ConsensusMembers, STxs, Override)};
        true ->
            case blockchain_txn:validate(STxs, Blockchain) of
                {_, []} ->
                    {ok, make_block(Blockchain, ConsensusMembers, STxs, Override)};
                {_, Invalid} ->
                    {error, {invalid_txns, Invalid}}
            end
    end.

pmap(F, L) ->
    Parent = self(),
    lists:foldl(
        fun(X, N) ->
            spawn_link(fun() ->
                Parent ! {pmap, N, F(X)}
            end),
            N + 1
        end,
        0,
        L
    ),
    L2 = [
        receive
            {pmap, N, R} -> {N, R}
        end
        || _ <- L
    ],
    {_, L3} = lists:unzip(lists:keysort(1, L2)),
    L3.

wait_until(Fun) ->
    wait_until(Fun, 40, 100).
wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry - 1, Delay)
    end.

wait_until_offline(Node) ->
    wait_until(
        fun() ->
            pang == net_adm:ping(Node)
        end,
        60 * 2,
        500
    ).

wait_until_disconnected(Node1, Node2) ->
    wait_until(
        fun() ->
            pang == rpc:call(Node1, net_adm, ping, [Node2])
        end,
        60 * 2,
        500
    ).

wait_until_connected(Node1, Node2) ->
    wait_until(
        fun() ->
            pong == rpc:call(Node1, net_adm, ping, [Node2])
        end,
        60 * 2,
        500
    ).

wait_until_local_height(TargetHeight) ->
    sibyl_ct_utils:wait_until(
        fun() ->
            C = blockchain_worker:blockchain(),
            {ok, CurHeight} = blockchain:height(C),
            ct:pal("local height ~p", [CurHeight]),
            CurHeight == TargetHeight
        end,
        30,
        timer:seconds(1)
    ).

wait_for(Fun) ->
    wait_for(Fun, 100, 100).

wait_for(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        {true, Resp} ->
            {ok, Resp};
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_for(Fun, Retry - 1, Delay)
    end.

start_node(Name, Config, Case) ->
    CodePath = lists:filter(fun filelib:is_dir/1, code:get_path()),
    %% have the slave nodes monitor the runner node, so they can't outlive it
    NodeConfig = [
        {monitor_master, true},
        {boot_timeout, 10},
        {init_timeout, 10},
        {startup_timeout, 10},
        {startup_functions, [
            {code, set_path, [CodePath]}
        ]}
    ],
    case ct_slave:start(Name, NodeConfig) of
        {ok, Node} ->
            ok = wait_until(
                fun() ->
                    net_adm:ping(Node) == pong
                end,
                60,
                500
            ),
            Node;
        {error, already_started, Node} ->
            ct_slave:stop(Name),
            wait_until_offline(Node),
            start_node(Name, Config, Case);
        {error, started_not_connected, Node} ->
            connect(Node),
            ct_slave:stop(Name),
            wait_until_offline(Node),
            start_node(Name, Config, Case)
    end.

partition_cluster(ANodes, BNodes) ->
    pmap(
        fun({Node1, Node2}) ->
            true = rpc:call(Node1, erlang, set_cookie, [Node2, canttouchthis]),
            true = rpc:call(Node1, erlang, disconnect_node, [Node2]),
            ok = wait_until_disconnected(Node1, Node2)
        end,
        [{Node1, Node2} || Node1 <- ANodes, Node2 <- BNodes]
    ),
    ok.

heal_cluster(ANodes, BNodes) ->
    GoodCookie = erlang:get_cookie(),
    pmap(
        fun({Node1, Node2}) ->
            true = rpc:call(Node1, erlang, set_cookie, [Node2, GoodCookie]),
            ok = wait_until_connected(Node1, Node2)
        end,
        [{Node1, Node2} || Node1 <- ANodes, Node2 <- BNodes]
    ),
    ok.

connect(Node) ->
    connect(Node, true).

connect(NodeStr, Auto) when is_list(NodeStr) ->
    connect(erlang:list_to_atom(lists:flatten(NodeStr)), Auto);
connect(Node, Auto) when is_atom(Node) ->
    connect(node(), Node, Auto).

connect(Node, Node, _) ->
    {error, self_join};
connect(_, Node, _Auto) ->
    attempt_connect(Node).

attempt_connect(Node) ->
    case net_kernel:connect_node(Node) of
        false ->
            {error, not_reachable};
        true ->
            {ok, connected}
    end.

count(_, []) -> 0;
count(X, [X | XS]) -> 1 + count(X, XS);
count(X, [_ | XS]) -> count(X, XS).

randname(N) ->
    randname(N, []).

randname(0, Acc) ->
    Acc;
randname(N, Acc) ->
    randname(N - 1, [rand:uniform(26) + 96 | Acc]).

get_config(Arg, Default) ->
    case os:getenv(Arg, Default) of
        false -> Default;
        T when is_list(T) -> list_to_integer(T);
        T -> T
    end.

random_n(N, List) ->
    lists:sublist(shuffle(List), N).

shuffle(List) ->
    [x || {_, x} <- lists:sort([{rand:uniform(), N} || N <- List])].

init_per_suite(Config) ->
    application:ensure_all_started(ranch),
    application:set_env(lager, error_logger_flush_queue, false),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, info),
    application:ensure_all_started(throttle),
    Config.

init_per_testcase(TestCase, Config) ->
    BaseDir = ?config(base_dir, Config),
    LogDir = ?config(log_dir, Config),
    os:cmd(os:find_executable("epmd") ++ " -daemon"),
    {ok, Hostname} = inet:gethostname(),
    case
        net_kernel:start([
            list_to_atom(
                "runner-blockchain-" ++
                    integer_to_list(erlang:system_time(nanosecond)) ++
                    "@" ++ Hostname
            ),
            shortnames
        ])
    of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, {{already_started, _}, _}} -> ok
    end,

    %% Node configuration, can be input from os env
    TotalNodes = get_config("T", 8),
    NumConsensusMembers = get_config("N", 7),
    SeedNodes = [],
    PeerCacheTimeout = 100,
    Port = get_config("PORT", 0),

    NodeNames = lists:map(fun(_M) -> list_to_atom(randname(5)) end, lists:seq(1, TotalNodes)),

    Nodes = pmap(
        fun(Node) ->
            start_node(Node, Config, TestCase)
        end,
        NodeNames
    ),

    ConfigResult = pmap(
        fun(Node) ->
            ct_rpc:call(Node, cover, start, []),
            ct_rpc:call(Node, application, load, [lager]),
            ct_rpc:call(Node, application, load, [blockchain]),
            ct_rpc:call(Node, application, load, [libp2p]),
            ct_rpc:call(Node, application, load, [erlang_stats]),
            %% give each node its own log directory
            LogRoot = LogDir ++ "_" ++ atom_to_list(Node),
            ct_rpc:call(Node, application, set_env, [lager, log_root, LogRoot]),
            ct_rpc:call(Node, lager, set_loglevel, [{lager_file_backend, "log/console.log"}, debug]),

            %% set blockchain configuration
            #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
            Key = {PubKey, libp2p_crypto:mk_sig_fun(PrivKey), libp2p_crypto:mk_ecdh_fun(PrivKey)},
            BlockchainBaseDir = BaseDir ++ "_" ++ atom_to_list(Node),
            ct_rpc:call(Node, application, set_env, [blockchain, base_dir, BlockchainBaseDir]),
            ct_rpc:call(Node, application, set_env, [
                blockchain,
                num_consensus_members,
                NumConsensusMembers
            ]),
            ct_rpc:call(Node, application, set_env, [blockchain, port, Port]),
            ct_rpc:call(Node, application, set_env, [blockchain, seed_nodes, SeedNodes]),
            ct_rpc:call(Node, application, set_env, [blockchain, key, Key]),
            ct_rpc:call(Node, application, set_env, [blockchain, peer_cache_timeout, 10000]),
            ct_rpc:call(Node, application, set_env, [blockchain, peerbook_update_interval, 200]),
            ct_rpc:call(Node, application, set_env, [blockchain, peerbook_allow_rfc1918, true]),
            ct_rpc:call(Node, application, set_env, [
                blockchain,
                max_inbound_connections,
                TotalNodes * 2
            ]),
            ct_rpc:call(Node, application, set_env, [
                blockchain,
                outbound_gossip_connections,
                TotalNodes
            ]),
            ct_rpc:call(Node, application, set_env, [blockchain, listen_interface, "127.0.0.1"]),

            ct_rpc:call(Node, application, set_env, [
                blockchain,
                peer_cache_timeout,
                PeerCacheTimeout
            ]),
            ct_rpc:call(Node, application, set_env, [
                blockchain,
                sc_client_handler,
                sc_client_test_handler
            ]),
            ct_rpc:call(Node, application, set_env, [
                blockchain,
                sc_packet_handler,
                sc_packet_test_handler
            ]),

            %% set grpcbox configuration
            ct_rpc:call(Node, application, set_env, [
                grpcbox,
                servers,
                [
                    #{
                        grpc_opts => #{
                            service_protos => [gateway_pb],
                            services => #{
                                'helium.gateway' => helium_gateway_service
                            }
                        },
                        transport_opts => #{ssl => false},
                        listen_opts => #{
                            port => 10001,
                            ip => {0, 0, 0, 0}
                        },
                        pool_opts => #{size => 2},
                        server_opts => #{
                            header_table_size => 4096,
                            enable_push => 1,
                            max_concurrent_streams => unlimited,
                            initial_window_size => 65535,
                            max_frame_size => 16384,
                            max_header_list_size => unlimited
                        }
                    }
                ]
            ]),

            {ok, _StartedApps2} = ct_rpc:call(Node, application, ensure_all_started, [grpcbox]),
            {ok, _StartedApps} = ct_rpc:call(Node, application, ensure_all_started, [blockchain])
        end,
        Nodes
    ),

    %% accumulate the listen addr of all the nodes
    Addrs = pmap(
        fun(Node) ->
            Swarm = ct_rpc:call(Node, blockchain_swarm, swarm, [], 2000),
            [H | _] = ct_rpc:call(Node, libp2p_swarm, listen_addrs, [Swarm], 2000),
            H
        end,
        Nodes
    ),

    %% connect the nodes
    pmap(
        fun(Node) ->
            Swarm = ct_rpc:call(Node, blockchain_swarm, swarm, [], 2000),
            lists:foreach(
                fun(A) ->
                    ct_rpc:call(Node, libp2p_swarm, connect, [Swarm, A], 2000)
                end,
                Addrs
            )
        end,
        Nodes
    ),

    %% make sure each node is gossiping with a majority of its peers
    ok = wait_until(
        fun() ->
            lists:all(
                fun(Node) ->
                    try
                        GossipPeers = ct_rpc:call(Node, blockchain_swarm, gossip_peers, [], 500),
                        case length(GossipPeers) >= (length(Nodes) / 2) + 1 of
                            true ->
                                true;
                            false ->
                                ct:pal("~p is not connected to enough peers ~p", [Node, GossipPeers]),
                                Swarm = ct_rpc:call(Node, blockchain_swarm, swarm, [], 500),
                                lists:foreach(
                                    fun(A) ->
                                        CRes = ct_rpc:call(
                                            Node,
                                            libp2p_swarm,
                                            connect,
                                            [Swarm, A],
                                            500
                                        ),
                                        ct:pal("Connecting ~p to ~p: ~p", [Node, A, CRes])
                                    end,
                                    Addrs
                                ),
                                false
                        end
                    catch
                        _C:_E ->
                            false
                    end
                end,
                Nodes
            )
        end,
        200,
        150
    ),

    Config0 = [
        {nodes, Nodes},
        {num_consensus_members, NumConsensusMembers},
        {node_listen_addrs, Addrs}
        | Config
    ],
    initialize_nodes(Config0).

end_per_testcase(TestCase, Config) ->
    Nodes = ?config(nodes, Config),
    pmap(fun(Node) -> ct_slave:stop(Node) end, Nodes),
    case ?config(tc_status, Config) of
        ok ->
            %% test passed, we can cleanup
            cleanup_per_testcase(TestCase, Config);
        _ ->
            %% leave results alone for analysis
            ok
    end,
    {comment, done}.

cleanup_per_testcase(_TestCase, Config) ->
    Nodes = ?config(nodes, Config),
    BaseDir = ?config(base_dir, Config),
    LogDir = ?config(log_dir, Config),
    lists:foreach(
        fun(Node) ->
            LogRoot = LogDir ++ "_" ++ atom_to_list(Node),
            Res = os:cmd("rm -rf " ++ LogRoot),
            ct:pal("rm -rf ~p -> ~p", [LogRoot, Res]),
            DataDir = BaseDir ++ "_" ++ atom_to_list(Node),
            Res2 = os:cmd("rm -rf " ++ DataDir),
            ct:pal("rm -rf ~p -> ~p", [DataDir, Res2]),
            ok
        end,
        Nodes
    ).

initialize_nodes(Config) ->
    Balance = 50000000000000,
    NumConsensusMembers = ?config(num_consensus_members, Config),
    Nodes = ?config(nodes, Config),

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
    DefaultVars = #{?num_consensus_members => NumConsensusMembers},
    ExtraVars = #{
        ?sc_version => 2,
        ?max_open_sc => 2,
        ?min_expire_within => 10,
        ?max_xor_filter_size => 1024 * 100,
        ?max_xor_filter_num => 5,
        ?max_subnet_size => 65536,
        ?min_subnet_size => 8,
        ?max_subnet_num => 20,
        ?sc_grace_blocks => 5,
        ?dc_payload_size => 24,
        ?validator_version => 3,
        ?validator_minimum_stake => ?bones(10000),
        ?validator_liveness_grace_period => 10,
        ?validator_liveness_interval => 5,
        ?validator_key_check => true,
        ?stake_withdrawal_cooldown => 10,
        ?stake_withdrawal_max => 500

    },

    {InitialVars, _Config} = create_vars(maps:merge(DefaultVars, ExtraVars)),

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

    ok = check_genesis_block(Config, GenesisBlock),
    ConsensusMembers = get_consensus_members(Config, ConsensusAddrs),
    [{consensus_members, ConsensusMembers}, {genesis_block, GenesisBlock} | Config].

create_vars() ->
    create_vars(#{}).

create_vars(Vars) ->
    #{secret := Priv, public := Pub} =
        libp2p_crypto:generate_keys(ecc_compact),

    Vars1 = raw_vars(Vars),
    ct:pal("vars ~p", [Vars1]),

    BinPub = libp2p_crypto:pubkey_to_bin(Pub),

    Txn = blockchain_txn_vars_v1:new(Vars1, 2, #{master_key => BinPub}),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    Txn1 = blockchain_txn_vars_v1:key_proof(Txn, Proof),
    {[Txn1], {master_key, {Priv, Pub}}}.

raw_vars(Vars) ->
    DefVars = #{
        ?chain_vars_version => 2,
        ?vars_commit_delay => 10,
        ?election_version => 2,
        ?election_restart_interval => 5,
        ?election_replacement_slope => 20,
        ?election_replacement_factor => 4,
        ?election_selection_pct => 70,
        ?election_removal_pct => 85,
        ?election_cluster_res => 8,
        ?block_version => v1,
        ?predicate_threshold => 0.85,
        ?num_consensus_members => 7,
        ?monthly_reward => 50000 * 1000000,
        ?securities_percent => 0.35,
        ?poc_challengees_percent => 0.19 + 0.16,
        ?poc_challengers_percent => 0.09 + 0.06,
        ?poc_witnesses_percent => 0.02 + 0.03,
        ?consensus_percent => 0.10,
        ?min_assert_h3_res => 12,
        ?max_staleness => 100000,
        ?alpha_decay => 0.007,
        ?beta_decay => 0.0005,
        ?block_time => 5000,
        ?election_interval => 30,
        ?poc_challenge_interval => 30,
        ?h3_exclusion_ring_dist => 2,
        ?h3_max_grid_distance => 13,
        ?h3_neighbor_res => 12,
        ?min_score => 0.15,
        ?reward_version => 1,
        ?allow_zero_amount => false,
        ?poc_version => 8,
        ?poc_good_bucket_low => -132,
        ?poc_good_bucket_high => -80,
        ?poc_v5_target_prob_randomness_wt => 1.0,
        ?poc_v4_target_prob_edge_wt => 0.0,
        ?poc_v4_target_prob_score_wt => 0.0,
        ?poc_v4_prob_rssi_wt => 0.0,
        ?poc_v4_prob_time_wt => 0.0,
        ?poc_v4_randomness_wt => 0.5,
        ?poc_v4_prob_count_wt => 0.0,
        ?poc_centrality_wt => 0.5,
        ?poc_max_hop_cells => 2000,
        ?poc_path_limit => 7,
        ?poc_typo_fixes => true,
        ?poc_target_hex_parent_res => 5,
        ?witness_refresh_interval => 10,
        ?witness_refresh_rand_n => 100,
        ?max_open_sc => 2,
        ?min_expire_within => 10,
        ?max_xor_filter_size => 1024 * 100,
        ?max_xor_filter_num => 5,
        ?max_subnet_size => 65536,
        ?min_subnet_size => 8,
        ?max_subnet_num => 20,
        ?dc_payload_size => 24
    },

    maps:merge(DefVars, Vars).

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory based off priv_data to be used as a scratch by common tests
%% @end
%%-------------------------------------------------------------------
-spec init_base_dir_config(atom(), atom(), list()) -> {list(), list()}.
init_base_dir_config(Mod, TestCase, Config) ->
    PrivDir = ?config(priv_dir, Config),
    TCName = erlang:atom_to_list(TestCase),
    BaseDir = PrivDir ++ "data/" ++ erlang:atom_to_list(Mod) ++ "_" ++ TCName,
    LogDir = PrivDir ++ "logs/" ++ erlang:atom_to_list(Mod) ++ "_" ++ TCName,
    SimDir = BaseDir ++ "_sim",
    [
        {base_dir, BaseDir},
        {sim_dir, SimDir},
        {log_dir, LogDir}
        | Config
    ].

wait_until_height(Node, Height) ->
    wait_until(
        fun() ->
            C = ct_rpc:call(Node, blockchain_worker, blockchain, []),
            {ok, CurHeight} = ct_rpc:call(Node, blockchain, height, [C]),
            ct:pal("node ~p height ~p", [Node, CurHeight]),
            CurHeight == Height
        end,
        30,
        timer:seconds(1)
    ).

ledger(ExtraVars, S3URL) ->
    %% Ledger at height: 481929
    %% ActiveGateway Count: 8000
    {ok, Dir} = file:get_cwd(),
    %% Ensure priv dir exists
    PrivDir = filename:join([Dir, "priv"]),
    ok = filelib:ensure_dir(PrivDir ++ "/"),
    %% Path to static ledger tar
    LedgerTar = filename:join([PrivDir, "ledger.tar.gz"]),
    %% Extract ledger tar if required
    ok = extract_ledger_tar(PrivDir, LedgerTar, S3URL),
    %% Get the ledger
    Ledger = blockchain_ledger_v1:new(PrivDir),
    %% Get current ledger vars
    LedgerVars = ledger_vars(Ledger),
    %% Ensure the ledger has the vars we're testing against
    Ledger1 = blockchain_ledger_v1:new_context(Ledger),
    blockchain_ledger_v1:vars(maps:merge(LedgerVars, ExtraVars), [], Ledger1),
    %% If the hexes aren't on the ledger add them
    blockchain:bootstrap_hexes(Ledger1),
    blockchain_ledger_v1:commit_context(Ledger1),
    Ledger.

extract_ledger_tar(PrivDir, LedgerTar, S3URL) ->
    case filelib:is_file(LedgerTar) of
        true ->
            %% if we have already unpacked it, no need to do it again
            LedgerDB = filename:join([PrivDir, "ledger.db"]),
            case filelib:is_dir(LedgerDB) of
                true ->
                    ok;
                false ->
                    %% ledger tar file present, extract
                    erl_tar:extract(LedgerTar, [compressed, {cwd, PrivDir}])
            end;
        false ->
            %% ledger tar file not found, download & extract
            ok = ssl:start(),
            {ok, {{_, 200, "OK"}, _, Body}} = httpc:request(S3URL),
            ok = file:write_file(filename:join([PrivDir, "ledger.tar.gz"]), Body),
            erl_tar:extract(LedgerTar, [compressed, {cwd, PrivDir}])
    end.

ledger_vars(Ledger) ->
    blockchain_utils:vars_binary_keys_to_atoms(
        maps:from_list(blockchain_ledger_v1:snapshot_vars(Ledger))
    ).

destroy_ledger() ->
    {ok, Dir} = file:get_cwd(),
    %% Ensure priv dir exists
    PrivDir = filename:join([Dir, "priv"]),
    ok = filelib:ensure_dir(PrivDir ++ "/"),
    LedgerTar = filename:join([PrivDir, "ledger.tar.gz"]),
    LedgerDB = filename:join([PrivDir, "ledger.db"]),

    case filelib:is_file(LedgerTar) of
        true ->
            %% we found a ledger tarball, remove it
            file:delete(LedgerTar);
        false ->
            ok
    end,
    case filelib:is_dir(LedgerDB) of
        true ->
            %% we found a ledger.db, remove it
            file:del_dir(LedgerDB);
        false ->
            %% ledger.db dir not found, don't do anything
            ok
    end.

check_genesis_block(Config, GenesisBlock) ->
    Nodes = ?config(nodes, Config),
    lists:foreach(
        fun(Node) ->
            Blockchain = ct_rpc:call(Node, blockchain_worker, blockchain, []),
            {ok, HeadBlock} = ct_rpc:call(Node, blockchain, head_block, [Blockchain]),
            {ok, WorkerGenesisBlock} = ct_rpc:call(Node, blockchain, genesis_block, [Blockchain]),
            {ok, Height} = ct_rpc:call(Node, blockchain, height, [Blockchain]),
            ?assertEqual(GenesisBlock, HeadBlock),
            ?assertEqual(GenesisBlock, WorkerGenesisBlock),
            ?assertEqual(1, Height)
        end,
        Nodes
    ).

get_consensus_members(Config, ConsensusAddrs) ->
    Nodes = ?config(nodes, Config),
    lists:keysort(
        1,
        lists:foldl(
            fun(Node, Acc) ->
                Addr = ct_rpc:call(Node, blockchain_swarm, pubkey_bin, []),
                case lists:member(Addr, ConsensusAddrs) of
                    false ->
                        Acc;
                    true ->
                        {ok, Pubkey, SigFun, _ECDHFun} = ct_rpc:call(
                            Node,
                            blockchain_swarm,
                            keys,
                            []
                        ),
                        [{Addr, Pubkey, SigFun} | Acc]
                end
            end,
            [],
            Nodes
        )
    ).

setup_meck_txn_forwarding(Node, From) ->
    ok = ct_rpc:call(Node, meck_test_util, forward_submit_txn, [From]),
    ok = ct_rpc:call(Node, blockchain_worker, submit_txn, [test]),
    receive
        {txn, test} ->
            ct:pal("Got txn test"),
            ok
    after 1000 -> ct:fail("txn test timeout")
    end.

create_oui_txn(OUI, RouterNode, EUIs, SubnetSize) ->
    {ok, RouterPubkey, RouterSigFun, _} = ct_rpc:call(RouterNode, blockchain_swarm, keys, []),
    RouterPubkeyBin = libp2p_crypto:pubkey_to_bin(RouterPubkey),
    {Filter, _} = xor16:to_bin(
        xor16:new(
            [
                <<DevEUI:64/integer-unsigned-little, AppEUI:64/integer-unsigned-little>>
                || {DevEUI, AppEUI} <- EUIs
            ],
            fun xxhash:hash64/1
        )
    ),
    OUITxn = blockchain_txn_oui_v1:new(OUI, RouterPubkeyBin, [RouterPubkeyBin], Filter, SubnetSize),
    blockchain_txn_oui_v1:sign(OUITxn, RouterSigFun).

add_block(RouterNode, RouterChain, ConsensusMembers, Txns) ->
    ct:pal("RouterChain: ~p", [RouterChain]),
    ct_rpc:call(RouterNode, sibyl_ct_utils, create_block, [ConsensusMembers, Txns]).

add_and_gossip_fake_blocks(NumFakeBlocks, ConsensusMembers, Node, Swarm, Chain, From) ->
    lists:foreach(
        fun(_) ->
            {ok, B} = ct_rpc:call(Node, sibyl_ct_utils, create_block, [ConsensusMembers, []]),
            _ = ct_rpc:call(Node, blockchain_gossip_handler, add_block, [B, Chain, From, Swarm]),
            timer:sleep(50)
        end,
        lists:seq(1, NumFakeBlocks)
    ).

local_add_and_gossip_fake_blocks(NumFakeBlocks, ConsensusMembers, Swarm, Chain, From) ->
    lists:foreach(
        fun(_) ->
            {ok, B} = sibyl_ct_utils:create_block(ConsensusMembers, []),
            _ = blockchain_gossip_handler:add_block(B, Chain, From, Swarm),
            timer:sleep(50)
        end,
        lists:seq(1, NumFakeBlocks)
    ).

generate_keys(N) ->
    generate_keys(N, ecc_compact).

generate_keys(N, Type) ->
    lists:foldl(
        fun(_, Acc) ->
            #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(Type),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            [{libp2p_crypto:pubkey_to_bin(PubKey), {PubKey, PrivKey, SigFun}}|Acc]
        end
        ,[]
        ,lists:seq(1, N)
    ).

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
make_block(Blockchain, ConsensusMembers, STxs, _Override) ->
    {ok, HeadBlock} = blockchain:head_block(Blockchain),
    {ok, PrevHash} = blockchain:head_hash(Blockchain),
    Height = blockchain_block:height(HeadBlock) + 1,
    Time = blockchain_block:time(HeadBlock) + 1,
    lager:info("creating block ~p", [STxs]),
    Default = #{
        prev_hash => PrevHash,
        height => Height,
        transactions => STxs,
        signatures => [],
        time => Time,
        hbbft_round => 0,
        election_epoch => 1,
        epoch_start => 0,
        seen_votes => [],
        bba_completion => <<>>,
        poc_keys => []
    },
    Block0 = blockchain_block_v1:new(Default),
    BinBlock = blockchain_block:serialize(Block0),
    Signatures = signatures(ConsensusMembers, BinBlock),
    Block1 = blockchain_block:set_signatures(Block0, Signatures),
    lager:info("block ~p", [Block1]),
    Block1.

signatures(ConsensusMembers, BinBlock) ->
    lists:foldl(
        fun
            ({A, {_, _, F}}, Acc) ->
                Sig = F(BinBlock),
                [{A, Sig} | Acc];
            %% NOTE: This clause matches the consensus members generated for the dist suite
            ({A, _, F}, Acc) ->
                Sig = F(BinBlock),
                [{A, Sig} | Acc]
        end,
        [],
        ConsensusMembers
    ).
