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
-include("sibyl.hrl").

%% common APIs
-export([
    init/2,
    handle_info/3
]).

%% general APIs
-export([
    address_to_public_uri/2,
    config/2,
    validators/2
]).

%% routing APIs
-export([]).

%% state channel related APIs
-export([
    is_active_sc/2,
    is_overpaid_sc/2,
    close_sc/2
]).

%% POC APIs
-export([
    check_challenge_target/2,
    send_report/2,
    poc_key_to_public_uri/2,
    region_params/2
]).

%% Stream API
-export([
    stream/2
]).

%%%-------------------------------------------------------------------
%% common API implementations
%%%-------------------------------------------------------------------

%%
%% RPC init - called from grpcbox
%%
init(_RPC, StreamState) ->
    StreamState.

%%
%% Any API can potentially handle info msgs, but really should only be used by streaming APIs
%% each handler initializes a map as state.  the map will always have a mod field which will
%% be the module of the handler, use this to route info messages.
%%
-spec handle_info(atom(), any(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(_RPC, Msg, StreamState) ->
    #{mod := Module} = _HandlerState = grpcbox_stream:stream_handler_state(StreamState),
    Module:handle_info(Msg, StreamState).

%%%-------------------------------------------------------------------
%% General RPC implementations
%%%-------------------------------------------------------------------
-spec address_to_public_uri(
    ctx:ctx(),
    gateway_pb:gateway_address_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
address_to_public_uri(Ctx, Message) ->
    helium_general_impl:address_to_public_uri(Ctx, Message).

-spec config(
    ctx:ctx(),
    gateway_pb:gateway_config_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
config(Ctx, Message) -> helium_general_impl:config(Ctx, Message).

-spec validators(
    ctx:ctx(),
    gateway_pb:gateway_validators_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
validators(Ctx, Message) -> helium_general_impl:validators(Ctx, Message).

%%%-------------------------------------------------------------------
%% Routing RPC implementations
%%%-------------------------------------------------------------------

%% none

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

%%%-------------------------------------------------------------------
%% PoCs RPC implementations
%%%-------------------------------------------------------------------
-spec check_challenge_target(
    ctx:ctx(),
    gateway_pb:gateway_poc_check_challenge_target_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
check_challenge_target(Ctx, Message) ->
    helium_poc_impl:check_challenge_target(Ctx, Message).

-spec send_report(
    ctx:ctx(),
    gateway_pb:gateway_poc_report_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
send_report(Ctx, Message) ->
    helium_poc_impl:send_report(Ctx, Message).

-spec poc_key_to_public_uri(
    ctx:ctx(),
    gateway_pb:gateway_poc_key_routing_data_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
poc_key_to_public_uri(Ctx, Message) ->
    helium_poc_impl:poc_key_to_public_uri(Ctx, Message).

-spec region_params(
    ctx:ctx(),
    gateway_pb:gateway_poc_region_params_req_v1_pb()
) -> {ok, gateway_pb:gateway_resp_v1_pb(), ctx:ctx()} | grpcbox_stream:grpc_error_response().
region_params(Ctx, Message) ->
    helium_poc_impl:region_params(Ctx, Message).
%%%-------------------------------------------------------------------
%% Streaming RPC implementations
%%%-------------------------------------------------------------------
-spec stream(
    gateway_pb:gateway_stream_req_v1_pb(),
    grpcbox_stream:t()
) -> {ok, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
stream({gateway_stream_req_v1_pb, {follow_req, Msg}}, StreamState) ->
    helium_state_channels_impl:follow_sc(Msg, StreamState);
stream({gateway_stream_req_v1_pb, {routing_req, Msg}}, StreamState) ->
    helium_routing_impl:routing(Msg, StreamState);
stream({gateway_stream_req_v1_pb, {poc_req, Msg}}, StreamState) ->
    helium_poc_impl:pocs(Msg, StreamState);
stream({gateway_stream_req_v1_pb, {config_update_req, Msg}}, StreamState) ->
    helium_general_impl:config_update(Msg, StreamState).
