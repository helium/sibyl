-module(sibyl_utils).

-include("../include/sibyl.hrl").
-include("grpc/autogen/server/gateway_pb.hrl").

-type gateway_resp_type() ::
    gateway_pb:gateway_sc_is_valid_resp_v1_pb()
    | gateway_pb:gateway_sc_close_resp_v1_pb()
    | gateway_pb:gateway_sc_follow_streamed_resp_v1_pb()
    | gateway_pb:gateway_routing_streamed_resp_v1_pb().

%% API
-export(
    [
        make_event/1,
        make_event/2,
        make_sc_topic/1,
        encode_gateway_resp_v1/3,
        to_routing_pb/1,
        ensure/2,
        ensure/3
    ]
).

-spec make_event(binary()) -> sibyl_mgr:event().
make_event(EventType) ->
    {event, EventType}.

-spec make_event(binary(), any()) -> sibyl_mgr:event().
make_event(EventType, EventPayload) ->
    {event, EventType, EventPayload}.

make_sc_topic(SCID) ->
    <<?EVENT_STATE_CHANNEL_UPDATE/binary, SCID/binary>>.

-spec encode_gateway_resp_v1(
    gateway_resp_type(),
    non_neg_integer(),
    function()
) -> gateway_pb:gateway_resp_v1_pb().
encode_gateway_resp_v1(#gateway_sc_is_valid_resp_v1_pb{} = Msg, Height, SigFun) ->
    do_encode_gateway_resp_v1({is_valid_resp, Msg}, Height, SigFun);
encode_gateway_resp_v1(#gateway_sc_close_resp_v1_pb{} = Msg, Height, SigFun) ->
    do_encode_gateway_resp_v1({close_resp, Msg}, Height, SigFun);
encode_gateway_resp_v1(#gateway_sc_follow_streamed_resp_v1_pb{} = Msg, Height, SigFun) ->
    do_encode_gateway_resp_v1({follow_streamed_resp, Msg}, Height, SigFun);
encode_gateway_resp_v1(#gateway_routing_streamed_resp_v1_pb{} = Msg, Height, SigFun) ->
    do_encode_gateway_resp_v1({routing_streamed_resp, Msg}, Height, SigFun).

-spec to_routing_pb(blockchain_ledger_routing_v1:routing()) -> gateway_pb:gateway_routing_pb().
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

ensure(_, undefined) ->
    undefined;
ensure(_, <<"undefined">>) ->
    undefined;
ensure(_, "undefined") ->
    undefined;
ensure(atom, Value) when is_binary(Value) ->
    list_to_atom(binary_to_list(Value));
ensure(atom, Value) when is_list(Value) ->
    list_to_atom(Value);
ensure(number, Value) when is_atom(Value) ->
    ensure(number, atom_to_list(Value));
ensure(number, Value) when is_binary(Value) ->
    ensure(number, binary_to_list(Value));
ensure(number, Value) when is_list(Value) ->
    list_to_num(Value);
ensure(integer, Value) when is_atom(Value) ->
    ensure(integer, atom_to_list(Value));
ensure(integer, Value) when is_binary(Value) ->
    ensure(integer, binary_to_list(Value));
ensure(integer, Value) when is_list(Value) ->
    case catch list_to_integer(Value) of
        V when is_integer(V) -> V;
        _ -> "bad_value"
    end;
ensure(integer_or_undefined, Value) ->
    case ensure(integer, Value) of
        "bad_value" -> undefined;
        V -> V
    end;
ensure(binary, undefined) ->
    undefined;
ensure(binary, Value) when is_binary(Value) ->
    Value;
ensure(binary, Value) when is_list(Value) ->
    list_to_binary(Value);
ensure(binary, Value) when is_atom(Value) ->
    list_to_binary(atom_to_list(Value));
ensure(binary, Value) when is_integer(Value) ->
    list_to_binary(integer_to_list(Value));
ensure(list, Value) when is_integer(Value) ->
    integer_to_list(Value);
ensure(list, Value) when is_float(Value) ->
    float_to_list(Value);
ensure(list, Value) when is_binary(Value) ->
    binary_to_list(Value);
ensure(_Type, Value) ->
    Value.

ensure(integer_or_default, Value, Default) ->
    case ensure(integer, Value) of
        "bad_value" -> Default;
        undefined -> Default;
        V -> V
    end.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec do_encode_gateway_resp_v1(
    {atom(), gateway_resp_type()},
    non_neg_integer(),
    function()
) -> gateway_pb:gateway_resp_v1_pb().
do_encode_gateway_resp_v1(Msg, Height, SigFun) ->
    Update = #gateway_resp_v1_pb{
        height = Height,
        msg = Msg,
        signature = <<>>
    },
    EncodedUpdateBin = gateway_pb:encode_msg(Update, gateway_resp_v1_pb),
    Update#gateway_resp_v1_pb{signature = SigFun(EncodedUpdateBin)}.

-spec address_data([libp2p_crypto:pubkey_bin()]) -> [#routing_address_pb{}].
address_data(Addresses) ->
    address_data(Addresses, []).

-spec address_data([libp2p_crypto:pubkey_bin()], [#routing_address_pb{}]) ->
    [#routing_address_pb{}].
address_data([], Hosts) ->
    Hosts;
address_data([PubKeyAddress | Rest], Hosts) ->
    case check_for_public_ip(PubKeyAddress) of
        {ok, IP} ->
            Address = #routing_address_pb{pub_key = PubKeyAddress, uri = format_ip(IP)},
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

list_to_num(V) ->
    try
        list_to_float(V)
    catch
        error:badarg ->
            case catch list_to_integer(V) of
                Int when is_integer(Int) -> Int;
                _ -> "bad_value"
            end
    end.
