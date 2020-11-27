-module(test_utils).

-export([
    init_per_testcase/2,
    end_per_testcase/2,
    tmp_dir/0, tmp_dir/1,
    init_base_dir_config/3,
    wait_until/1, wait_until/3
]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

init_per_testcase(_TestCase, Config) ->
    %% setup and start a chain
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    BaseDir = ?config(base_dir, Config),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    ECDHFun = libp2p_crypto:mk_ecdh_fun(PrivKey),
    Opts = [
        {key, {PubKey, SigFun, ECDHFun}},
        {seed_nodes, []},
        {port, 0},
        {num_consensus_members, 7},
        {base_dir, BaseDir}
    ],
    {ok, Sup} = blockchain_sup:start_link(Opts),
    ?assert(erlang:is_pid(blockchain_swarm:swarm())),
    Swarm = blockchain_swarm:swarm(),
    {ok, _GenesisMembers, _GenesisBlock, ConsensusMembers, Keys} = blockchain_test_utils:init_chain(
        5000,
        {PrivKey, PubKey},
        true
    ),

    [
        {swarm, Swarm},
        {keys, Keys},
        {sup, Sup},
        {consensus_members, ConsensusMembers}
        | Config
    ].

end_per_testcase(_TestCase, Config) ->
    Sup = ?config(sup, Config),
    meck:unload(),
    case erlang:is_process_alive(Sup) of
        true ->
            true = erlang:exit(Sup, normal),
            ok = test_utils:wait_until(fun() -> false =:= erlang:is_process_alive(Sup) end);
        false ->
            ok
    end,
    ok.

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory to be used as a scratch by eunit tests
%% @end
%%-------------------------------------------------------------------
tmp_dir() ->
    os:cmd("mkdir -p " ++ ?BASE_TMP_DIR),
    create_tmp_dir(?BASE_TMP_DIR_TEMPLATE).

tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

wait_until(Fun) ->
    wait_until(Fun, 100, 100).

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

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% Deletes the specified directory
%% @end
%%-------------------------------------------------------------------
-spec cleanup_tmp_dir(list()) -> ok.
cleanup_tmp_dir(Dir) ->
    os:cmd("rm -rf " ++ Dir),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% create a tmp directory at the specified path
%% @end
%%-------------------------------------------------------------------
-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path) ->
    ?MODULE:nonl(os:cmd("mktemp -d " ++ Path)).

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory based off priv_dir to be used as a scratch by common tests
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
