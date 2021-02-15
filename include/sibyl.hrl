-define(EVENT_ROUTING_UPDATE, <<"route_update">>).
-define(EVENT_ROUTING_UPDATES_END, <<"route_updates_end">>).
-define(EVENT_STATE_CHANNEL_UPDATE, <<"state_channel_update">>).
-define(EVENT_STATE_CHANNEL_UPDATES_END, <<"state_channel_updates_end">>).

-define(ALL_EVENTS, [
    ?EVENT_ROUTING_UPDATE,
    ?EVENT_ROUTING_UPDATES_END,
    ?EVENT_STATE_CHANNEL_UPDATE,
    ?EVENT_STATE_CHANNEL_UPDATES_END
]).
