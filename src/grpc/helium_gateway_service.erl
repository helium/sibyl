%%%-------------------------------------------------------------------
%% wrapper implementations for the APIs & RPCs for the gateway service
%% basically this module handles various RPC and function calls from grpcbox_stream
%% and routes it to the required application specific handler module
%% due to issues with the rust grpc client, we have amalgamated what were
%% previously distinct grpc services ( such as state channels and routing )
%% which had module specific implementations
%% into a single service as defined in the gateway proto
%% rather than combining the server side implementations into one
%% single module, this top level module was added instead and simply
%% routes incoming RPCs to their service specific module
%% this was we can maintain functional seperation of concerns
%%%-------------------------------------------------------------------
-module(helium_gateway_service).

-behavior(helium_gateway_bhvr).

-include("../grpc/autogen/server/gateway_pb.hrl").

%% common APIs
-export([
    init/2,
    handle_info/3
]).

%% routing APIs
-export([
    routing/2
]).

%% state channel related APIs
-export([
    is_valid/2,
    close/2,
    follow/2
]).

%%%-------------------------------------------------------------------
%% common API implementations
%%%-------------------------------------------------------------------

%% its really only stream RPCs which need to handle the init
%% as its those which are likely to manage their own state
%% unary APIs only need to return the same passed in StreamState

%%
%% routing streaming APIs
%%
-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().
init(RPC = routing, StreamState) ->
    helium_routing_impl:init(RPC, StreamState);
%%
%% state channel streaming APIs
%%
init(RPC = follow, StreamState) ->
    helium_state_channels_impl:init(RPC, StreamState);
%%
%% state channel unary APIs
%%
init(_RPC = is_valid, StreamState) ->
    StreamState;
init(_RPC = close, StreamState) ->
    StreamState.

%%
%% Any API can potentially handle info msgs
%%
-spec handle_info(atom(), any(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_RPC = routing, Msg, StreamState) ->
    helium_routing_impl:handle_info(Msg, StreamState);
handle_info(_RPC = is_valid, Msg, StreamState) ->
    helium_state_channels_impl:handle_info(Msg, StreamState);
handle_info(_RPC = close, Msg, StreamState) ->
    helium_state_channels_impl:handle_info(Msg, StreamState);
handle_info(_RPC = follow, Msg, StreamState) ->
    lager:warning("got follow info msg, RPC ~p, Msg, ~p", [_RPC, Msg]),
    helium_state_channels_impl:handle_info(Msg, StreamState);
handle_info(_RPC, _Msg, StreamState) ->
    lager:warning("got unhandled info msg, RPC ~p, Msg, ~p", [_RPC, _Msg]),
    StreamState.

%%%-------------------------------------------------------------------
%% Routing RPC implementations
%%%-------------------------------------------------------------------
-spec routing(gateway_pb:gateway_routing_req_v1_pb(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
routing(Msg, StreamState) -> helium_routing_impl:routing(Msg, StreamState).

%%%-------------------------------------------------------------------
%% State channel RPC implementations
%%%-------------------------------------------------------------------
-spec is_valid(
    ctx:ctx(),
    gateway_pb:gateway_sc_is_valid_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_valid(Ctx, Message) -> helium_state_channels_impl:is_valid(Ctx, Message).

-spec close(
    ctx:ctx(),
    gateway_pb:gateway_sc_close_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()}.
close(Ctx, Message) -> helium_state_channels_impl:close(Ctx, Message).

-spec follow(
    gateway_pb:gateway_follow_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
follow(Msg, StreamState) -> helium_state_channels_impl:follow(Msg, StreamState).
