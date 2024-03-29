-module(sibyl_bus).
%% a simple wrapper around pg/pg2 providing pub/sub requirements
-include("include/sibyl.hrl").

%% API
-export([
    start/0,
    sub/2,
    pub/2,
    leave/2
]).

%% if release not defined default to 20, should be defined from otp21 and up
-ifndef(OTP_RELEASE).
-define(OTP_RELEASE, 20).
-endif.

%% if using otp23 or higher, use pg otherwise use pg2
-if(?OTP_RELEASE >= 23).

start() ->
    pg:start_link().

sub(Topic, Subscriber) ->
    pg:join(Topic, Subscriber).

leave(Topic, Subscriber) ->
    pg:leave(Topic, Subscriber).

pub(Topic, Message) ->
    Members = pg:get_local_members(Topic),
    send_to_members(Members, Message).

-else.

start() ->
    pg2:start_link().

sub(Topic, Subscriber) ->
    %% for pg2, need to create the desired topics/groups before we can join
    %% so just issue a create here, if already exists, it will be ignored
    pg2:create(Topic),
    pg2:join(Topic, Subscriber).

leave(Topic, Subscriber) ->
    pg2:leave(Topic, Subscriber).

pub(Topic, Message) ->
    case pg2:get_local_members(Topic) of
        {error, _} ->
            ok;
        Members ->
            send_to_members(Members, Message)
    end.

-endif.

%% private functions

send_to_members([], _Message) ->
    ok;
send_to_members([H | T], Message) ->
    H ! Message,
    send_to_members(T, Message).
