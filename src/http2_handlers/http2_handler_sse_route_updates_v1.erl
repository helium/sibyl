-module(http2_handler_sse_route_updates_v1).

-behavior(lib_http2_handler).

-include("../../include/sibyl.hrl").

-include_lib("lib_http2_handler/include/http2_handler.hrl").

-include_lib("helium_proto/include/routing_v1_pb.hrl").

-record(handler_state, {}).

%% ------------------------------------------------------------------
%% lib_http2_stream exports
%% ------------------------------------------------------------------
-export([
    handle_on_request_end_stream/2,
    handle_info/2,
    validations/0
]).

%% ------------------------------------------------------------------
%% lib_http2_stream callbacks
%% ------------------------------------------------------------------
validations() ->
    [
        {<<":method">>, fun(V) -> V =:= <<"GET">> end, <<"405">>, <<"method not supported">>}
    ].

handle_on_request_end_stream(
    _Method,
    State
) ->
    %% subscribe to events using the relevant topic
    erlbus:sub(self(), ?EVENT_ROUTING_UPDATE),
    %% return the event-stream header to client
    {ok,
        State#state{
            request_data = <<>>,
            handler_state = #handler_state{}
        },
        [
            {send_headers, [
                {<<":status">>, <<"200">>},
                {<<"content-type">>, <<"text/event-stream">>}
            ]}
        ]}.

%% ------------------------------------------------------------------
%% info msg callbacks
%% ------------------------------------------------------------------
handle_info(
    {event, EventTopic, Updates} = _Msg,
    State
) when EventTopic =:= ?EVENT_ROUTING_UPDATE ->
    {ok, State, handle_routing_updates(State, EventTopic, Updates)};
handle_info(
    _Msg,
    State = #state{}
) ->
    lager:debug("unhandled info msg: ~p", [_Msg]),
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec handle_routing_updates(any(), sibyl_mgr:event(), [blockchain_ledger_routing_v1:routing()]) ->
    [lib_http2_stream:action()].
handle_routing_updates(
    #state{
        client_ref = ClientRef,
        stream_id = StreamId
    },
    Topic,
    Updates
) ->
    Ledger = blockchain:ledger(sibyl_mgr:blockchain()),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    true = sibyl_mgr:update_last_modified(Topic, Height),
    %% get the sigfun which will be used to sign event payloads sent to the client
    SigFun = sibyl_mgr:sigfun(),
    lists:foldl(
        fun(Update, AccActions) ->
            {_Ref, Action, _Something, RoutePB} = Update,
            Route = blockchain_ledger_routing_v1:deserialize(RoutePB),

            Bin = serialize_response(Action, Route, Height, SigFun),
            ?LOGGER(debug, ClientRef, StreamId, "sending event:  ~p", [
                Route
            ]),
            SSEEncodedBin = lib_http2_utils:encode_sse(Bin, Topic),
            [{send_body, SSEEncodedBin, false} | AccActions]
        end,
        [],
        Updates
    ).

-spec serialize_response(
    atom(),
    blockchain_ledger_routing_v1:routing(),
    non_neg_integer(),
    function()
) -> binary().
serialize_response(Action, Route, Height, SigFun) ->
    RouteUpdatePB = to_routing_pb(Route),
    Resp = #routing_v1_update_pb{
        route = RouteUpdatePB,
        height = Height,
        action = sibyl_utils:ensure(binary, Action)
    },
    EncodedRoutingInfoBin = routing_v1_pb:encode_msg(Resp, routing_v1_update_pb),
    routing_v1_pb:encode_msg(
        Resp#routing_v1_update_pb{signature = SigFun(EncodedRoutingInfoBin)},
        routing_v1_update_pb
    ).

-spec to_routing_pb(blockchain_ledger_routing_v1:routing()) -> #routing_v1_pb{}.
to_routing_pb(Route) ->
    #routing_v1_pb{
        oui = blockchain_ledger_routing_v1:oui(Route),
        owner = blockchain_ledger_routing_v1:owner(Route),
        router_addresses = blockchain_ledger_routing_v1:addresses(Route),
        filters = blockchain_ledger_routing_v1:filters(Route),
        subnets = blockchain_ledger_routing_v1:subnets(Route)
    }.
