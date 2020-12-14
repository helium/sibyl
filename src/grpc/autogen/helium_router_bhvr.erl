%%%-------------------------------------------------------------------
%% @doc Behaviour to implement for grpc service helium.router.
%% @end
%%%-------------------------------------------------------------------

%% this module was generated on 2020-12-14T16:42:01+00:00 and should not be modified manually

-module(helium_router_bhvr).

%% @doc Unary RPC
-callback route(ctx:ctx(), router_pb:blockchain_state_channel_message_v_1()) ->
    {ok, router_pb:blockchain_state_channel_message_v_1(), ctx:ctx()}
    | grpcbox_stream:grpc_error_response().
