-module(sibyl_utils).

%% API
-export([
    make_event/1,
    make_event/2,
    ensure/2,
    ensure/3
]).

-spec make_event(binary()) -> sibyl_mgr:event().
make_event(EventType) ->
    {event, EventType}.

-spec make_event(binary(), binary()) -> sibyl_mgr:event().
make_event(EventType, EventPayload) ->
    {event, EventType, EventPayload}.

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
    p_list_to_num(Value);
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
p_list_to_num(V) ->
    try
        list_to_float(V)
    catch
        error:badarg ->
            case catch list_to_integer(V) of
                Int when is_integer(Int) -> Int;
                _ -> "bad_value"
            end
    end.
