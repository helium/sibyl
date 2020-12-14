%%%-------------------------------------------------------------------
%% @doc Behaviour to implement for grpc service helium.validator.
%% @end
%%%-------------------------------------------------------------------

%% this module was generated on 2020-12-14T16:42:01+00:00 and should not be modified manually

-module(helium_validator_bhvr).

%% @doc
-callback routing(validator_pb:routing_request(), grpcbox_stream:t()) ->
    ok | {continue, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
