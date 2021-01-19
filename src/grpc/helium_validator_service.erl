-module(helium_validator_service).

-behavior(helium_validator_bhvr).

-include("../../include/sibyl.hrl").
-include("autogen/server/validator_pb.hrl").

-record(handler_state, {
    initialized = false :: boolean()
}).

-export([
    init/1,
    handle_info/2,
    routing/2
]).

-spec init(grpcbox_stream:t()) -> grpcbox_stream:t().
init(StreamState) ->
    lager:debug("handler init, stream state ~p", [StreamState]),
    NewStreamState = grpcbox_stream:stream_handler_state(
        StreamState,
        #handler_state{
            initialized = false
        }
    ),
    NewStreamState.

-spec routing(validator_pb:routing_request_pb(), grpcbox_stream:t()) ->
    {continue, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
routing(#routing_request_pb{height = ClientHeight} = Msg, StreamState) ->
    lager:debug("RPC routing called with height ~p", [ClientHeight]),
    #handler_state{initialized = Initialized} = grpcbox_stream:stream_handler_state(StreamState),
    routing(Initialized, sibyl_mgr:blockchain(), Msg, StreamState).

-spec routing(
    boolean(),
    blockchain:blockchain(),
    validator_pb:routing_request_pb(),
    grpcbox_stream:t()
) -> {continue, grpcbox_stream:t()} | grpcbox_stream:grpc_error_response().
routing(_Initialized, undefined = _Chain, #routing_request_pb{} = _Msg, _StreamState) ->
    % if chain not up we have no way to return routing data so just return a 14/503
    lager:debug("chain not ready, returning error response"),
    {grpc_error, {grpcbox_stream:code_to_status(14), <<"temporarily unavavailable">>}};
routing(
    false = _Initialized,
    _Chain,
    #routing_request_pb{height = ClientHeight} = _Msg,
    StreamState
) ->
    %% not previously initialized, this must be the first msg from the client
    %% we will have some setup to do including subscribing to our required events
    lager:debug("handling first msg from client ~p", [_Msg]),
    ok = erlbus:sub(self(), ?EVENT_ROUTING_UPDATE),
    NewStreamState = maybe_send_inital_all_routes_msg(ClientHeight, StreamState),
    NewStreamState0 = grpcbox_stream:stream_handler_state(
        NewStreamState,
        #handler_state{
            initialized = true
        }
    ),
    {continue, NewStreamState0};
routing(true = _Initialized, _Chain, #routing_request_pb{} = _Msg, StreamState) ->
    %% we previously initialized, this must be a subsequent incoming msg from the client
    %% ignore these and return continue directive
    lager:debug("ignoring subsequent msg from client ~p", [_Msg]),
    {continue, StreamState}.

-spec handle_info(sibyl_mgr:event() | any(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_info(
    {event, _EventTopic, _Update} = Event,
    StreamState
) ->
    lager:debug("received event ~p", [Event]),
    NewStreamState = handle_event(Event, StreamState),
    NewStreamState;
handle_info(
    _Msg,
    StreamState
) ->
    lager:debug("unhandled info msg: ~p", [_Msg]),
    StreamState.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------

-spec handle_event(sibyl_mgr:event(), grpcbox_stream:t()) -> grpcbox_stream:t().
handle_event(
    {event, ?EVENT_ROUTING_UPDATE, Routes},
    StreamState
) ->
    Ledger = blockchain:ledger(sibyl_mgr:blockchain()),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    %% get the sigfun which will be used to sign event payloads sent to the remote peer
    SigFun = sibyl_mgr:sigfun(),
    ClientUpdatePB = encode_routing_update_response(Routes, Height, SigFun),
    lager:debug("sending event to client:  ~p", [
        ClientUpdatePB
    ]),
    NewStreamState = grpcbox_stream:send(false, ClientUpdatePB, StreamState),
    NewStreamState.

-spec maybe_send_inital_all_routes_msg(validator_pb:routing_request(), grpcbox_stream:t()) ->
    grpc:stream().
maybe_send_inital_all_routes_msg(ClientHeight, StreamState) ->
    %% get the height field from the request msg and only return
    %% the initial full set of routes if they were modified since that height
    LastModifiedHeight = sibyl_mgr:get_last_modified(?EVENT_ROUTING_UPDATE),
    case is_data_modified(ClientHeight, LastModifiedHeight) of
        false ->
            lager:debug(
                "not sending initial routes msg, data not modified since client height ~p",
                [ClientHeight]
            ),
            StreamState;
        true ->
            lager:debug(
                "sending initial routes msg, data has been modified since client height ~p",
                [ClientHeight]
            ),
            %% get the route data
            Chain = sibyl_mgr:blockchain(),
            Ledger = blockchain:ledger(Chain),
            {ok, CurHeight} = blockchain_ledger_v1:current_height(Ledger),
            case blockchain_ledger_v1:get_routes(Ledger) of
                {ok, Routes} ->
                    RoutesPB = encode_routing_update_response(
                        Routes,
                        CurHeight,
                        sibyl_mgr:sigfun()
                    ),
                    NewStream = grpcbox_stream:send(false, RoutesPB, StreamState),
                    NewStream;
                {error, _Reason} ->
                    StreamState
            end
    end.

-spec encode_routing_update_response(
    blockchain_ledger_routing_v1:routing(),
    non_neg_integer(),
    function()
) -> validator_pb:routing_response_pb().
encode_routing_update_response(Routes, Height, SigFun) ->
    RoutePB = [to_routing_pb(R) || R <- Routes],
    Update = #routing_response_pb{
        routings = RoutePB,
        height = Height
    },
    EncodedUpdateBin = validator_pb:encode_msg(Update, routing_response_pb),
    Update#routing_response_pb{signature = SigFun(EncodedUpdateBin)}.

-spec to_routing_pb(validator_ledger_routing_v1:routing()) -> validator_pb:routing_pb().
to_routing_pb(Route) ->
    PubKeyAddresses = blockchain_ledger_routing_v1:addresses(Route),
    %% using the pub keys, attempt to determine public IP for each peer
    %% and return in address record
    Addresses = address_data(PubKeyAddresses),
    #routing_pb{
        oui = blockchain_ledger_routing_v1:oui(Route),
        owner = blockchain_ledger_routing_v1:owner(Route),
        addresses = Addresses,
        filters = blockchain_ledger_routing_v1:filters(Route),
        subnets = blockchain_ledger_routing_v1:subnets(Route)
    }.

-spec is_data_modified(non_neg_integer(), non_neg_integer()) -> boolean().
is_data_modified(ClientLastHeight, LastModifiedHeight) when
    is_integer(ClientLastHeight); is_integer(LastModifiedHeight)
->
    ClientLastHeight < LastModifiedHeight;
is_data_modified(_ClientLastHeight, _LastModifiedHeight) ->
    true.

-spec address_data([libp2p_crypto:pubkey_bin()]) -> [#address_pb{}].
address_data(Addresses) ->
    address_data(Addresses, []).

-spec address_data([libp2p_crypto:pubkey_bin()], [#address_pb{}]) -> [#address_pb{}].
address_data([], Hosts) ->
    Hosts;
address_data([PubKeyAddress | Rest], Hosts) ->
    case check_for_public_ip(PubKeyAddress) of
        {ok, IP} ->
            Address = #address_pb{pub_key = PubKeyAddress, uri = format_ip(IP)},
            lager:debug("address data ~p", [Address]),
            address_data(Rest, [Address | Hosts]);
        {error, _Reason} ->
            lager:warning("no public ip for router address ~p. Reason ~p", [PubKeyAddress, _Reason]),

            address_data(Rest, Hosts)
    end.

-spec check_for_public_ip(libp2p_crypto:pubkey_bin()) -> {ok, binary()} | {error, atom()}.
check_for_public_ip(PubKeyBin) ->
    lager:debug("getting IP for peer ~p", [PubKeyBin]),
    SwarmTID = blockchain_swarm:tid(),
    Peerbook = libp2p_swarm:peerbook(SwarmTID),
    case libp2p_peerbook:get(Peerbook, PubKeyBin) of
        {ok, PeerInfo} ->
            ClearedListenAddrs = libp2p_peer:cleared_listen_addrs(PeerInfo),
            %% sort listen addrs, ensure the public ip is at the head
            [H | _] = libp2p_transport:sort_addrs_with_keys(SwarmTID, ClearedListenAddrs),
            has_addr_public_ip(H);
        {error, not_found} ->
            %% we dont have this peer in our peerbook, check if we have an alias for it
            check_for_alias(SwarmTID, PubKeyBin)
    end.

-spec check_for_alias(atom(), libp2p_crypto:pubkey_bin()) -> binary() | {error, atom()}.
check_for_alias(SwarmTID, PubKeyBin) ->
    MAddr = libp2p_crypto:pubkey_bin_to_p2p(PubKeyBin),
    Aliases = application:get_env(libp2p, node_aliases, []),
    case lists:keyfind(MAddr, 1, Aliases) of
        false ->
            {error, peer_not_found};
        {MAddr, AliasAddr} ->
            {ok, _, {_Transport, _}} =
                libp2p_transport:for_addr(SwarmTID, AliasAddr),
            %% hmm ignore transport for now, assume tcp TODO: revisit
            {IPTuple, _, _, _} = libp2p_transport_tcp:tcp_addr(AliasAddr),
            format_ip(list_to_binary(inet:ntoa(IPTuple)))
    end.

-spec has_addr_public_ip({non_neg_integer(), string()}) -> {ok, binary()} | {error, atom()}.
has_addr_public_ip({1, Addr}) ->
    [_, _, IP, _, _Port] = re:split(Addr, "/"),
    {ok, IP};
has_addr_public_ip({_, _Addr}) ->
    {error, no_public_ip}.

-spec format_ip(binary()) -> binary().
format_ip(IP) ->
    {ok, [GrpcOpts]} = application:get_env(grpcbox, servers),
    #{listen_opts := #{port := Port}, transport_opts := #{ssl := SSL}} = GrpcOpts,
    lager:debug("ip: ~p, ssl: ~p, port: ~p", [IP, SSL, Port]),
    format_ip(IP, SSL, Port).

-spec format_ip(binary(), boolean(), non_neg_integer()) -> binary().
format_ip(IP, true, Port) ->
    list_to_binary(
        uri_string:normalize(#{scheme => "https", port => Port, host => IP, path => ""})
    );
format_ip(IP, false, Port) ->
    list_to_binary(uri_string:normalize(#{scheme => "http", port => Port, host => IP, path => ""})).
