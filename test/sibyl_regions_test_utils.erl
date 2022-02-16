-module(sibyl_regions_test_utils).

-include("sibyl_poc_v11_vars.hrl").
-export([poc_v11_vars/0]).

%% Below is lifted from blockchain-core tests...
poc_v11_vars() ->
    RegionURLs = region_urls(),
    Regions = download_regions(RegionURLs),
    V0 = maps:put(regulatory_regions, ?regulatory_region_bin_str, maps:from_list(Regions)),
    V1 = #{
        poc_version => 11,
        %% XXX: 1.0 = no loss? because the mic_rcv_sig calculation multiplies this? unclear...
        fspl_loss => 1.0,
        %% NOTE: Set to 3 to attach tx_power to poc receipt
        data_aggregation_version => 3,
        region_us915_params => region_params_us915(),
        region_eu868_params => region_params_eu868(),
        region_au915_params => region_params_au915(),
        region_as923_1_params => region_params_as923_1(),
        region_as923_2_params => region_params_as923_2(),
        region_as923_3_params => region_params_as923_3(),
        region_as923_4_params => region_params_as923_4(),
        region_ru864_params => region_params_ru864(),
        region_cn470_params => region_params_cn470(),
        region_in865_params => region_params_in865(),
        region_kr920_params => region_params_kr920(),
        region_eu433_params => region_params_eu433()
    },
    maps:merge(V0, V1).

region_urls() ->
    [
        {region_as923_1, ?region_as923_1_url},
        {region_as923_2, ?region_as923_2_url},
        {region_as923_3, ?region_as923_3_url},
        {region_as923_4, ?region_as923_4_url},
        {region_au915, ?region_au915_url},
        {region_cn470, ?region_cn470_url},
        {region_eu433, ?region_eu433_url},
        {region_eu868, ?region_eu868_url},
        {region_in865, ?region_in865_url},
        {region_kr920, ?region_kr920_url},
        {region_ru864, ?region_ru864_url},
        {region_us915, ?region_us915_url}
    ].

download_regions(RegionURLs) ->
    sibyl_ct_utils:pmap(
        fun({Region, URL}) ->
            Ser = download_serialized_region(URL),
            {Region, Ser}
        end,
        RegionURLs
    ).

region_params_us915() ->
    Params = make_params(?REGION_PARAMS_US915),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_eu868() ->
    Params = make_params(?REGION_PARAMS_EU868),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_au915() ->
    Params = make_params(?REGION_PARAMS_AU915),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_as923_1() ->
    Params = make_params(?REGION_PARAMS_AS923_1),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_as923_2() ->
    Params = make_params(?REGION_PARAMS_AS923_2),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_as923_3() ->
    Params = make_params(?REGION_PARAMS_AS923_3),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_as923_4() ->
    Params = make_params(?REGION_PARAMS_AS923_4),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_ru864() ->
    Params = make_params(?REGION_PARAMS_RU864),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_cn470() ->
    Params = make_params(?REGION_PARAMS_CN470),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_in865() ->
    Params = make_params(?REGION_PARAMS_IN865),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_kr920() ->
    Params = make_params(?REGION_PARAMS_KR920),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

region_params_eu433() ->
    Params = make_params(?REGION_PARAMS_EU433),
    blockchain_region_params_v1:serialize(blockchain_region_params_v1:new(Params)).

download_serialized_region(URL) ->
    %% Example URL: "https://github.com/JayKickliter/lorawan-h3-regions/blob/main/serialized/US915.res7.h3idx?raw=true"
    {ok, Dir} = file:get_cwd(),
    %% Ensure priv dir exists
    PrivDir = filename:join([Dir, "priv"]),
    ok = filelib:ensure_dir(PrivDir ++ "/"),
    ok = ssl:start(),
    case httpc:request(URL) of
        {ok, {{_, 200, "OK"}, _, Body}} ->
            FName = hd(string:tokens(hd(lists:reverse(string:tokens(URL, "/"))), "?")),
            FPath = filename:join([PrivDir, FName]),
            ok = file:write_file(FPath, Body),
            {ok, Data} = file:read_file(FPath),
            Data;
        _ ->
            <<>>
    end.

make_params(RegionParams) ->
    lists:foldl(
        fun(P, Acc) ->
            Param = construct_param(P),
            [Param | Acc]
        end,
        [],
        RegionParams
    ).

construct_param(P) ->
    CF = proplists:get_value(<<"channel_frequency">>, P),
    BW = proplists:get_value(<<"bandwidth">>, P),
    MaxEIRP = proplists:get_value(<<"max_eirp">>, P),
    Spreading = blockchain_region_spreading_v1:new(proplists:get_value(<<"spreading">>, P)),
    blockchain_region_param_v1:new(CF, BW, MaxEIRP, Spreading).
