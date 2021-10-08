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

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {
    chain :: undefined | blockchain:blockchain()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    ok = blockchain_event:add_handler(self()),
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
    {blockchain_event, {add_block, _BlockHash, _Sync, _Ledger} = _Event},
    #state{chain = Chain} = State
) when Chain =:= undefined ->
    {noreply, State};
handle_info({blockchain_event, {add_block, _BlockHash, Sync, _Ledger} = Event}, State) when
    Sync =:= false
->
    lager:debug("received add block event, sync is ~p", [Sync]),
    handle_add_block_event(Event, State);
handle_info(_Info, State = #state{}) ->
    {noreply, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec handle_add_block_event(
    {atom(), blockchain_block:hash(), boolean(), blockchain_ledger_v1:ledger()},
    #state{}
) -> {noreply, #state{}}.
handle_add_block_event({add_block, _BlockHash, true = _Sync, _Ledger}, State = #state{}) ->
    {noreply, State};
handle_add_block_event(
    {add_block, BlockHash, false = _Sync, Ledger},
    State = #state{chain = Chain}
) ->
    case blockchain:get_block(BlockHash, Chain) of
        {ok, Block} ->
            Vars = blockchain_utils:vars_binary_keys_to_atoms(
                maps:from_list(blockchain_ledger_v1:snapshot_vars(Ledger))
            ),
            %% get the empheral keys from the block
            %% keys will be a prop with tuples in the format: {ChallengerPubKey, Key}
            PocEphemeralKeys = blockchain_block_v1:poc_keys(Block),
            %% a POC will be active for each key
            %% for each notify all GWs in the target region
            %% telling them they have to contact the challenger to check if they are the actual target
            {ok, CGMembers} = blockchain_ledger_v1:consensus_members(Ledger),
            [
                begin
                    ChallengerAddr = lists:index(CGPos, CGMembers),
                    spawn_link(
                        fun() ->
                            run_poc_targetting(ChallengerAddr, Key, Ledger, BlockHash, Vars)
                        end
                    )
                end
                || {CGPos, Key} <- PocEphemeralKeys
            ],
            {noreply, State#state{}};
        _ ->
            lager:error("failed to find block with hash: ~p", [BlockHash]),
            {noreply, State}
    end.

run_poc_targetting(ChallengerAddr, Key, Ledger, BlockHash, Vars) ->
    %% first we pick an initial target GW based on the entropy of the ephemeral key and the block hash
    %% this wont be the actual target, instead its location is used as the point from where the actual
    %% target will be selected within a specified radius of this initial target
    %% this is used over picking a random h3 cell or region, as in that case we would have to
    %% contend and deal with selected cells not containing any GWs
    Entropy = <<Key/binary, BlockHash/binary>>,
    ZoneRandState = blockchain_utils:rand_state(Entropy),
    case blockchain_poc_target_v4:target_zone(ZoneRandState, Ledger) of
        {error, _} ->
            lager:info("*** failed to find a target zone", []),
            noop;
        {ok, {HexList, Hex, HexRandState}} ->
            %% get all GWs in this zone
            {ok, ZoneGWs} = blockchain_poc_target_v4:gateways_for_zone(
                ChallengerAddr,
                Ledger,
                Vars,
                HexList,
                [{Hex, HexRandState}]
            ),
            lager:info("*** found gateways for target zone", [ZoneGWs]),
            %% create the notification
            case sibyl_utils:address_data([ChallengerAddr]) of
                [] ->
                    lager:info("*** no public addr for ~p", [ChallengerAddr]),
                    %% hmmm we have no public address for the challenger's pub key
                    %% what to do ?
                    ok;
                [ChallengerRoutingAddress] ->
                    lager:info("ChallengerAddr: ~p", [ChallengerAddr]),
                    lager:info("ChallengerRoutingAddress: ~p", [ChallengerRoutingAddress]),

                    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
                    NotificationPB = #gateway_poc_challenge_notification_resp_v1_pb{
                        challenger = ChallengerRoutingAddress,
                        block_hash = BlockHash,
                        onion_key_hash = Key
                    },
                    Notification = sibyl_utils:encode_gateway_resp_v1(
                        NotificationPB,
                        CurHeight,
                        sibyl_mgr:sigfun()
                    ),
                    %% send the notification to all the GWs in the zone, informing them they might be being challenged
                    lists:foreach(
                        fun(GW) ->
                            Topic = sibyl_utils:make_poc_topic(GW),
                            lager:info("*** sending poc notification to gateway ~p", [GW]),
                            sibyl_bus:pub(Topic, {poc_notify, Notification})
                        end,
                        ZoneGWs
                    )
            end
    end.
