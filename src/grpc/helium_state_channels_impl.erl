-module(helium_state_channels_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").
-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").

-define(SC_CLOSED, close_state_closed).
-define(SC_CLOSING, close_state_closing).
-define(SC_CLOSABLE, close_state_closable).
-define(SC_DISPUTE, close_state_dispute).

-type sc_state() :: undefined | ?SC_CLOSED | ?SC_CLOSING | ?SC_CLOSABLE | ?SC_DISPUTE.

-type sc_ledger() :: blockchain_ledger_state_channel_v1 | blockchain_ledger_state_channel_v2.

-type follow() ::
    %% v1 or v2 SC ledger module
    {
        SCLedgerMod :: sc_ledger(),
        %% ID of the SC
        SCID :: binary(),
        %% height at which point the SC will expire
        SCExpireAtHeight :: non_neg_integer(),
        %% the last state the SC was determined to be in
        SCLastState :: sc_state(),
        %% the last block height at which we processed the SC
        SCLastBlockTime :: non_neg_integer()
    }.

-record(handler_state, {
    %% tracks which SC we are following
    sc_follows = #{} :: #{binary() => follow()},
    %% tracks which SCs we have send a closed msg for
    sc_closes_sent = [] :: list(),
    %% tracks which SCs we have send a closing msg for
    sc_closings_sent = [] :: list(),
    %% tracks which SCs we have send a closable msg for
    sc_closables_sent = [] :: list(),
    %% tracks which SCs we have send a dispute msg for
    sc_disputes_sent = [] :: list()
}).

-export([
    init/2,
    is_active_sc/2,
    is_overpaid_sc/2,
    close_sc/2,
    follow_sc/2,
    handle_info/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_state_channels_bhvr callbacks
%% ------------------------------------------------------------------
-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    lager:info("handler init, stream state ~p", [StreamState]),
    %% subscribe to block events so we can get blocktime
    ok = blockchain_event:add_handler(self()),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #handler_state{}
    ),
    NewStreamState.

-spec is_active_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_is_active_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_active_sc(Ctx, #gateway_sc_is_active_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    is_active_sc(Chain, Ctx, Message).

-spec is_overpaid_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_is_overpaid_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_overpaid_sc(Ctx, #gateway_sc_is_overpaid_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    is_overpaid_sc(Chain, Ctx, Message).

-spec close_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_close_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()}.
close_sc(Ctx, #gateway_sc_close_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    close_sc(Chain, Ctx, Message).

-spec follow_sc(
    gateway_pb:gateway_sc_follow_req_v1(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
follow_sc(#gateway_sc_follow_req_v1_pb{sc_id = SCID, sc_owner = SCOwner} = Msg, StreamState) ->
    Chain = sibyl_mgr:blockchain(),
    #handler_state{sc_follows = SCFollows} = grpcbox_stream:stream_handler_state(StreamState),
    Key = blockchain_ledger_v1:state_channel_key(SCID, SCOwner),
    follow_sc(Chain, maps:is_key(Key, SCFollows), Msg, StreamState).

-spec handle_info(any(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info({blockchain_event, {add_block, BlockHash, _Sync, _Ledger} = _Event}, StreamState) ->
    %% for each add block event, we get the block height and use this to determine
    %% if we need to send any event msgs back to the client relating to close state
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    SCGrace = get_sc_grace(Ledger),
    NewStreamState =
        case blockchain:get_block(BlockHash, Chain) of
            {ok, Block} ->
                BlockHeight = blockchain_block:height(Block),
                lager:info("processing add_block event for height ~p", [
                    BlockHeight
                ]),
                process_sc_block_events(BlockHeight, SCGrace, StreamState);
            _ ->
                %% hmm do nothing...
                StreamState
        end,
    NewStreamState;
handle_info(
    {event, _EventTopic, _Payload} = Event,
    StreamState
) ->
    lager:info("received event ~p", [Event]),
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
-spec is_active_sc(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_sc_is_active_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_active_sc(undefined = _Chain, _Ctx, #gateway_sc_is_active_req_v1_pb{} = _Msg) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
is_active_sc(
    Chain,
    Ctx,
    #gateway_sc_is_active_req_v1_pb{sc_id = SCID, sc_owner = SCOwner} = _Message
) ->
    lager:info("executing RPC is_active with msg ~p", [_Message]),
    Ledger = blockchain:ledger(Chain),
    Response0 =
        case get_ledger_state_channel(SCID, SCOwner, Ledger) of
            {ok, Mod, SC} ->
                #gateway_sc_is_active_resp_v1_pb{
                    active = true,
                    sc_id = SCID,
                    sc_owner = SCOwner,
                    sc_expiry_at_block = Mod:expire_at_block(SC),
                    sc_original_dc_amount = get_sc_original(Mod, SC)
                };
            _ ->
                #gateway_sc_is_active_resp_v1_pb{
                    active = false,
                    sc_id = SCID,
                    sc_owner = SCOwner,
                    sc_expiry_at_block = undefined,
                    sc_original_dc_amount = undefined
                }
        end,
    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
        sibyl_mgr:sigfun()
    ),
    {ok, Response1, Ctx}.

-spec is_overpaid_sc(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_sc_is_overpaid_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_overpaid_sc(undefined = _Chain, _Ctx, #gateway_sc_is_overpaid_req_v1_pb{} = _Msg) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
is_overpaid_sc(
    Chain,
    Ctx,
    #gateway_sc_is_overpaid_req_v1_pb{sc_id = SCID, sc_owner = SCOwner, total_dcs = TotalDCs} =
        _Message
) ->
    lager:info("executing RPC is_overpaid with msg ~p", [_Message]),
    Response0 = #gateway_sc_is_overpaid_resp_v1_pb{
        overpaid = check_is_overpaid_sc(SCID, SCOwner, TotalDCs, Chain),
        sc_id = SCID,
        sc_owner = SCOwner
    },
    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
        sibyl_mgr:sigfun()
    ),
    {ok, Response1, Ctx}.

-spec close_sc(
    blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_sc_close_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()}.
close_sc(undefined = _Chain, _Ctx, #gateway_sc_close_req_v1_pb{} = _Msg) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
close_sc(_Chain, Ctx, #gateway_sc_close_req_v1_pb{close_txn = CloseTxn} = _Message) ->
    lager:info("executing RPC close with msg ~p", [_Message]),
    %% TODO, maybe validate the SC exists ? but then if its a v1 it could already have been
    %% deleted from the ledger.....
    SC = blockchain_txn_state_channel_close_v1:state_channel(CloseTxn),
    SCID = blockchain_state_channel_v1:id(SC),
    ok = blockchain_worker:submit_txn(CloseTxn),
    Response0 = #gateway_sc_close_resp_v1_pb{sc_id = SCID, response = <<"ok">>},
    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
        sibyl_mgr:sigfun()
    ),
    {ok, Response1, Ctx}.

-spec follow_sc(
    blockchain:blockchain(),
    boolean(),
    gateway_pb:gateway_follow_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
follow_sc(
    undefined = _Chain,
    _IsAlreadyFolowing,
    #gateway_sc_follow_req_v1_pb{} = _Msg,
    _StreamState
) ->
    % if chain not up we have no way to return state channel data so just return a 14/503
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
follow_sc(
    Chain,
    false = _IsAlreadyFolowing,
    #gateway_sc_follow_req_v1_pb{sc_id = SCID, sc_owner = SCOwner} = _Msg,
    StreamState
) ->
    %% we are not already following this SC, so lets start things rolling
    lager:info("executing RPC follow for sc id ~p and owner ~p", [SCID, SCOwner]),
    %% get the SC from the ledger
    Ledger = blockchain:ledger(Chain),
    SCGrace = get_sc_grace(Ledger),
    {ok, SCLedgerMod, SC} = get_ledger_state_channel(SCID, SCOwner, Ledger),
    SCExpireAtHeight = SCLedgerMod:expire_at_block(SC),
    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
    lager:debug("sc id ~p will expire at height ~p.  Current height: ~p", [
        SCID,
        SCExpireAtHeight,
        CurHeight
    ]),
    %% we want to know when any changes to this SC are applied to the ledger
    %% such as it being closed, so subscribe to events for this SC
    %% the events are published by the ledger commit hooks ( setup via siby_mgr )

    %% the ledger SCs are keyed on combo of sc id and the owner
    %% the ledger commit hooks will publish using this key
    %% so subscribe using same key
    %% as we also have the standalone SCID value in state we can utilise that were needed
    LedgerSCID = blockchain_ledger_v1:state_channel_key(SCID, SCOwner),
    SCTopic = sibyl_utils:make_sc_topic(LedgerSCID),
    lager:info("subscribing to SC events for key ~p and topic ~p", [LedgerSCID, SCTopic]),
    ok = sibyl_bus:sub(SCTopic, self()),
    %% add this SC to our follow list
    #handler_state{sc_follows = SCFollows} =
        HandlerState = grpcbox_stream:stream_handler_state(
            StreamState
        ),
    NewStreamState0 = grpcbox_stream:stream_handler_state(
        StreamState,
        HandlerState#handler_state{
            sc_follows = maps:put(
                LedgerSCID,
                {SCLedgerMod, SCID, SCOwner, SCExpireAtHeight, undefined, CurHeight},
                SCFollows
            )
        }
    ),
    %% process the SC in case for the current blockheight
    %% we may need to send a msg to client informing of state
    %% for example if they started following after it closed
    NewStreamState1 = process_sc_block_events(
        LedgerSCID,
        {SCLedgerMod, SCID, SCOwner, SCExpireAtHeight, undefined, CurHeight},
        CurHeight,
        SCGrace,
        NewStreamState0
    ),
    {ok, NewStreamState1};
follow_sc(_Chain, true = _IsAlreadyFolowing, #gateway_sc_follow_req_v1_pb{} = _Msg, StreamState) ->
    %% we are already following this SC - ignore
    lager:info("ignoring dup follow. Msg ~p", [_Msg]),
    {ok, StreamState}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec handle_event(sibyl_mgr:event(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_event(
    {event, _EventTopic, {delete, LedgerSCID}} = _Event,
    StreamState
) ->
    %% if a V1 SC we are following is closed at the ledger side we will receive a delete event
    %% from the ledger commit hook.
    %% the payload will be the ledger key of the SC ( combo of <<owner, sc_id>> )
    %% We use this event to identify when a V1 SC becomes closed
    %% and send the corresponding closed event to the client
    %% V2 SCs are not deleted from the ledger upon close instead their close_state is updated
    %% for those the commit hooks will generate a PUT event ( handled elsewhere )
    {ok, CurHeight} = get_height(),
    lager:info("handling delete state channel for ledger key ~p at height ~p", [
        LedgerSCID,
        CurHeight
    ]),
    #handler_state{sc_closes_sent = SCClosesSent, sc_follows = SCFollows} =
        HandlerState = grpcbox_stream:stream_handler_state(
            StreamState
        ),
    %% use the ledger key to get the standalone SC ID from our follow list
    %% and then determine if we need to send an updated msg to the client
    case maps:get(LedgerSCID, SCFollows, not_found) of
        {SCMod, SCID, SCOwner, SCExpireAtHeight, SCLastState, SCLastHeight} ->
            {WasSent, NewStreamState, NewClosesSent} = maybe_send_follow_msg(
                lists:member(SCID, SCClosesSent),
                SCID,
                SCOwner,
                {?SC_CLOSED, SCClosesSent},
                CurHeight,
                SCLastState,
                SCLastHeight,
                StreamState
            ),
            UpdatedSCState =
                case WasSent of
                    true -> ?SC_CLOSED;
                    false -> SCLastState
                end,
            grpcbox_stream:stream_handler_state(
                NewStreamState,
                HandlerState#handler_state{
                    sc_follows = maps:put(
                        LedgerSCID,
                        {SCMod, SCID, SCOwner, SCExpireAtHeight, UpdatedSCState, CurHeight},
                        SCFollows
                    ),
                    sc_closes_sent = NewClosesSent
                }
            );
        not_found ->
            %% if we dont have a matching entry in the follow list do nothing
            StreamState
    end;
handle_event(
    {event, _EventTopic, {put, LedgerSCID, Payload}} = _Event,
    StreamState
) ->
    lager:info("handling updated state channel for ledger key ~p", [LedgerSCID]),
    %% V2 SCs are not deleted in the same way as V1 SCs when they are closed
    %% instead the SC state is updated to closed or dispute on the ledger
    %% and in these cases we will get a PUT event from the ledger commit hooks
    %% This is unlike for SC V1s, where we will get a delete event as they are deleted from the ledger
    %% we will also get put events for V1 SCs, but we can ignore those
    %% we only want to handle a V2 SC which has been updated to closed or dispute state
    FinalStreamState =
        case deserialize_sc(Payload) of
            {v1, _SC} ->
                StreamState;
            {v2, SC} ->
                case blockchain_ledger_state_channel_v2:close_state(SC) of
                    closed ->
                        #handler_state{sc_closes_sent = SCClosesSent, sc_follows = SCFollows} =
                            HandlerState = grpcbox_stream:stream_handler_state(
                                StreamState
                            ),
                        %% use the ledger key to get the standalone SC ID from our follow list
                        case maps:get(LedgerSCID, SCFollows, not_found) of
                            {SCMod, SCID, SCOwner, SCExpireAtHeight, SCLastState, SCLastBlockTime} ->
                                {ok, CurHeight} = get_height(),
                                lager:info(
                                    "got PUT for V2 SC ~p with close state ~p at height ~p",
                                    [
                                        SCID,
                                        ?SC_CLOSED,
                                        CurHeight
                                    ]
                                ),

                                {WasSent, NewStreamState, NewClosesSent} = maybe_send_follow_msg(
                                    lists:member(SCID, SCClosesSent),
                                    SCID,
                                    SCOwner,
                                    {?SC_CLOSED, SCClosesSent},
                                    CurHeight,
                                    SCLastState,
                                    SCLastBlockTime,
                                    StreamState
                                ),
                                UpdatedSCState =
                                    case WasSent of
                                        true -> ?SC_CLOSED;
                                        false -> SCLastState
                                    end,
                                grpcbox_stream:stream_handler_state(
                                    NewStreamState,
                                    HandlerState#handler_state{
                                        sc_follows = maps:put(
                                            LedgerSCID,
                                            {SCMod, SCID, SCOwner, SCExpireAtHeight, UpdatedSCState,
                                                CurHeight},
                                            SCFollows
                                        ),
                                        sc_closes_sent = NewClosesSent
                                    }
                                );
                            not_found ->
                                %% if we dont have a matching entry in the follow list do nothing
                                StreamState
                        end;
                    _ ->
                        StreamState
                end
        end,
    FinalStreamState;
handle_event(
    {event, _EventType, _Payload} = _Event,
    StreamState
) ->
    lager:warning("received unhandled event ~p", [_Event]),
    StreamState.

-spec process_sc_block_events(non_neg_integer(), non_neg_integer(), grpcbox_stream:t()) ->
    grpcbox_stream:t().
%% TODO - verify the exact scenarios/triggers for the closing and closable state
%%        what is below is a best guess for now
process_sc_block_events(BlockTime, SCGrace, StreamState) ->
    %% for each SC we are following, check if we are now in a closable or closing state
    %% ( we will derive close and dispute states from the ledger update events )
    #handler_state{sc_follows = SCFollows} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    maps:fold(
        fun(K, V, AccStreamState) ->
            process_sc_block_events(K, V, BlockTime, SCGrace, AccStreamState)
        end,
        StreamState,
        SCFollows
    ).

-spec process_sc_block_events(
    binary(),
    follow(),
    non_neg_integer(),
    non_neg_integer(),
    grpcbox_stream:t()
) -> grpcbox_stream:t().
process_sc_block_events(
    LedgerSCID,
    {SCMod, SCID, SCOwner, SCExpireAtHeight, SCLastState, SCLastBlockTime},
    BlockTime,
    _SCGrace,
    StreamState
) when
    BlockTime == SCExpireAtHeight andalso
        BlockTime > SCLastBlockTime andalso
        (SCLastState /= ?SC_CLOSED andalso SCLastState /= ?SC_DISPUTE)
->
    %% send the client a 'closable' msg if the blocktime is same as the SC expire time
    %% unless we previously entered the closed or dispute state
    lager:info("process_sc_block_events: block time same as SCExpireHeight", []),
    %% send closeable event if not previously sent
    #handler_state{sc_closables_sent = SCClosablesSent} =
        HandlerState = grpcbox_stream:stream_handler_state(
            StreamState
        ),
    {WasSent, NewStreamState, NewClosablesSent} = maybe_send_follow_msg(
        lists:member(SCID, SCClosablesSent),
        SCID,
        SCOwner,
        {?SC_CLOSABLE, SCClosablesSent},
        BlockTime,
        SCLastState,
        SCLastBlockTime,
        StreamState
    ),
    #handler_state{sc_follows = SCFollows} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    UpdatedSCState =
        case WasSent of
            true -> ?SC_CLOSABLE;
            _ -> SCLastState
        end,
    grpcbox_stream:stream_handler_state(
        NewStreamState,
        HandlerState#handler_state{
            sc_follows = maps:put(
                LedgerSCID,
                {SCMod, SCID, SCOwner, SCExpireAtHeight, UpdatedSCState, BlockTime},
                SCFollows
            ),
            sc_closables_sent = NewClosablesSent
        }
    );
process_sc_block_events(
    LedgerSCID,
    {SCMod, SCID, SCOwner, SCExpireAtHeight, SCLastState, SCLastBlockTime},
    BlockTime,
    SCGrace,
    StreamState
) when
    BlockTime >= SCExpireAtHeight + (SCGrace div 3) andalso
        BlockTime =< SCExpireAtHeight + SCGrace andalso
        BlockTime > SCLastBlockTime andalso
        (SCLastState /= ?SC_CLOSED andalso SCLastState /= ?SC_DISPUTE)
->
    %% send the client a 'closing' msg if we are past SCExpireTime and within the grace period
    %% unless we previously entered the closed or dispute state
    lager:info("process_sc_block_events: block time within SC expire-at grace time", []),
    %% send closing event if not previously sent
    #handler_state{sc_closings_sent = SCClosingsSent} =
        HandlerState = grpcbox_stream:stream_handler_state(
            StreamState
        ),
    {WasSent, NewStreamState, NewClosingsSent} = maybe_send_follow_msg(
        lists:member(SCID, SCClosingsSent),
        SCID,
        SCOwner,
        {?SC_CLOSING, SCClosingsSent},
        BlockTime,
        SCLastState,
        SCLastBlockTime,
        StreamState
    ),
    UpdatedSCState =
        case WasSent of
            true -> ?SC_CLOSING;
            _ -> SCLastState
        end,
    #handler_state{sc_follows = SCFollows} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    grpcbox_stream:stream_handler_state(
        NewStreamState,
        HandlerState#handler_state{
            sc_follows = maps:put(
                LedgerSCID,
                {SCMod, SCID, SCOwner, SCExpireAtHeight, UpdatedSCState, BlockTime},
                SCFollows
            ),
            sc_closings_sent = NewClosingsSent
        }
    );
process_sc_block_events(
    _LedgerSCID,
    {_SCMod, _SCID, _SCOwner, _SCExpireAtHeight, _SCLastState, _SCLastBlockTime},
    _BlockTime,
    _SCGrace,
    StreamState
) ->
    lager:info("process_sc_block_events: nothing to do for SC ~p at blocktime ~p", [
        _SCID,
        _BlockTime
    ]),
    StreamState.

-spec maybe_send_follow_msg(
    boolean(),
    binary(),
    binary(),
    {sc_state(), [binary()]},
    non_neg_integer(),
    sc_state(),
    non_neg_integer(),
    grpcbox_stream:t()
) -> {boolean(), grpcbox_stream:t(), list()}.
maybe_send_follow_msg(
    true = _SentPreviously,
    SCID,
    SCOwner,
    {SCNewState, SendList},
    Height,
    SCOldState,
    SCLastBlockTime,
    StreamState
) when SCNewState /= SCOldState andalso Height > SCLastBlockTime ->
    %% we previously did send this state to the client but the state must have subsequently changed
    %% so we can resend it, for example state went from closed -> dispute -> closed
    send_follow_msg(
        SCID,
        SCOwner,
        {SCNewState, lists:delete(SCID, SendList)},
        Height,
        SCOldState,
        StreamState
    );
maybe_send_follow_msg(
    true = _SentPreviously,
    _SCID,
    _SCOwner,
    {_SCNewState, SendList},
    _Height,
    _SCOldState,
    _SCLastBlockTime,
    StreamState
) ->
    %% if we have already sent a msg with the state to the client, dont send again
    {false, StreamState, SendList};
maybe_send_follow_msg(
    false = _SentPreviously,
    SCID,
    SCOwner,
    {SCNewState, SendList},
    Height,
    SCOldState,
    _SCLastBlockTime,
    StreamState
) ->
    %% client has not been sent a msg with this state, so lets send it
    send_follow_msg(SCID, SCOwner, {SCNewState, SendList}, Height, SCOldState, StreamState).

-spec send_follow_msg(
    binary(),
    binary(),
    {sc_state(), [binary()]},
    non_neg_integer(),
    sc_state(),
    grpcbox_stream:t()
) -> {boolean(), grpcbox_stream:t(), list()}.
send_follow_msg(SCID, SCOwner, {SCNewState, SendList}, _Height, _SCOldState, StreamState) ->
    lager:info("sending SC event ~p for SCID ~p and SCOwner ~p", [SCNewState, SCID, SCOwner]),
    Msg0 = #gateway_sc_follow_streamed_resp_v1_pb{
        close_state = SCNewState,
        sc_owner = SCOwner,
        sc_id = SCID
    },
    Msg1 = sibyl_utils:encode_gateway_resp_v1(
        Msg0,
        sibyl_mgr:sigfun()
    ),
    NewStreamState = grpcbox_stream:send(false, Msg1, StreamState),
    {true, NewStreamState, [SCID | SendList]}.

-spec check_is_overpaid_sc(
    SCID :: binary(),
    SCOwner :: libp2p_crypto:pubkey_bin(),
    TotalDCs :: non_neg_integer(),
    Chain :: blockchain:blockchain()
) -> true | false.
check_is_overpaid_sc(SCID, SCOwner, TotalDCs, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case get_ledger_state_channel(SCID, SCOwner, Ledger) of
        {ok, blockchain_ledger_state_channel_v2, SC} ->
            blockchain_ledger_state_channel_v2:original(SC) < TotalDCs;
        _ ->
            false
    end.

-spec get_ledger_state_channel(binary(), binary(), blockchain_ledger_v1:ledger()) ->
    {ok, sc_ledger(), blockchain_state_channel_v1:state_channel()} | {error, any()}.
get_ledger_state_channel(SCID, Owner, Ledger) ->
    case blockchain_ledger_v1:find_state_channel_with_mod(SCID, Owner, Ledger) of
        {ok, Mod, SC} -> {ok, Mod, SC};
        _ -> {error, inactive_sc}
    end.

-spec get_height() -> {ok, non_neg_integer()}.
get_height() ->
    Chain = sibyl_mgr:blockchain(),
    Ledger = blockchain:ledger(Chain),
    blockchain_ledger_v1:current_height(Ledger).

-spec get_sc_grace(blockchain_ledger_v1:ledger()) -> non_neg_integer().
get_sc_grace(Ledger) ->
    case blockchain:config(?sc_grace_blocks, Ledger) of
        {ok, G} -> G;
        _ -> 0
    end.

-spec deserialize_sc(binary()) ->
    {v1, blockchain_state_channel_v1:state_channel()}
    | {v2, blockchain_state_channel_v1:state_channel()}.
deserialize_sc(SC = <<1, _/binary>>) ->
    {v1, blockchain_ledger_state_channel_v1:deserialize(SC)};
deserialize_sc(SC = <<2, _/binary>>) ->
    {v2, blockchain_ledger_state_channel_v2:deserialize(SC)}.

-spec get_sc_original(
    blockchain_ledger_state_channel_v1
    | blockchain_ledger_state_channel_v2,
    blockchain_ledger_state_channel_v1:state_channel()
    | blockchain_ledger_state_channel_v2:state_channel()
) -> non_neg_integer().
get_sc_original(blockchain_ledger_state_channel_v1, _SC) ->
    0;
get_sc_original(blockchain_ledger_state_channel_v2, SC) ->
    blockchain_ledger_state_channel_v2:original(SC).
