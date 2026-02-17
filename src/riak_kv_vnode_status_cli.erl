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
-export([vnode_status_on_nodes/2, tableify/1, tableify1/1]).

register_cli() ->
    register_all_usage(),
    register_all_commands().

register_all_usage() ->
    clique:register_usage(["riak-admin", "vnode-status"], main_usage()).

register_all_commands() ->
    lists:foreach(
      fun(Args) -> apply(clique, register_command, Args) end,
      [get_vnode_status_specs()]).

main_usage() ->
    ["riak-admin vnode-status [-n|--node NODE|all] [-p|--partition PARTITION|all]\n",
     "                        [-f|--format json|csv|table]\n",
     "Print vnode status, including backend stats and info,\n",
     "on specified NODE and PARTITION (defaults to current node\n",
     "and all partitions, table format).\n"
    ].


-define(NODEOPT,
        {node, [{shortname, "n"},
                {longname, "node"},
                {typecast, fun to_node/1}]}).
-define(FORMATOPT,
        {format, [{shortname, "f"},
                  {longname, "format"}]}).

get_vnode_status_specs() ->
    [["riak-admin", "vnode-status"],
     '_', [?NODEOPT, ?FORMATOPT],
     fun get_vnode_status_cmd/3
    ].


get_vnode_status_cmd([_, _ | Args], _, Options) ->
    Nodes = extract_nodes(Options),
    Format = proplists:get_value(format, Options, "table"),
    case Args of
        [] when Format == "table" ->
            [clique_status:table(
               [[{node, N}] ++ lists:flatten([tableify(X) || {_Idx, X} <- Res])
                || {Res, N} <- vnode_status_on_nodes(Nodes, [])])
            ];
        _ ->
            clique_status:usage()
    end.

tableify(PP) ->
    [tableify1(P) || P <- PP].

tableify1({backend_status, Backend, BS}) ->
    tableify_backend(Backend, BS);
tableify1({vnodeid, Id}) ->
    {vnodeid, printable_bin(Id)};
tableify1(P) -> P.

tableify_backend(riak_kv_leveled_backend, PP) ->
    [tableify_led_prop(P) || P <- maps:to_list(PP)];
tableify_backend(_, PP) when is_map(PP) ->
    maps:to_list(PP);
tableify_backend(_, PP) ->
    PP.

tableify_led_prop({A, undefined}) ->
    {A, undefined};
tableify_led_prop({fetch_count_by_level,
                   #{not_found := A1, lower := A2, mem := A3,
                     '0' := A4, '1' := A5, '2' := A6, '3' := A7}}) ->
    F = fun(#{count := C, time := T}) -> io_lib:format("~b,~b", [C, T]) end,
    {fetch_count_by_level,
     iolist_to_binary(
       io_lib:format("nf:~s lwr:~s mem:~s 0:~s 1:~s 2:~s 3:~s",
                     [F(A1), F(A2), F(A3), F(A4), F(A5), F(A6), F(A7)]))};
tableify_led_prop({penciller_work_backlog_status, {A, B1, B2}}) ->
    F = fun(true) -> "+"; (false) -> "-" end,
    {penciller_work_backlog_status, iolist_to_binary(io_lib:format("~b ~s ~s", [A, F(B1), F(B2)]))};
tableify_led_prop({level_files_count, Map}) ->
    F = fun(#{level := L, count := C}) -> io_lib:format("~b:~b", [L, C]) end,
    {level_files_count, iolist_to_binary(lists:join(" ", [F(A) || A <- maps:to_list(Map)]))};
tableify_led_prop({A, TS}) when A =:= penciller_last_merge_time;
                                A =:= journal_last_compaction_time ->
    {A, calendar:system_time_to_rfc3339(TS, [{unit, millisecond}])};
tableify_led_prop(Unchanged) ->
    Unchanged.



vnode_status_on_nodes([], Q) ->
    Q;
vnode_status_on_nodes([N|Rest], Q) ->
    Preflists = rpc:call(N, riak_core_vnode_manager, all_index_pid, [riak_kv_vnode]),
    Res = rpc:call(N, riak_kv_vnode, vnode_status, [Preflists]),
    vnode_status_on_nodes(Rest, [{Res, N} | Q]).


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

to_node("all") ->
    all;
to_node(A) ->
    clique_typecast:to_node(A).


printable_bin(K) ->
    case re:run(K, <<"[[:alnum:][:punct:]]+">>) of
        {match, [{0, N}]} when N == size(K) ->
            K;
        _ ->
            iolist_to_binary(["0x", mochihex:to_hex(K)])
    end.

clique_status_text(F, A) ->
    clique_status:text(io_lib:format(F, A)).
clique_status_alert(S) ->
    clique_status_alert(S, []).
clique_status_alert(F, A) ->
    clique_status:alert([clique_status_text(F, A)]).
