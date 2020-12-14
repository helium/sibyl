-module(helium_validator_service).

-behavior(helium_validator_bhvr).

-include("../include/sibyl.hrl").

-record(handler_state, {
    worker_pid = undefined :: pid()
}).

-export([
    routing/2
]).

routing(Message, StreamState) ->
    lager:debug("RPC routing called with msg ~p", [Message]),
    HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    case HandlerState of
        undefined ->
            %% get our chain and only handle the request if the chain is up
            % if chain not up we have no way to return routing data so just return a 14/503
            Chain = sibyl_mgr:blockchain(),
            case is_chain_ready(Chain) of
                false ->
                    {grpc_error,
                        {grpcbox_stream:code_to_status(14), <<"temporarily unavavailable">>}};
                true ->
                    {ok, _WorkerPid} = routing_updates_sup:start_route_stream_worker(
                        Message,
                        StreamState
                    ),
                    lager:debug("started route update worker pid ~p", [_WorkerPid]),
                    NewStreamState = grpcbox_stream:stream_handler_state(
                        StreamState,
                        #handler_state{
                            worker_pid = _WorkerPid
                        }
                    ),
                    {continue, NewStreamState}
            end;
        _ ->
            %% handler state has previously been set, so this must be an additional msg
            %% we just ignore these and return continue directive
            {continue, StreamState}
    end.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec is_chain_ready(undefined | blockchain:blockchain()) -> boolean().
is_chain_ready(undefined) ->
    false;
is_chain_ready(_Chain) ->
    true.
