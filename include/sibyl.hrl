-define(CLIENT_HEIGHT_HEADER, <<"x-client-height">>).

-define(EVENT_ROUTING_UPDATES_END, <<"route_updates_end">>).
-define(EVENT_ROUTING_UPDATE, <<"route_update">>).
-define(EVENT_NEW_BLOCK, <<"new_block">>).

-define(ALL_EVENTS, [
    ?EVENT_ROUTING_UPDATE,
    ?EVENT_ROUTING_UPDATES_END,
    ?EVENT_NEW_BLOCK
]).
