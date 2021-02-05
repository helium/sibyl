-module(sibyl_mgr).

-behaviour(gen_server).

-include("../include/sibyl.hrl").
-include("grpc/autogen/server/validator_state_channels_pb.hrl").

-define(TID, val_mgr).
-define(CHAIN, blockchain).
-define(HEIGHT, height).
-define(SIGFUN, sigfun).
-define(SERVER, ?MODULE).
-define(ROUTING_CF_NAME, routing).
-define(STATE_CHANNEL_CF_NAME, state_channels).

-type event_type() :: binary().
-type event_types() :: [event_type()].
-type event() :: {event, binary(), any()} | {event, binary()}.

-export_type([event_type/0, event_types/0, event/0]).

-record(state, {
    tid :: ets:tab(),
    commit_hook_refs = [] :: list()
}).

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
    sigfun/0
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
                    ok;
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
    lager:info("init with args ~p", [Args]),
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
handle_info({blockchain_event, {new_chain, NC}}, State = #state{commit_hook_refs = Refs}) ->
    catch [blockchain_worker:remove_commit_hook(R) || R <- Refs],
    ets:insert(?TID, {?CHAIN, NC}),
    {ok, NewRefs} = add_commit_hooks(),
    {noreply, State#state{commit_hook_refs = NewRefs}};
handle_info(
    {event, EventTopic} = _Msg,
    State
) when EventTopic == ?EVENT_ROUTING_UPDATES_END ->
    %% ledger routes must have been updated
    %% send the updated routes to all connected peers
    Chain = ?MODULE:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    {ok, Routes} = blockchain_ledger_v1:get_routes(Ledger),
    SigFun = ?MODULE:sigfun(),
    ClientUpdatePB = sibyl_utils:encode_routing_update_response(Routes, CurHeight, SigFun),
    erlbus:pub(
        ?EVENT_ROUTING_UPDATE,
        sibyl_utils:make_event(?EVENT_ROUTING_UPDATE, ClientUpdatePB)
    ),
    %% update cache with the height at which the routes have been updated
    true = ?MODULE:update_last_modified(?EVENT_ROUTING_UPDATE, CurHeight),
    lager:debug("updated last modified height for event ~p with height ~p", [
        ?EVENT_ROUTING_UPDATE,
        CurHeight
    ]),
    {noreply, State};
%%handle_info(
%%    {event, EventTopic, UpdatedSC} = _Msg,
%%    State
%%) when EventTopic == ?EVENT_STATE_CHANNEL_UPDATE ->
%%    %% a state channel has been updated
%%    %% get its ID and republish it to a SC ID specific topic
%%    %% thus subscribers only receive SC updates of those they are specifically following
%%    Chain = ?MODULE:blockchain(),
%%    Ledger = blockchain:ledger(Chain),
%%    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
%%    SCID = blockchain_state_channel_v1:id(UpdatedSC),
%%    Response0 = #validator_sc_follow_resp_v1_pb{
%%        sc = UpdatedSC
%%    },
%%    Response1 = sibyl_utils:encode_validator_resp_v1(Response0, CurHeight, sibyl_mgr:sigfun()),
%%    SCTopic = sibyl_utils:make_sc_topic(SCID),
%%    erlbus:pub(
%%        SCTopic,
%%        sibyl_utils:make_event(SCTopic, Response1)
%%    ),
%%    {noreply, State};
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
-spec add_commit_hooks() -> {ok, [reference() | atom()]}.
add_commit_hooks() ->
    %% add any required commit hooks to the ledger

    %% Routing Related Hooks
    %% we arent interested in receiving incremental/partial updates of route data
    RouteUpdateIncrementalFun = fun(_Update) -> noop end,
    %% we do want to be receive events of when there have been route updates
    %% and those updates for the current block have *all* been applied
    RouteUpdatesEndFun = fun
        (?ROUTING_CF_NAME = _CFName) ->
            erlbus:pub(
                ?EVENT_ROUTING_UPDATES_END,
                sibyl_utils:make_event(?EVENT_ROUTING_UPDATES_END)
            );
        (_CFName) ->
            noop
    end,
    RoutingRef = blockchain_worker:add_commit_hook(
        ?ROUTING_CF_NAME,
        RouteUpdateIncrementalFun,
        RouteUpdatesEndFun
    ),

    %% State Channel Related Hooks
    %% we are interested in receiving incremental/partial updates of route data

    SCUpdateIncrementalFun = fun(UpdatedSC) ->
        SCID = blockchain_state_channel_v1:id(UpdatedSC),
        SCTopic = sibyl_utils:make_sc_topic(SCID),
        erlbus:pub(
            SCTopic,
            sibyl_utils:make_event(SCTopic, UpdatedSC)
        )
    end,
    %% we do NOT want to be receive events of when there have been state channels updates
    %% and those updates for the current block have *all* been applied
    SCUpdatesEndFun = fun(_Update) -> noop end,

    SCRef = blockchain_worker:add_commit_hook(
        ?STATE_CHANNEL_CF_NAME,
        SCUpdateIncrementalFun,
        SCUpdatesEndFun
    ),

    {ok, [RoutingRef, SCRef]}.

-spec subscribe_to_events() -> ok.
subscribe_to_events() ->
    %% subscribe to events the mgr is interested in
    [erlbus:sub(self(), E) || E <- [?EVENT_ROUTING_UPDATES_END, ?EVENT_STATE_CHANNEL_UPDATE]],
    ok.
