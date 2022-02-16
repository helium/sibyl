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

%% region params APIs
-export([
    region_params_update/2
]).

%% config APIs
-export([
    config/2,
    config_update/2
]).

%% validators APIs
-export([
    validators/2
]).

%% routing APIs
-export([
    routing/2
]).

%% state channel related APIs
-export([
    is_active_sc/2,
    is_overpaid_sc/2,
    close_sc/2,
    follow_sc/2
]).

%%%-------------------------------------------------------------------
%% common API implementations
%%%-------------------------------------------------------------------

%% its really only stream RPCs which need to handle the init
%% as its those which are likely to manage their own state
%% unary APIs only need to return the same passed in StreamState

-spec init(atom(), grpcbox_stream:t()) -> grpcbox_stream:t().

%%
%% validators unary APIs
%%
init(_RPC = validators, StreamState) ->
    StreamState;
%%
%% config unary APIs
%%
init(_RPC = config, StreamState) ->
    StreamState;
%%
%% region params streaming APIs
%%
init(RPC = region_params_update, StreamState) ->
    helium_region_params_impl:init(RPC, StreamState);
%%
%% config streaming APIs
%%
init(RPC = config_update, StreamState) ->
    helium_config_impl:init(RPC, StreamState);
%%
%% routing streaming APIs
%%
init(RPC = routing, StreamState) ->
    helium_routing_impl:init(RPC, StreamState);
%%
%% state channel streaming APIs
%%
init(RPC = follow_sc, StreamState) ->
    helium_state_channels_impl:init(RPC, StreamState);
%%
%% state channel unary APIs
%%
init(_RPC = is_active_sc, StreamState) ->
    StreamState;
init(_RPC = is_overpaid_sc, StreamState) ->
    StreamState;
init(_RPC = close_sc, StreamState) ->
    StreamState.

%%
%% Any API can potentially handle info msgs but really its only
%% gonna be streaming APIs
%%
-spec handle_info(atom(), any(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_RPC = region_params_update, Msg, StreamState) ->
    helium_region_params_impl:handle_info(Msg, StreamState);
handle_info(_RPC = config_update, Msg, StreamState) ->
    helium_config_impl:handle_info(Msg, StreamState);
handle_info(_RPC = routing, Msg, StreamState) ->
    helium_routing_impl:handle_info(Msg, StreamState);
handle_info(_RPC = follow_sc, Msg, StreamState) ->
    helium_state_channels_impl:handle_info(Msg, StreamState);
handle_info(_RPC, _Msg, StreamState) ->
    lager:warning("got unhandled info msg, RPC ~p, Msg, ~p", [_RPC, _Msg]),
    StreamState.

%%%-------------------------------------------------------------------
%% Region params RPC implementations
%%%-------------------------------------------------------------------
-spec region_params_update(
    gateway_pb:gateway_region_params_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
region_params_update(Msg, StreamState) ->
    helium_region_params_impl:region_params_update(Msg, StreamState).
%%%-------------------------------------------------------------------
%% Validators RPC implementations
%%%-------------------------------------------------------------------
-spec validators(
    ctx:ctx(),
    gateway_pb:gateway_validators_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
validators(Ctx, Message) -> helium_validators_impl:validators(Ctx, Message).

%%%-------------------------------------------------------------------
%% Config RPC implementations
%%%-------------------------------------------------------------------
-spec config(
    ctx:ctx(),
    gateway_pb:gateway_config_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
config(Ctx, Message) -> helium_config_impl:config(Ctx, Message).

-spec config_update(
    gateway_pb:gateway_config_update_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
config_update(Msg, StreamState) -> helium_config_impl:config_update(Msg, StreamState).

%%%-------------------------------------------------------------------
%% Routing RPC implementations
%%%-------------------------------------------------------------------
-spec routing(gateway_pb:gateway_routing_req_v1_pb(), grpcbox_stream:t()) ->
    {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
routing(Msg, StreamState) -> helium_routing_impl:routing(Msg, StreamState).

%%%-------------------------------------------------------------------
%% State channel RPC implementations
%%%-------------------------------------------------------------------
-spec is_active_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_is_active_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_active_sc(Ctx, Message) -> helium_state_channels_impl:is_active_sc(Ctx, Message).

-spec is_overpaid_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_is_overpaid_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
is_overpaid_sc(Ctx, Message) -> helium_state_channels_impl:is_overpaid_sc(Ctx, Message).

-spec close_sc(
    ctx:ctx(),
    gateway_pb:gateway_sc_close_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()}.
close_sc(Ctx, Message) -> helium_state_channels_impl:close_sc(Ctx, Message).

-spec follow_sc(
    gateway_pb:gateway_sc_follow_req_v1(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
follow_sc(Msg, StreamState) -> helium_state_channels_impl:follow_sc(Msg, StreamState).
