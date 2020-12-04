-module(sibyl_mgr).

-behaviour(gen_server).

-include("../include/sibyl.hrl").

-define(TID, val_mgr).
-define(CHAIN, blockchain).
-define(SIGFUN, sigfun).
-define(SERVER, ?MODULE).

-type event() :: binary().

-type events() :: [event()].

-export_type([event/0, events/0]).

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
    start_link/0,
    update_last_modified/2,
    get_last_modified/1,
    blockchain/0,
    sigfun/0
]).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec update_last_modified(event(), non_neg_integer()) -> true.
update_last_modified(Event, Height) ->
    ets:insert(?TID, {Event, Height}).

-spec get_last_modified(event()) -> non_neg_integer().
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

-spec sigfun() -> function() | undefined.
sigfun() ->
    try ets:lookup_element(?TID, ?SIGFUN, 2) of
        X -> X
    catch
        _:_ -> undefined
    end.

%% ------------------------------------------------------------------
%% gen_server functions
%% ------------------------------------------------------------------
init(_Args) ->
    process_flag(trap_exit, true),
    lager:info("init with args ~p", [_Args]),
    TID = ets:new(?TID, [public, ordered_set, named_table, {read_concurrency, true}]),
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
            ok = blockchain_event:add_handler(self()),
            {ok, _, SigFun, _} = blockchain_swarm:keys(),
            ets:insert(?TID, {?CHAIN, Chain}),
            ets:insert(?TID, {?SIGFUN, SigFun}),
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
    {event, EventTopic, _Updates} = _Msg,
    State
) ->
    Chain = ?MODULE:blockchain(),
    Ledger = blockchain:ledger(Chain),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    true = ?MODULE:update_last_modified(EventTopic, CurHeight),
    lager:debug("updated last modified height for event ~p with height ~p", [EventTopic, CurHeight]),
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
    %% so as we can get updates for those CFs we are interested in
    RoutingFun = fun(RouteUpdate) ->
        erlbus:pub(?EVENT_ROUTING_UPDATE, {event, ?EVENT_ROUTING_UPDATE, RouteUpdate})
    end,
    Ref = blockchain_worker:add_commit_hook(routing, RoutingFun),
    {ok, [Ref]}.

-spec subscribe_to_events() -> ok.
subscribe_to_events() ->
    %% the mgr will subscribe to all published hook events
    %% and for each event type update the height in its ETS table
    %% at which the type was last updated
    %% it wont actually process the events
    [erlbus:sub(self(), E) || E <- ?ALL_EVENTS],
    ok.
