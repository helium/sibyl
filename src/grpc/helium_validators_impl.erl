-module(helium_validators_impl).

-include("../../include/sibyl.hrl").
-include("../grpc/autogen/server/gateway_pb.hrl").

-ifdef(TEST).
-define(VALIDATOR_LIMIT, 5).
-else.
-define(VALIDATOR_LIMIT, 50).
-endif.

-export([
    validators/2
]).

%% ------------------------------------------------------------------
%% helium_gateway_hbvr 'validators' callbacks
%% ------------------------------------------------------------------

-spec validators(
    ctx:ctx(),
    gateway_pb:gateway_validators_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
validators(Ctx, #gateway_validators_req_v1_pb{} = Message) ->
    Chain = sibyl_mgr:blockchain(),
    validators(Chain, Ctx, Message).

%% ------------------------------------------------------------------
%% callback breakout functions
%% ------------------------------------------------------------------
-spec validators(
    undefined | blockchain:blockchain(),
    ctx:ctx(),
    gateway_pb:gateway_validators_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
validators(
    undefined = _Chain,
    _Ctx,
    #gateway_validators_req_v1_pb{} = _Msg
) ->
    lager:debug("chain not ready, returning error response for msg ~p", [_Msg]),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavailable">>}};
validators(
    _Chain,
    Ctx,
    #gateway_validators_req_v1_pb{
        quantity = NumVals
    } = Request
) ->
    lager:debug("executing RPC validators with msg ~p", [Request]),
    %% get list of current validators from the cache
    %% and then get a random sub set of these with size
    %% equal to NumVals
    Vals = sibyl_mgr:validators(),
    RandomVals = blockchain_utils:shuffle(Vals),
    SelectedVals = lists:sublist(RandomVals, max(1, min(NumVals, ?VALIDATOR_LIMIT))),
    lager:debug("randomly selected validators: ~p", [SelectedVals]),
    EncodedVals = [
        #routing_address_pb{pub_key = Addr, uri = Routing}
     || {Addr, Routing} <- SelectedVals
    ],
    Response = sibyl_utils:encode_gateway_resp_v1(
        #gateway_validators_resp_v1_pb{result = EncodedVals},
        sibyl_mgr:sigfun()
    ),
    {ok, Response, Ctx}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
