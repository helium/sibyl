-module(http2_handler_routes_v1).

-behavior(lib_http2_handler).

-include("../../include/sibyl.hrl").

-include_lib("lib_http2_handler/include/http2_handler.hrl").

-include_lib("helium_proto/include/routing_v1_pb.hrl").

-ifdef(TEST).
-define(TIMEOUT, 4000).
-else.
-define(TIMEOUT, 7000).
-endif.

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
    State = #state{
        request_valid = true,
        app_data = _AppData,
        stream_id = StreamId,
        client_ref = ClientRef,
        route = _Route,
        query_params = QueryParams,
        request_headers = Headers
    }
) ->
    %% get our chain and only handle the request if the chain is up
    % if chain not up we have no way to return routing data so just return a 503
    Chain = sibyl_mgr:blockchain(),
    case is_chain_ready(Chain) of
        false ->
            {ok, State, [
                {send_headers, [{<<":status">>, <<"503">>}]},
                {send_body, <<"temporarily unavavailable">>, true}
            ]};
        true ->
            %% if the client presented the x-last-height header then we will only return
            %% route data if it was modified since that height
            %% if header not presented default last height to 1 and thus always return route data
            ClientLastRequestHeight = sibyl_utils:ensure(
                integer_or_default,
                proplists:get_value(?CLIENT_HEIGHT_HEADER, Headers, 1),
                1
            ),
            LastModifiedHeight = sibyl_mgr:get_last_modified(?EVENT_ROUTING_UPDATE),
            case is_data_modified(ClientLastRequestHeight, LastModifiedHeight) of
                false ->
                    {ok, State, [
                        {send_headers, [{<<":status">>, <<"304">>}]},
                        {send_body, <<"not modified">>, true}
                    ]};
                true ->
                    Ledger = blockchain:ledger(Chain),
                    {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
                    %% get the route data
                    Res =
                        case find_by_eui_or_dev_addr(QueryParams) of
                            all_routes ->
                                blockchain_ledger_v1:get_routes(Ledger);
                            {find_route, {eui, DevEUI, AppEUI}} ->
                                blockchain_ledger_v1:find_routing_via_eui(DevEUI, AppEUI, Ledger);
                            {find_route, {devaddr, DevAddr0}} ->
                                blockchain_ledger_v1:find_routing_via_devaddr(DevAddr0, Ledger)
                        end,

                    %% handle the route data, return response to client
                    case Res of
                        {ok, Routes} ->
                            Bin = serialize_response(Routes, CurHeight, sibyl_mgr:sigfun()),
                            {ok, State#state{request_data = <<>>, handler_state = #handler_state{}},
                                [
                                    {send_headers, [{<<":status">>, <<"200">>}]},
                                    {send_body, Bin, true}
                                ]};
                        {error, _Reason} ->
                            ?LOGGER(
                                warning,
                                ClientRef,
                                StreamId,
                                Route,
                                "failed to decode request, reason: ~p",
                                [
                                    _Reason
                                ]
                            ),
                            {ok, State, [
                                {send_headers, [{<<":status">>, <<"400">>}]},
                                {send_body, <<"bad request">>, true}
                            ]}
                    end
            end
    end.

%% ------------------------------------------------------------------
%% info msg callbacks
%% ------------------------------------------------------------------
handle_info(
    _Msg,
    State = #state{
        stream_id = StreamId,
        client_ref = ClientRef
    }
) ->
    ?LOGGER(info, ClientRef, StreamId, "unhandled info msg: ~p", [
        _Msg
    ]),
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec serialize_response([blockchain_ledger_routing_v1:routing()], non_neg_integer(), function()) ->
    binary().
serialize_response(Routes, Height, SigFun) ->
    RoutingInfo = [to_routing_pb(R) || R <- Routes],
    Resp = #routing_v1_response_pb{
        routes = RoutingInfo,
        height = Height
    },
    EncodedRoutingInfoBin = routing_v1_pb:encode_msg(Resp, routing_v1_response_pb),
    base64:encode(
        routing_v1_pb:encode_msg(
            Resp#routing_v1_response_pb{signature = SigFun(EncodedRoutingInfoBin)},
            routing_v1_response_pb
        )
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

-spec find_by_eui_or_dev_addr([binary()]) ->
    all_routes
    | {find_route, {devaddr, non_neg_integer()}}
    | {find_route, {eui, non_neg_integer(), non_neg_integer()}}.
find_by_eui_or_dev_addr(QueryParams) ->
    FindKey = proplists:get_value(<<"key">>, QueryParams),
    find_by_eui_or_dev_addr(QueryParams, FindKey).

-spec find_by_eui_or_dev_addr([binary()], undefined | binary()) ->
    all_routes
    | {find_route, {devaddr, non_neg_integer()}}
    | {find_route, {eui, non_neg_integer(), non_neg_integer()}}.
find_by_eui_or_dev_addr(_QueryParams, undefined) ->
    all_routes;
find_by_eui_or_dev_addr(QueryParams, <<"dev_addr">>) ->
    DevAddr = sibyl_utils:ensure(
        integer_or_undefined,
        proplists:get_value(<<"dev_addr">>, QueryParams)
    ),
    {find_route, {devaddr, DevAddr}};
find_by_eui_or_dev_addr(QueryParams, <<"eui">>) ->
    AppEUI = proplists:get_value(<<"app_eui">>, QueryParams),
    DevEUI = proplists:get_value(<<"dev_eui">>, QueryParams),
    {find_route, {eui, DevEUI, AppEUI}}.

-spec is_chain_ready(undefined | blockchain:blockchain()) -> boolean().
is_chain_ready(undefined) ->
    false;
is_chain_ready(_Chain) ->
    true.

-spec is_data_modified(non_neg_integer(), non_neg_integer()) -> boolean().
is_data_modified(ClientLastHeight, LastModifiedHeight) when
    is_integer(ClientLastHeight); is_integer(LastModifiedHeight)
->
    ClientLastHeight =< LastModifiedHeight;
is_data_modified(_ClientLastHeight, _LastModifiedHeight) ->
    true.
