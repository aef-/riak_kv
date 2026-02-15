%% -------------------------------------------------------------------
%%
%% Copyright (c) 2026 TI Tokyo.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(riak_kv_vnode_status_cli).

-behaviour(clique_handler).

-include_lib("kernel/include/logger.hrl").

-export([register_cli/0]).

register_cli() ->
    register_all_usage(),
    register_all_commands().

register_all_usage() ->
    clique:register_usage(["riak-admin", "vnode-status"], main_usage()).

register_all_commands() ->
    clique:register_command(get_vnode_status_specs()).

main_usage() ->
    ["riak-admin vnode-status [-n|--node NODE|all] [-p|--partition PARTITION|all] \n",
     "Print vnode status, including backend stats and info,\n",
     "on specified NODE and PARTITION (defaults to current node and all partitions).\n"
    ].


-define(NODEOPT, {node, [{shortname, "n"},
                         {longname, "node"},
                         {typecast, fun to_node/1}]}).
-define(PARTITIONOPT, {partition, [{shortname, "p"},
                                   {longname, "partition"},
                                   {typecast, fun to_partition/1}]}).

get_vnode_status_specs() ->
    [["riak-admin", "vnode-status"],
     '_', [?NODEOPT, ?PARTITIONOPT],
     fun(A, B, C) -> get_vnode_status_cmd/3, A, B, C) end
    ].


get_vnode_status_cmd([_, _, _ | Args], _, Options) ->
    Nodes = extract_nodes(Options),
    Vnodes = extract_vnodes(Options, Nodes),
    case Args of
        [] ->
            [clique_status:table(
               [[{node, N}, {index, P}, {rebuild_schedule, FmtF(Res)}]
                || {Res, {P, N}} <- get_rebuild_schedule(Vnodes)])];
        _ ->
            clique_status:usage()
    end.


-spec(vnode_status([]) -> ok).
vnode_status([]) ->
    try
        case riak_kv_status:vnode_status() of
            [] ->
                io:format("There are no active vnodes.~n");
            Statuses ->
                io:format("~s~n-------------------------------------------~n~n",
                          ["Vnode status information"]),
                print_vnode_statuses(lists:sort(Statuses))
        end
    catch
        Exception:Reason ->
            ?LOG_ERROR("Backend status failed ~p:~p", [Exception,
                    Reason]),
            io:format("Backend status failed, see log for details~n"),
            error
    end.


print_vnode_statuses([]) ->
    ok;
print_vnode_statuses([{VNodeIndex, StatusData} | RestStatuses]) ->
    io:format("VNode: ~p~n", [VNodeIndex]),
    print_vnode_status(StatusData),
    io:format("~n"),
    print_vnode_statuses(RestStatuses).

print_vnode_status([]) ->
    ok;
print_vnode_status([{backend_status,
                     Backend,
                     StatusItem} | RestStatusItems]) ->
    if is_binary(StatusItem) ->
            StatusString = binary_to_list(StatusItem),
            io:format("Backend: ~p~nStatus: ~n~s~n",
                      [Backend, string:strip(StatusString)]);
       true ->
            io:format("Backend: ~p~nStatus: ~n~p~n",
                      [Backend, StatusItem])
    end,
    print_vnode_status(RestStatusItems);
print_vnode_status([StatusItem | RestStatusItems]) ->
    if is_binary(StatusItem) ->
            StatusString = binary_to_list(StatusItem),
            io:format("Status: ~n~s~n",
                      [string:strip(StatusString)]);
       true ->
            io:format("Status: ~n~p~n", [StatusItem])
    end,
    print_vnode_status(RestStatusItems).


extract_nodes(Options) ->
    NN = [N || {node, N} <- Options],
    case lists:member(all, NN) of
        true ->
            [node() | nodes()];
        false when NN /= [] ->
            NN;
        _ ->
            [node()]
    end.
extract_vnodes(Options, Nodes) ->
    PP = [P || {partition, P} <- Options],
    HaveAll = lists:member(all, PP) or (length(PP) == 0),
    HaveManyNodes = length(Nodes) > 1,
    case {HaveManyNodes, HaveAll} of
        {true, false} ->
            io:format("With more than a single node, only -p all is allowed\n", []),
            throw(inconsistent_options);
        {_, true} ->
            lists:flatten([[{P, N} || {P, _} <- vnodes(N, all)] || N <- Nodes]);
        {_, false} ->
            lists:flatten([[{P, N} || {P, _} <- vnodes(N, PP)] || N <- Nodes])
    end.

vnodes(Node, all) ->
    {ok, Ring} = rpc:call(Node, riak_core_ring_manager, get_my_ring, []),
    [VN || VN = {_, Owner} <- rpc:call(Node, riak_core_ring, all_owners, [Ring]), Owner =:= Node];
vnodes(Node, List) ->
    [{P, Node} || P <- List].


to_node("all") ->
    all;
to_node(A) ->
    clique_typecast:to_node(A).

to_partition("all") ->
    all;
to_partition(A) ->
    try
        list_to_integer(A)
    catch _:_ ->
            {error, bad_partition}
    end.


printable_bin(K) ->
    case re:run(K, <<"[[:alnum:][:punct:]]+">>) of
        {match, [{0, N}]} when N == size(K) ->
            K;
        _ ->
            iolist_to_binary(["0x", mochihex:to_hex(K)])
    end.
bin_from_maybe_hex("0x" ++ A) -> mochihex:to_bin(A);
bin_from_maybe_hex(A) -> list_to_binary(A).

printable_vclock(A) ->
    base64:encode(riak_object:encode_vclock(A)).

tree_size("xxsmall") -> xxsmall;
tree_size("xsmall") -> xsmall;
tree_size("small") -> small;
tree_size("medium") -> medium;
tree_size("large") -> large;
tree_size("xlarge") -> xlarge.

time2s(never) ->
    never;
time2s(now) ->
    time2s(calendar:local_time());
time2s({_, _, _} = A) ->
    time2s(calendar:now_to_local_time(A));
time2s({{LRY, LRMo, LRD}, {LRH, LRMi, LRS}}) ->
    iolist_to_binary(
      io_lib:format("~4.10.0B-~2.10.0B-~2.10.0BT~2.10.0B:~2.10.0B:~2.10.0B",
                    [LRY, LRMo, LRD, LRH, LRMi, LRS])).

ending([_]) -> "";
ending(_) -> "s".

clique_status_text(F, A) ->
    clique_status:text(io_lib:format(F, A)).
clique_status_alert(S) ->
    clique_status_alert(S, []).
clique_status_alert(F, A) ->
    clique_status:alert([clique_status_text(F, A)]).
