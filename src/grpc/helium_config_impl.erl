-module(helium_config_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").
-include_lib("helium_proto/include/blockchain_txn_vars_v1_pb.hrl").

-ifdef(TEST).
-define(MAX_KEY_SIZE, 5).
-else.
-define(MAX_KEY_SIZE, 50).
-endif.

-record(handler_state, {
    mod = undefined :: atom(),
    config_streaming_initialized = false :: boolean()
}).

-type handler_state() :: #handler_state{}.

-export_type([handler_state/0]).

-export([
    init/2,
    handle_info/2
]).

-export([
    config/2,
    config_update/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_hbvr 'config' callbacks
%% ------------------------------------------------------------------
-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(_RPC, StreamState) ->
    lager:info("handler init, stream state ~p", [StreamState]),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #handler_state{config_streaming_initialized = false, mod = ?MODULE}
    ),
    NewStreamState.

-spec config(
    ctx:ctx(),
    gateway_pb:gateway_config_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
config(Ctx, #gateway_config_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    config(Chain, Ctx, Message).

-spec config_update(
    gateway_pb:gateway_config_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
config_update(#gateway_config_update_req_v1_pb{} = Msg, StreamState) ->
    Chain = sibyl_mgr:blockchain(),
    #handler_state{config_streaming_initialized = IsAlreadyStreamingConfigUpdates} = grpcbox_stream:stream_handler_state(
        StreamState
    ),
    config_update(Chain, IsAlreadyStreamingConfigUpdates, Msg, StreamState).

handle_info(
    {config_update_notify, Msg},
    StreamState
) ->
    lager:info("received config_update_notify msg, sending to client ~p", [Msg]),
    %% received a config update notification event, we simply have to forward this unmodified to the client
    %% the payload is fully formed and encoded
    NewStreamState = grpcbox_stream:send(false, Msg, StreamState),
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

-spec config(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_config_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
config(
    undefined = _Chain,
    _Ctx,
    #gateway_config_req_v1_pb{} = _Msg
) ->
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
config(
    Chain,
    Ctx,
    #gateway_config_req_v1_pb{
        keys = Keys
    } = Request
) ->
    lager:info("executing RPC config with msg ~p", [Request]),
    Ledger = blockchain:ledger(Chain),
    NumKeys = length(Keys),
    Response0 =
        case NumKeys > ?MAX_KEY_SIZE of
            true ->
                {grpc_error, {
                    grpcbox_stream:code_to_status(3),
                    list_to_binary(
                        lists:concat(["limit ", ?MAX_KEY_SIZE, ". keys presented ", NumKeys])
                    )
                }};
            false ->
                %% iterate over the keys submitted in the request and retrieve
                %% current chain var value for each
                Res =
                    lists:map(
                        fun(Key) ->
                            try
                                case
                                    blockchain_ledger_v1:config(
                                        list_to_existing_atom(Key),
                                        Ledger
                                    )
                                of
                                    {ok, V} -> to_var(Key, V);
                                    {error, _} -> to_var(Key, undefined)
                                end
                            catch
                                _:_ -> to_var(Key, undefined)
                            end
                        end,
                        Keys
                    ),
                #gateway_config_resp_v1_pb{result = Res}
        end,

    Response1 = sibyl_utils:encode_gateway_resp_v1(
        Response0,
        sibyl_mgr:sigfun()
    ),
    {ok, Response1, Ctx}.

to_var(Key, undefined) ->
    #blockchain_var_v1_pb{
        name = Key,
        type = undefined,
        value = undefined
    };
to_var(Key, V) ->
    blockchain_txn_vars_v1:to_var(Key, V).

-spec config_update(
    blockchain:blockchain(),
    boolean(),
    gateway_pb:gateway_config_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
config_update(
    undefined = _Chain,
    _IsAlreadyStreamingConfigUpdates,
    #gateway_config_update_req_v1_pb{} = _Msg,
    _StreamState
) ->
    %% if chain not up we have no way to retrieve data so just return a 14/503
    lager:info("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
config_update(
    _Chain,
    true = _IsAlreadyStreamingConfigUpdates,
    #gateway_config_update_req_v1_pb{} = _Msg,
    StreamState
) ->
    %% we are already streaming config so do nothing further here
    {ok, StreamState};
config_update(
    _Chain,
    false = _IsAlreadyStreamingConfigUpdates,
    #gateway_config_update_req_v1_pb{} = Msg,
    StreamState
) ->
    lager:info("executing RPC config_update with msg ~p", [Msg]),
    %% start a config updates stream
    %% generate a topic key for config updates
    %% this key is global, ie not client specific
    %% any process subscribed to it will receive chain var updates
    Topic = sibyl_utils:make_config_update_topic(),
    ok = sibyl_bus:sub(Topic, self()),
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        HandlerState#handler_state{
            config_streaming_initialized = true
        }
    ),
    {ok, NewStreamState}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
