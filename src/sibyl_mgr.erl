-module(sibyl_mgr).

-behaviour(gen_server).

-include("../include/sibyl.hrl").
-include("grpc/autogen/server/gateway_pb.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-define(TID, val_mgr).
-define(CHAIN, blockchain).
-define(HEIGHT, height).
-define(SIGFUN, sigfun).
-define(SERVER, ?MODULE).
-define(VALIDATORS, validators).
-define(ROUTING_CF_NAME, routing).
-define(STATE_CHANNEL_CF_NAME, state_channels).

-ifdef(TEST).
-define(VALIDATOR_CACHE_REFRESH, 5).
-else.
-define(VALIDATOR_CACHE_REFRESH, 100).
-endif.

-record(state, {
    tid :: ets:tab(),
    commit_hook_refs = [] :: list()
}).

-type event_type() :: binary().
-type event_types() :: [event_type()].
-type event() :: {event, binary(), any()} | {event, binary()}.
-type state() :: #state{}.

-export_type([event_type/0, event_types/0, event/0]).

%% ------------------------------------------------------------------
%% gen_server exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

%% ------------------------------------------------------------------
%% API exports
%% ------------------------------------------------------------------
-export([
    start_link/1,
    make_ets_table/0,
    update_last_modified/2,
    get_last_modified/1,
    blockchain/0,
    height/0,
    sigfun/0,
    validators/0
]).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------
-spec start_link([any()]) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link(Args) ->
    case gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []) of
        {ok, Pid} ->
            %% if we have an ETS table reference, give ownership to the new process
            %% we likely are the `heir', so we'll get it back if this process dies
            case proplists:get_value(ets, Args) of
                undefined ->
                    {ok, Pid};
                Tab ->
                    true = ets:give_away(Tab, Pid, undefined),
                    {ok, Pid}
            end;
        Other ->
            Other
    end.

-spec update_last_modified(event_type(), non_neg_integer()) -> true.
update_last_modified(Event, Height) ->
    ets:insert(?TID, {Event, Height}).

-spec get_last_modified(event_type()) -> non_neg_integer().
get_last_modified(Event) ->
    try ets:lookup_element(?TID, Event, 2) of
        X -> X
    catch
        _:_ -> undefined
    end.

-spec blockchain() -> blockchain:blockchain() | undefined.
blockchain() ->
    try ets:lookup_element(?TID, ?CHAIN, 2) of
        X -> X
    catch
        _:_ -> undefined
    end.

-spec height() -> non_neg_integer() | undefined.
height() ->
    try ets:lookup_element(?TID, ?HEIGHT, 2) of
        X -> X
    catch
        _:_ -> undefined
    end.

-spec sigfun() -> function() | undefined.
sigfun() ->
    try ets:lookup_element(?TID, ?SIGFUN, 2) of
        X -> X
    catch
        _:_ -> undefined
    end.

-spec validators() -> function() | undefined.
validators() ->
    try ets:lookup_element(?TID, ?VALIDATORS, 2) of
        X -> X
    catch
        _:_ -> []
    end.

make_ets_table() ->
    ets:new(
        ?TID,
        [
            public,
            ordered_set,
            named_table,
            {read_concurrency, true},
            {heir, self(), undefined}
        ]
    ).

%% ------------------------------------------------------------------
%% gen_server functions
%% ------------------------------------------------------------------
init(Args) ->
    process_flag(trap_exit, true),
    lager:debug("init with args ~p", [Args]),
    TID =
        case proplists:get_value(ets, Args) of
            undefined ->
                make_ets_table();
            Tab ->
                Tab
        end,
    _ = erlang:send_after(500, self(), setup),
    {ok, #state{tid = TID}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(setup, State) ->
    try blockchain_worker:blockchain() of
        undefined ->
            lager:debug("chain not ready, will try again in a bit"),
            erlang:send_after(2000, self(), setup),
            {noreply, State};
        Chain ->
            lager:debug("chain ready, saving chain and sigfun to cache and adding commit hooks"),
            Ledger = blockchain:ledger(Chain),
            ok = blockchain_event:add_handler(self()),
            {ok, _, SigFun, _} = blockchain_swarm:keys(),
            {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
            ets:insert(?TID, {?CHAIN, Chain}),
            ets:insert(?TID, {?SIGFUN, SigFun}),
            ets:insert(?TID, {?HEIGHT, CurHeight}),
            {ok, Refs} = add_commit_hooks(),
            ok = subscribe_to_events(),
            {noreply, State#state{commit_hook_refs = Refs}}
    catch
        _:_ ->
            erlang:send_after(2000, self(), setup),
            {noreply, State}
    end;
handle_info({blockchain_event, {new_chain, NC}}, State = #state{commit_hook_refs = _Refs}) ->
    lager:debug("updating with new chain", []),
    ets:insert(?TID, {?CHAIN, NC}),
    {noreply, State};
handle_info({blockchain_event, {add_block, _BlockHash, Sync, _Ledger} = Event}, State) when
    Sync =:= false
->
    lager:debug("received add block event, sync is ~p", [Sync]),
    ok = process_add_block_event(Event, State),
    {noreply, State};
handle_info(
    {event, EventTopic, _Payload} = _Msg,
    State
) ->
    %% the mgr subscribes to updates in order to update the cache as to when
    %% relevant CFs were last updated.  Then when a client connects we can determine
    %% if they maybe have a stale view of the world
    Chain = ?MODULE:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    %% update cache with the height at which the routes have been updated
    true = ?MODULE:update_last_modified(EventTopic, CurHeight),
    lager:debug("updated last modified height for event ~p with height ~p", [
        EventTopic,
        CurHeight
    ]),
    {noreply, State};
handle_info({'ETS-TRANSFER', _TID, _FromPid, _Data}, State) ->
    lager:debug("rcvd ets table transfer for tid ~p", [_TID]),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:debug("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

terminate(_Reason, _State = #state{commit_hook_refs = Refs}) ->
    catch [blockchain_worker:remove_commit_hook(R) || R <- Refs],
    ok.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec process_add_block_event(
    Event :: {add_block, binary(), boolean(), blockchain_ledger_v1:ledger()},
    State :: state()
) -> ok.
process_add_block_event({add_block, BlockHash, _Sync, Ledger}, _State) ->
    Chain = ?MODULE:blockchain(),
    case blockchain:get_block(BlockHash, Chain) of
        {ok, Block} ->
            BlockHeight = blockchain_block:height(Block),
            %% update the list of validators in the cache every N blocks
            case BlockHeight rem ?VALIDATOR_CACHE_REFRESH == 0 of
                true ->
                    ok = update_validator_cache(Ledger);
                false ->
                    ok
            end,
            %% check if there are any chain var txns in the block
            %% if so send a notification to subscribed clients
            %% containing the updates vars
            %% TODO: replace the txn monitoring with the chain var hooks
            %%       when that gets integrated
            ok = check_for_chain_var_updates(Block),

            %% check if there are any assert v2 txns in the block
            %% for each publish a notification to subsribed clients
            %% containing the Addr of the updated GW
            ok = check_for_asserts(Block);
        _ ->
            %% err what?
            ok
    end.

-spec check_for_chain_var_updates(blockchain_block_v1:block()) -> ok.
check_for_chain_var_updates(Block) ->
    Txns = blockchain_block:transactions(Block),
    FilteredTxns = lists:filter(
        fun(Txn) -> blockchain_txn:type(Txn) == blockchain_txn_vars_v1 end,
        Txns
    ),
    UpdatedKeysPB =
        lists:flatmap(
            fun(VarTxn) ->
                Vars = maps:to_list(blockchain_txn_vars_v1:decoded_vars(VarTxn)),
                [sibyl_utils:ensure(binary, K) || {K, _V} <- Vars]
            end,
            FilteredTxns
        ),
    %% publish an event with the updated vars
    %% all subscribed clients will get the same msg payload
    Notification = sibyl_utils:encode_gateway_resp_v1(
        #gateway_config_update_streamed_resp_v1_pb{keys = UpdatedKeysPB},
        sibyl_mgr:sigfun()
    ),
    Topic = sibyl_utils:make_config_update_topic(),
    sibyl_bus:pub(Topic, {config_update_notify, Notification}),
    lager:debug("notifying clients of chain var updates: ~p", [UpdatedKeysPB]),
    ok.

-spec check_for_asserts(blockchain_block_v1:block()) -> ok.
check_for_asserts(Block) ->
    Txns = blockchain_block:transactions(Block),
    FilteredTxns = lists:filter(
        fun(Txn) ->
            Asserts = [blockchain_txn_assert_location_v1, blockchain_txn_assert_location_v2],
            lists:member(blockchain_txn:type(Txn), Asserts)
        end,
        Txns
    ),
    lists:foreach(
        fun(AssertTxn) ->
            %% for each asserted GW, fire an event
            %% and allow consumers to do any needful
            Type = blockchain_txn:type(AssertTxn),
            GWAddr = Type:gateway(AssertTxn),
            Topic = sibyl_utils:make_asserted_gw_topic(GWAddr),
            lager:debug("notifying clients of assert for gw ~p", [GWAddr]),
            sibyl_bus:pub(Topic, {asserted_gw_notify, GWAddr})
        end,
        FilteredTxns
    ),
    ok.

-spec update_validator_cache(Ledger :: blockchain_ledger_v1:ledger()) -> ok.
update_validator_cache(Ledger) ->
    {ok, HBInterval} = blockchain:config(?validator_liveness_interval, Ledger),
    {ok, HBGrace} = blockchain:config(?validator_liveness_grace_period, Ledger),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    Vals =
        blockchain_ledger_v1:cf_fold(
            validators,
            fun({Addr, BinVal}, Acc) ->
                Validator = blockchain_ledger_validator_v1:deserialize(BinVal),
                case
                    (blockchain_ledger_validator_v1:last_heartbeat(Validator) +
                        HBInterval + HBGrace) >=
                        CurHeight
                of
                    true ->
                        case get_validator_routing(Addr) of
                            {ok, URI} ->
                                [{Addr, URI} | Acc];
                            {error, _} ->
                                Acc
                        end;
                    false ->
                        Acc
                end
            end,
            [],
            Ledger
        ),
    _ = ets:insert(?TID, {?VALIDATORS, Vals}),
    ok.

-spec get_validator_routing(libp2p_crypto:pubkey_bin()) -> {error, any()} | {ok, binary()}.
get_validator_routing(Addr) ->
    case sibyl_utils:address_data([Addr]) of
        [] ->
            {error, no_routing_data};
        [#routing_address_pb{uri = URI}] ->
            {ok, URI}
    end.

-spec add_commit_hooks() -> {ok, [reference() | atom()]}.
add_commit_hooks() ->
    %% add any required commit hooks to the ledger

    %% Routing Related Hooks
    %% we arent interested in receiving incremental/partial updates of route data
    RouteUpdateIncrementalFun = fun(_Update) -> noop end,
    %% we do want to be receive events of when there have been route updates
    %% and those updates for the current block have *all* been applied
    RouteUpdatesEndFun = fun
        (?ROUTING_CF_NAME = _CFName, CFChangedKeys) ->
            lager:debug("firing route update with changed key ~p", [CFChangedKeys]),
            sibyl_bus:pub(
                ?EVENT_ROUTING_UPDATES_END,
                sibyl_utils:make_event(?EVENT_ROUTING_UPDATES_END, CFChangedKeys)
            );
        (_CFName, _ChangedKeys) ->
            noop
    end,
    RoutingRef = blockchain_worker:add_commit_hook(
        ?ROUTING_CF_NAME,
        RouteUpdateIncrementalFun,
        RouteUpdatesEndFun
    ),

    %% State Channel Related Hooks
    %% we are interested in receiving incremental/partial updates of route data
    SCUpdateIncrementalFun = fun(Updates) ->
        lager:debug("handling SC Updates ~p", [Updates]),
        lists:foreach(
            fun
                ({_CF, put, Key, Value}) ->
                    %% note: the key will be a combo of <<owner, sc_id>>
                    SCTopic = sibyl_utils:make_sc_topic(Key),
                    lager:debug("publishing SC put event for key ~p and topic ~p", [Key, SCTopic]),
                    sibyl_bus:pub(
                        SCTopic,
                        sibyl_utils:make_event(SCTopic, {put, Key, Value})
                    );
                ({_CF, delete, Key}) ->
                    %% note: the key will be a combo of <<owner, sc_id>>
                    SCTopic = sibyl_utils:make_sc_topic(Key),
                    lager:debug("publishing SC delete event for key ~p and topic ~p", [Key, SCTopic]),
                    sibyl_bus:pub(
                        SCTopic,
                        sibyl_utils:make_event(SCTopic, {delete, Key})
                    );
                (_Other) ->
                    lager:debug("got unknown event for SC ~p", [_Other]),
                    noop
            end,
            Updates
        )
    end,
    %% we do NOT want to be receive events of when there have been state channels updates
    %% and those updates for the current block have *all* been applied
    SCUpdatesEndFun = fun(_CFName, _Update) -> noop end,

    SCRef = blockchain_worker:add_commit_hook(
        ?STATE_CHANNEL_CF_NAME,
        SCUpdateIncrementalFun,
        SCUpdatesEndFun
    ),
    lager:debug("added commit hooks ~p ~p", [RoutingRef, SCRef]),
    {ok, [RoutingRef, SCRef]}.

-spec subscribe_to_events() -> ok.
subscribe_to_events() ->
    %% subscribe to events the mgr is interested in
    [sibyl_bus:sub(E, self()) || E <- [?EVENT_ROUTING_UPDATES_END, ?EVENT_STATE_CHANNEL_UPDATE]],
    ok.
