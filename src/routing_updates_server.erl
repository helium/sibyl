-module(routing_updates_server).

-behaviour(gen_server).

-include("../include/sibyl.hrl").

-record(state, {
    stream :: grpcbox_stream:t()
}).

-type state() :: #state{}.

-define(SERVER, ?MODULE).

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
    start_link/2
]).

%% ------------------------------------------------------------------
%% API functions
%% ------------------------------------------------------------------
-spec start_link(validator_pb:routing_reques(), any()) ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link(RequestMsg, Stream) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [RequestMsg, Stream], []).

%% ------------------------------------------------------------------
%% gen_server functions
%% ------------------------------------------------------------------
init([RequestMsg, Stream] = _Args) ->
    lager:info("init with args ~p", [_Args]),
    erlbus:sub(self(), ?EVENT_ROUTING_UPDATE),
    NewStream = maybe_send_inital_all_routes_msg(RequestMsg, Stream),
    {ok, #state{stream = NewStream}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(
    {event, EventTopic, Updates} = _Msg,
    #state{stream = Stream} = State
) when EventTopic =:= ?EVENT_ROUTING_UPDATE ->
    NewStream = handle_routing_updates(Updates, Stream),
    {noreply, State#state{stream = NewStream}};
handle_info(
    _Msg,
    State = #state{}
) ->
    lager:debug("unhandled info msg: ~p", [_Msg]),
    {ok, State}.

terminate(_Reason, _State = #state{}) ->
    ok.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec maybe_send_inital_all_routes_msg(validator_pb:routing_request(), grpc:stream()) ->
    grpc:stream().
maybe_send_inital_all_routes_msg(#{height := ClientHeight} = _RequestMsg, Stream) ->
    %% get the height field from the request msg and only return
    %% the initial full set of routes if they were modified since that height
    LastModifiedHeight = sibyl_mgr:get_last_modified(?EVENT_ROUTING_UPDATE),
    case is_data_modified(ClientHeight, LastModifiedHeight) of
        false ->
            Stream;
        true ->
            %% get the route data
            Chain = sibyl_mgr:blockchain(),
            Ledger = blockchain:ledger(Chain),
            {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
            case blockchain_ledger_v1:get_routes(Ledger) of
                {ok, Routes} ->
                    RoutesPB = encode_response(
                        all,
                        Routes,
                        CurHeight,
                        sibyl_mgr:sigfun()
                    ),
                    lager:info("*** stream: ~p", [Stream]),
                    NewStream = grpcbox_stream:send(false, RoutesPB, Stream),
                    NewStream;
                {error, _Reason} ->
                    Stream
            end
    end.

-spec handle_routing_updates({reference(), atom(), binary()}, state()) -> grpc:stream().
handle_routing_updates(
    Updates,
    Stream
) ->
    Ledger = blockchain:ledger(sibyl_mgr:blockchain()),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    %% get the sigfun which will be used to sign event payloads sent to the client
    SigFun = sibyl_mgr:sigfun(),
    lists:foldl(
        fun(Update, AccStream) ->
            {_Ref, Action, _Something, RoutePB} = Update,
            Route = blockchain_ledger_routing_v1:deserialize(RoutePB),
            RouteUpdatePB = encode_response(Action, [Route], Height, SigFun),
            lager:debug("sending event:  ~p", [
                RouteUpdatePB
            ]),
            lager:info("*** stream: ~p", [Stream]),
            grpcbox_stream:send(false, RouteUpdatePB, AccStream)
        end,
        Stream,
        Updates
    ).

-spec encode_response(
    atom(),
    blockchain_ledger_routing_v1:routing(),
    non_neg_integer(),
    function()
) -> validator_pb:routing_response().
encode_response(_Action, Routes, Height, SigFun) ->
    RouteUpdatePB = [to_routing_pb(R) || R <- Routes],
    Resp = #{
        routes => RouteUpdatePB,
        height => Height
    },
    EncodedRoutingInfoBin = validator_pb:encode_msg(Resp, routing_response),
    Resp#{signature => SigFun(EncodedRoutingInfoBin)}.

-spec to_routing_pb(blockchain_ledger_routing_v1:routing()) -> validator_pb:routing().
to_routing_pb(Route) ->
    #{
        oui => blockchain_ledger_routing_v1:oui(Route),
        owner => blockchain_ledger_routing_v1:owner(Route),
        addresses => blockchain_ledger_routing_v1:addresses(Route),
        filters => blockchain_ledger_routing_v1:filters(Route),
        subnet => blockchain_ledger_routing_v1:subnets(Route)
    }.

-spec is_data_modified(non_neg_integer(), non_neg_integer()) -> boolean().
is_data_modified(ClientLastHeight, LastModifiedHeight) when
    is_integer(ClientLastHeight); is_integer(LastModifiedHeight)
->
    ClientLastHeight < LastModifiedHeight;
is_data_modified(_ClientLastHeight, _LastModifiedHeight) ->
    true.
