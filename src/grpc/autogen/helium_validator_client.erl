%%%-------------------------------------------------------------------
%% @doc Client module for grpc service helium.validator.
%% @end
%%%-------------------------------------------------------------------

%% this module was generated on 2020-12-14T16:42:01+00:00 and should not be modified manually

-module(helium_validator_client).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("grpcbox/include/grpcbox.hrl").

-define(is_ctx(Ctx), is_tuple(Ctx) andalso element(1, Ctx) =:= ctx).

-define(SERVICE, 'helium.validator').
-define(PROTO_MODULE, 'validator_pb').
-define(MARSHAL_FUN(T), fun(I) -> ?PROTO_MODULE:encode_msg(I, T) end).
-define(UNMARSHAL_FUN(T), fun(I) -> ?PROTO_MODULE:decode_msg(I, T) end).
-define(DEF(Input, Output, MessageType), #grpcbox_def{
    service = ?SERVICE,
    message_type = MessageType,
    marshal_fun = ?MARSHAL_FUN(Input),
    unmarshal_fun = ?UNMARSHAL_FUN(Output)
}).

%% @doc
-spec routing(validator_pb:routing_request()) ->
    {ok, grpcbox_client:stream()} | grpcbox_stream:grpc_error_response() | {error, any()}.
routing(Input) ->
    routing(ctx:new(), Input, #{}).

-spec routing(
    ctx:t() | validator_pb:routing_request(),
    validator_pb:routing_request() | grpcbox_client:options()
) -> {ok, grpcbox_client:stream()} | grpcbox_stream:grpc_error_response() | {error, any()}.
routing(Ctx, Input) when ?is_ctx(Ctx) ->
    routing(Ctx, Input, #{});
routing(Input, Options) ->
    routing(ctx:new(), Input, Options).

-spec routing(ctx:t(), validator_pb:routing_request(), grpcbox_client:options()) ->
    {ok, grpcbox_client:stream()} | grpcbox_stream:grpc_error_response() | {error, any()}.
routing(Ctx, Input, Options) ->
    grpcbox_client:stream(
        Ctx,
        <<"/helium.validator/routing">>,
        Input,
        ?DEF(routing_request, routing_response, <<"helium.RoutingRequest">>),
        Options
    ).
