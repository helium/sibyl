%%%-------------------------------------------------------------------
%%% @author andrewmckenzie
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%% Listen for block events, pulls the POC empheral keys from the block metadata
%%% and utilizes each key and the block hash to identify the target region
%%% of the associated POC.  Subsequently sends a notification to each GW in the
%%% target region that they may be being challenged
%%% @end
%%% Created : 13. May 2021 11:24
%%%-------------------------------------------------------------------
-module(sibyl_poc_mgr).

-behaviour(gen_server).

-include("src/grpc/autogen/server/gateway_pb.hrl").
-include("sibyl.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include_lib("blockchain/include/blockchain.hrl").

%% API
-export([
    start_link/1,
    make_ets_table/0,
    cache_reactivated_gw/1,
    cached_reactivated_gws/0,
    clear_reactivated_gws/0,
    delete_reactivated_gws/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(REACTIVATED_GWS, reactivated_gws).

-record(state, {
    chain :: undefined | blockchain:blockchain()
}).

%%%===================================================================
%%% API
%%%===================================================================
-spec start_link(#{}) -> {ok, pid()}.
start_link(Args) ->
    case gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []) of
        {ok, Pid} ->
            %% if we have an ETS table reference, give ownership to the new process
            %% we likely are the `heir', so we'll get it back if this process dies
            case proplists:get_value(ets, Args) of
                undefined ->
                    ok;
                Tab ->
                    true = ets:give_away(Tab, Pid, undefined)
            end,
            {ok, Pid};
        Other ->
            Other
    end.

-spec make_ets_table() -> atom().
make_ets_table() ->
    Tab1 = ets:new(
        ?REACTIVATED_GWS,
        [
            named_table,
            public,
            {heir, self(), undefined}
        ]
    ),
    Tab1.

cache_reactivated_gw(GWAddr) ->
    true = ets:insert(?REACTIVATED_GWS, {GWAddr}).

cached_reactivated_gws() ->
    L = ets:tab2list(?REACTIVATED_GWS),
    [Addr || {Addr} <- L].

delete_reactivated_gws(L) ->
    [ets:delete(?REACTIVATED_GWS, GWAddr) || GWAddr <- L].

clear_reactivated_gws() ->
    ets:delete_all_objects(?REACTIVATED_GWS).
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Args) ->
    ok = blockchain_poc_event:add_handler(self()),
    erlang:send_after(500, self(), init),
    {ok, #state{}}.

handle_call(_Request, _From, State = #state{}) ->
    {reply, ok, State}.

handle_cast(_Request, State = #state{}) ->
    {noreply, State}.

handle_info(init, #state{chain = undefined} = State) ->
    %% No chain
    case blockchain_worker:blockchain() of
        undefined ->
            erlang:send_after(500, self(), init),
            {noreply, State};
        Chain ->
            {noreply, State#state{chain = Chain}}
    end;
handle_info(
    {blockchain_poc_event, {poc_keys, _Payload} = _Event},
    #state{chain = Chain} = State
) when Chain =:= undefined ->
    {noreply, State};
handle_info(
    {blockchain_poc_event, {poc_keys, _Payload} = Event}, State
) ->
    lager:debug("received poc_keys event:  ~p", [Event]),
    handle_poc_event(Event, State);
handle_info(Msg, State = #state{}) ->
    lager:warning("unhandled msg ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
handle_poc_event(
    {poc_keys, {_BlockHeight, BlockHash, _Sync, BlockPOCs}},
    State = #state{chain = Chain}
) ->
    Ledger = blockchain:ledger(Chain),
    Vars = blockchain_utils:vars_binary_keys_to_atoms(
        maps:from_list(blockchain_ledger_v1:snapshot_vars(Ledger))
    ),
    %% a POC will be active for each record in BlockPOCs
    %% for each notify all GWs in the target region
    %% telling them they have to contact the challenger to check if they are the actual target
    [
        begin
            spawn_link(
                fun() ->
                    Key = blockchain_ledger_poc_v3:onion_key_hash(POC),
                    Challenger = blockchain_ledger_poc_v3:challenger(POC),
                    run_poc_targetting(Challenger, Key, Ledger, BlockHash, Vars)
                end
            )
        end
     || {_, POC} <- BlockPOCs
    ],
    {noreply, State#state{}}.

run_poc_targetting(ChallengerAddr, Key, Ledger, BlockHash, Vars) ->
    Entropy = <<Key/binary, BlockHash/binary>>,
    ZoneRandState = blockchain_utils:rand_state(Entropy),
    TargetMod = blockchain_utils:target_v_to_mod(blockchain:config(?poc_targeting_version, Ledger)),
    case TargetMod:target_zone(ZoneRandState, Ledger) of
        {error, _} ->
            lager:debug("*** failed to find a target zone", []),
            noop;
        {ok, {HexList, Hex, HexRandState}} ->
            %% get all GWs in this zone
            {ok, ZoneGWs} = blockchain_poc_target_v5:gateways_for_zone(
                ChallengerAddr,
                Ledger,
                Vars,
                HexList,
                [{Hex, HexRandState}]
            ),
            lager:debug("*** found gateways for target zone: ~p", [ZoneGWs]),
            %% create the notification
            case sibyl_utils:address_data([ChallengerAddr]) of
                [] ->
                    lager:debug("*** no public addr for ~p", [ChallengerAddr]),
                    %% hmmm we have no public address for the challenger's pub key
                    %% what to do ?
                    ok;
                [ChallengerRoutingAddress] ->
                    lager:debug("ChallengerRoutingAddress: ~p", [ChallengerRoutingAddress]),
                    NotificationPB = #gateway_poc_challenge_notification_resp_v1_pb{
                        challenger = ChallengerRoutingAddress,
                        block_hash = BlockHash,
                        onion_key_hash = Key
                    },
                    Notification = sibyl_utils:encode_gateway_resp_v1(
                        NotificationPB,
                        sibyl_mgr:sigfun()
                    ),
                    %% send the notification to all the GWs in the zone, informing them they might be being challenged
                    lists:foreach(
                        fun(GW) ->
                            Topic = sibyl_utils:make_poc_topic(GW),
                            lager:debug("*** sending poc notification to gateway ~p", [GW]),
                            sibyl_bus:pub(Topic, {poc_notify, Notification})
                        end,
                        ZoneGWs
                    )
            end
    end.
