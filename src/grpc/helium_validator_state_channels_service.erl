-module(helium_validator_state_channels_service).

-behavior(helium_validator_state_channels_bhvr).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/validator_state_channels_pb.hrl").
-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-define(SC_CLOSED, <<"closed">>).
-define(SC_CLOSING, <<"closing">>).
-define(SC_CLOSABLE, <<"closable">>).

-record(handler_state, {
    sc_follows = #{} :: map(),
    sc_closes_sent = [] :: list(),
    sc_closings_sent = [] :: list(),
    sc_closables_sent = [] :: list()
}).

-export([
    init/1,
    is_valid/2,
    close/2,
    follow/2,
    handle_info/2
]).

%% ------------------------------------------------------------------
%% helium_validator_state_channels_bhvr callbacks
%% ------------------------------------------------------------------
-spec init(grpcbox_stream:t()) -> grpcbox_stream:t().
init(StreamState) ->
    lager:debug("handler init, stream state ~p", [StreamState]),
    %% subscribe to block events so we can get blocktime
    ok = blockchain_event:add_handler(self()),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #handler_state{}
    ),
    NewStreamState.

is_valid(Ctx, #validator_sc_is_valid_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    is_valid(Chain, Ctx, Message).

close(Ctx, #validator_sc_close_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    close(Chain, Ctx, Message).

follow(#validator_sc_follow_req_v1_pb{sc_id = SCID} = Msg, StreamState) ->
    Chain = sibyl_mgr:blockchain(),
    #handler_state{sc_follows = FollowList} = grpcbox_stream:stream_handler_state(StreamState),
    follow(Chain, lists:member(SCID, FollowList), Msg, StreamState).

handle_info({blockchain_event, {add_block, BlockHash, _Sync, _Ledger} = _Event}, StreamState) ->
    %% for each add block event, we get the block height and use this to determine
    %% if we need to send any event msgs back to the client relating to close state
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    SCGrace = sc_grace(Ledger),
    case blockchain:get_block(BlockHash, Chain) of
        {ok, Block} ->
            BlockHeight = blockchain_block:height(Block),
            process_sc_close_events(BlockHeight, SCGrace, StreamState);
        _ ->
            %% hmm do nothing...
            noop
    end;
handle_info(
    {event, _EventTopic, _Payload} = Event,
    StreamState
) ->
    lager:debug("received event ~p", [Event]),
    NewStreamState = handle_event(Event, StreamState),
    NewStreamState;
handle_info(
    _Msg,
    StreamState
) ->
    lager:warning("unhandled info msg: ~p", [_Msg]),
    StreamState.

%% ------------------------------------------------------------------
%% callback breakout functions
%% ------------------------------------------------------------------
-spec is_valid(
    blockchain:blockchain(),
    ctx:ctx(),
    validator_state_channels_pb:validator_sc_is_valid_req_v1_pb()
) ->
    {ok, validator_state_channels_pb:validator_resp_v1_pb(), ctx:ctx()}
    | grpcbox_stream:grpc_error_response().
is_valid(undefined = _Chain, _Ctx, #validator_sc_is_valid_req_v1_pb{} = _Msg) ->
    lager:debug("chain not ready, returning error response for msg ", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
is_valid(Chain, Ctx, #validator_sc_is_valid_req_v1_pb{sc = SC} = _Message) ->
    lager:info("executing RPC is_valid with msg ~p", [_Message]),
    SCID = blockchain_state_channel_v1:id(SC),
    {ok, CurHeight} = height(),
    {IsValid, Msg} = is_valid_sc(SC, Chain),
    Response0 = #validator_sc_is_valid_resp_v1_pb{
        valid = IsValid,
        reason = sibyl_utils:ensure(binary, Msg),
        sc_id = SCID
    },
    Response1 = sibyl_utils:encode_validator_resp_v1(Response0, CurHeight, sibyl_mgr:sigfun()),
    {ok, Response1, Ctx}.

-spec close(
    blockchain:blockchain(),
    ctx:ctx(),
    validator_state_channels_pb:validator_sc_close_req_v1_pb()
) -> {ok, validator_state_channels_pb:validator_resp_v1_pb(), ctx:ctx()}.
close(undefined = _Chain, _Ctx, #validator_sc_close_req_v1_pb{} = _Msg) ->
    lager:debug("chain not ready, returning error response for msg ", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
close(_Chain, Ctx, #validator_sc_close_req_v1_pb{close_txn = CloseTxn} = _Message) ->
    lager:debug("executing RPC close with msg ~p", [_Message]),
    SC = blockchain_txn_state_channel_close_v1:state_channel(CloseTxn),
    SCID = blockchain_state_channel_v1:id(SC),
    ok = blockchain_worker:submit_txn(CloseTxn),
    {ok, CurHeight} = height(),
    Response0 = #validator_sc_close_resp_v1_pb{sc_id = SCID, response = <<"ok">>},
    Response1 = sibyl_utils:encode_validator_resp_v1(Response0, CurHeight, sibyl_mgr:sigfun()),
    {ok, Response1, Ctx}.

-spec follow(
    blockchain:blockchain(),
    boolean(),
    state_channel_validator_pb:validator_follow_req_v1_pb(),
    grpcbox_stream:t()
) -> {continue, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
follow(
    undefined = _Chain,
    _IsAlreadyFolowing,
    #validator_sc_follow_req_v1_pb{} = _Msg,
    _StreamState
) ->
    % if chain not up we have no way to return state channel data so just return a 14/503
    lager:debug("chain not ready, returning error response for msg ", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
follow(
    Chain,
    false = _IsAlreadyFolowing,
    #validator_sc_follow_req_v1_pb{sc_id = SCID, owner = SCOwner} = _Msg,
    StreamState
) ->
    %% we are not already following this SC, so lets start things rolling
    lager:debug("RPC follow called with msg ~p", [_Msg]),
    %% get the SC from the ledger
    Ledger = blockchain:ledger(Chain),
    SCGrace = sc_grace(Ledger),
    {ok, SC} = get_ledger_state_channel(SCID, SCOwner, Ledger),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    SCExpireAtHeight = blockchain_ledger_state_channel_v1:expire_at_block(SC),
    SCState = blockchain_ledger_state_channel_v1:state(SC),
    #handler_state{sc_follows = SCFollows} = grpcbox_stream:stream_handler_state(
        StreamState
    ),

    %% we want to know when any changes to this SC are applied to the ledger
    %% such as the SC closing, to subscribe to events for this SC
    %% these are published by the ledger commit hooks ( setup via siby_mgr )
    ok = erlbus:sub(self(), sibyl_utils:make_sc_topic(SCID)),

    %% process the SC in case we need to send a msg to client informing of state
    NewStreamState0 = process_sc_close_events(
        {SCID, SCExpireAtHeight, SCState},
        CurHeight,
        SCGrace,
        StreamState
    ),
    NewStreamState1 = grpcbox_stream:stream_handler_state(
        NewStreamState0,
        #handler_state{
            sc_follows = maps:put(SCID, {SCID, SCExpireAtHeight, SCState}, SCFollows)
        }
    ),
    {continue, NewStreamState1};
follow(_Chain, true = _IsAlreadyFolowing, #validator_sc_follow_req_v1_pb{} = _Msg, StreamState) ->
    %% we are already following this SC - ignore
    lager:debug("ignoring dup follow. Msg ~p", [_Msg]),
    {continue, StreamState}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec handle_event(sibyl_mgr:event(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_event(
    {event, _EventTopic, {delete, SCID}} = _Event,
    StreamState
) ->
    %% if an SC we are following is updated at the ledger side we will receive an event
    %% from the ledger commit hook.  The event payload will be the updated SC
    %% For SCs, this only really happens when a close txn is submitted
    %% We we use this event to determine when an SC becomes closed
    %% and send the corresponding event to the client

    {ok, CurHeight} = height(),
    #handler_state{sc_closes_sent = SCClosesSent} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    {NewStreamState, NewClosesSent} = maybe_send_follow_msg(
        lists:member(SCID, SCClosesSent),
        SCID,
        {?SC_CLOSED, SCClosesSent},
        CurHeight,
        StreamState
    ),
    grpcbox_stream:stream_handler_state(
        NewStreamState,
        #handler_state{
            sc_closes_sent = NewClosesSent
        }
    );
handle_event(
    {event, _EventType, _Payload} = _Event,
    StreamState
) ->
    lager:warning("received unhandled event ~p", [_Event]),
    StreamState.

%% TODO - verify the exact scenarios/triggers for the closing and closable state
%%        what is below is a best guess for now
process_sc_close_events(BlockTime, SCGrace, StreamState) ->
    %% for each SC we are following, check if we are now in a closable or closing state
    %% ( we will derive close state from the ledger update events )
    #handler_state{sc_follows = SCFollows} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    maps:fold(
        fun(I) ->
            process_sc_close_events(I, BlockTime, SCGrace, StreamState)
        end,
        StreamState,
        SCFollows
    ).

process_sc_close_events({SCID, SCExpireAtHeight, _SCState}, BlockTime, _SCGrace, StreamState) when
    BlockTime == SCExpireAtHeight
->
    %% send closeable event if not previously sent
    #handler_state{sc_closables_sent = SCClosablesSent} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    {NewStreamState, NewClosablesSent} = maybe_send_follow_msg(
        lists:member(SCID, SCClosablesSent),
        SCID,
        {?SC_CLOSABLE, SCClosablesSent},
        BlockTime,
        StreamState
    ),
    grpcbox_stream:stream_handler_state(
        NewStreamState,
        #handler_state{
            sc_closables_sent = NewClosablesSent
        }
    );
process_sc_close_events({SCID, SCExpireAtHeight, _SCState}, BlockTime, SCGrace, StreamState) when
    BlockTime >= SCExpireAtHeight + (SCGrace div 3) andalso
        BlockTime =< SCExpireAtHeight + SCGrace
->
    %% send closing event if not previously sent
    #handler_state{sc_closings_sent = SCClosingsSent} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    {NewStreamState, NewClosingsSent} = maybe_send_follow_msg(
        lists:member(SCID, SCClosingsSent),
        SCID,
        {?SC_CLOSING, SCClosingsSent},
        BlockTime,
        StreamState
    ),
    grpcbox_stream:stream_handler_state(
        NewStreamState,
        #handler_state{
            sc_closings_sent = NewClosingsSent
        }
    ).

maybe_send_follow_msg(true = _Send, _SCID, {_SCState, SendList}, _Height, StreamState) ->
    {StreamState, SendList};
maybe_send_follow_msg(false = _Send, SCID, {SCState, SendList}, Height, StreamState) ->
    Msg0 = #validator_sc_follow_streamed_msg_v1_pb{
        close_state = SCState,
        sc_id = SCID
    },
    Msg1 = sibyl_utils:encode_validator_resp_v1(Msg0, Height, sibyl_mgr:sigfun()),
    NewStreamState = grpcbox_stream:send(false, Msg1, StreamState),
    {NewStreamState, [SCID | SendList]}.

-spec is_valid_sc(
    SC :: blockchain_state_channel_v1:state_channel(),
    Chain :: blockchain:blockchain()
) -> boolean().
is_valid_sc(SC, Chain) ->
    %% the ability of the validator to validate an SC is limited
    %% as it does not have the full/current SC as seen by both the
    %% gateway and the router.  As such the validation here is basic
    %% and questionable in terms of its usefulness beyond is it on the ledger ????
    %% For example cannot verify if causally correct, or if summaries
    %% are sane or if there is an overspend
    SCOwner = blockchain_state_channel_v1:owner(SC),
    SCID = blockchain_state_channel_v1:id(SC),
    %% check the SC is active
    case is_active_sc(SCID, SCOwner, Chain) of
        {error, Reason} = _E ->
            {false, Reason};
        ok ->
            {true, <<>>}
    end.

-spec is_active_sc(
    SCID :: binary(),
    SCOwner :: libp2p_crypto:pubkey_bin(),
    Chain :: blockchain:blockchain()
) -> ok | {error, no_chain} | {error, inactive_sc}.
is_active_sc(_, _, undefined) ->
    {error, no_chain};
is_active_sc(SCID, SCOwner, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case get_ledger_state_channel(SCID, SCOwner, Ledger) of
        {ok, _SC} -> ok;
        _ -> {error, inactive_sc}
    end.

%%-spec quick_validate(blockchain_state_channel_v1:state_channel()) -> ok | {error, any()}.
%%quick_validate(SC) ->
%%    BaseSC = SC#blockchain_state_channel_v1_pb{signature = <<>>},
%%    EncodedSC = blockchain_state_channel_v1:encode(BaseSC),
%%    Signature = blockchain_state_channel_v1:signature(SC),
%%    Owner = blockchain_state_channel_v1:owner(SC),
%%    PubKey = libp2p_crypto:bin_to_pubkey(Owner),
%%    case libp2p_crypto:verify(EncodedSC, Signature, PubKey) of
%%        false -> {error, bad_signature};
%%        true -> ok
%%    end.

get_ledger_state_channel(SCID, Owner, Ledger) ->
    case blockchain_ledger_v1:find_state_channel(SCID, Owner, Ledger) of
        {ok, SC} -> {ok, SC};
        _ -> {error, inactive_sc}
    end.

height() ->
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    blockchain_ledger_v1:current_height(Ledger).

sc_grace(Ledger) ->
    case blockchain:config(?sc_grace_blocks, Ledger) of
        {ok, G} -> G;
        _ -> 0
    end.
