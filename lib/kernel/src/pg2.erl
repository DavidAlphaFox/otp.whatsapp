%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 1997-2012. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%
-module(pg2).

-export([create/1, delete/1, join/2, leave/2]).
-export([get_members/1, get_local_members/1]).
-export([get_closest_pid/1, which_groups/0]).
-export([start/0,start_link/0,init/1,handle_call/3,handle_cast/2,handle_info/2,
         terminate/2]).
-export([sync/0, resync/0, global_resync/0]).
-export([verify_cluster_state/0, verify_cluster_state/1, get_node_state/4]).
-export([local_monitor/0, get_local_groups/0]).

-define(TRANS_LOCK_RETRIES, 5).
-define(TRANS_CALL_TIMEOUT, 30000).

%%% As of R13B03 monitors are used instead of links.

%%%
%%% Exported functions
%%%

-spec start_link() -> {'ok', pid()} | {'error', any()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec start() -> {'ok', pid()} | {'error', any()}.

start() ->
    ensure_started().

-type name() :: any().

-spec create(Name :: name()) -> 'ok'.

create(Name) ->
    ensure_started(),
    case ets:member(pg2_table, {group, Name}) of
        false ->
            trans(Name, {create, Name});
        true ->
            ok
    end.

-spec delete(Name :: name()) -> 'ok'.

delete(Name) ->
    ensure_started(),
    trans(Name, {delete, Name}),
    ok.

-spec join(Name, Pid :: pid()) -> 'ok' | {'error', {'no_such_group', Name}}
      when Name :: name().

join(Name, Pid) when is_pid(Pid) ->
    ensure_started(),
    case ets:member(pg2_table, {group, Name}) of
        false ->
            {error, {no_such_group, Name}};
        true ->
	    trans(Name, {join, Name, Pid})
    end.

-spec leave(Name, Pid :: pid()) -> 'ok' | {'error', {'no_such_group', Name}}
      when Name :: name().

leave(Name, Pid) when is_pid(Pid) ->
    ensure_started(),
    case ets:member(pg2_table, {group, Name}) of
        false ->
            {error, {no_such_group, Name}};
        true ->
	    trans(Name, {leave, Name, Pid})
    end.

-spec get_members(Name) -> [pid()] | {'error', {'no_such_group', Name}}
      when Name :: name().

get_members(Name) ->
    ensure_started(),
    case ets:member(pg2_table, {group, Name}) of
        true ->
            group_members(Name);
        false ->
            {error, {no_such_group, Name}}
    end.

-spec get_local_members(Name) -> [pid()] | {'error', {'no_such_group', Name}}
      when Name :: name().

get_local_members(Name) ->
    ensure_started(),
    case ets:member(pg2_table, {group, Name}) of
        true ->
            local_group_members(Name);
        false ->
            {error, {no_such_group, Name}}
    end.

-spec which_groups() -> [Name :: name()].

which_groups() ->
    ensure_started(),
    all_groups().

-spec get_closest_pid(Name) ->  pid() | {'error', Reason} when
      Name :: name(),
      Reason ::  {'no_process', Name} | {'no_such_group', Name}.

get_closest_pid(Name) ->
    case get_local_members(Name) of
        [Pid] ->
            Pid;
        [] ->
            {_,_,X} = erlang:now(),
            case get_members(Name) of
                [] -> {error, {no_process, Name}};
                Members ->
                    lists:nth((X rem length(Members))+1, Members)
            end;
        Members when is_list(Members) ->
            {_,_,X} = erlang:now(),
            lists:nth((X rem length(Members))+1, Members);
        Else ->
            Else
    end.

sync () ->
    gen_server:call(?MODULE, sync).

local_monitor () ->
    gen_server:call(?MODULE, {local_monitor, self()}).

resync () ->
    ?MODULE ! resync.

global_resync () ->
    gen_server:call(?MODULE, global_resync).

%%%
%%% Callback functions from gen_server
%%%

-record(state, {local_monitors = []}).

-type state() :: #state{}.

-spec init(Arg :: []) -> {'ok', state()}.

init([]) ->
    Ns = nodes(),
    net_kernel:monitor_nodes(true),
    lists:foreach(fun(N) ->
                          {?MODULE, N} ! {new_pg2, node()},
                          self() ! {nodeup, N}
                  end, Ns),
    pg2_table = ets:new(pg2_table, [ordered_set, protected, named_table]),
    {ok, #state{}}.

-spec handle_call(Call :: {'create', Name}
                        | {'delete', Name}
                        | {'join', Name, Pid :: pid()}
                        | {'leave', Name, Pid :: pid()},
                  From :: {pid(),Tag :: any()},
                  State :: state()) -> {'reply', 'ok', state()}
      when Name :: name().

handle_call({create, Name}, _From, S) ->
    assure_group(Name),
    {reply, ok, S};
handle_call({join, Name, Pid}, _From, S) ->
    ets:member(pg2_table, {group, Name}) andalso notify(join_group(Name, Pid), S),
    {reply, ok, S};
handle_call({leave, Name, Pid}, _From, S) ->
    ets:member(pg2_table, {group, Name}) andalso notify(leave_group(Name, Pid), S),
    {reply, ok, S};
handle_call({delete, Name}, _From, S) ->
    notify(delete_group(Name), S),
    {reply, ok, S};
handle_call(sync, _From, S) ->
    sync_groups(),
    {reply, ok, S};
handle_call({local_monitor, Pid}, _From, S) ->
    {Res, NewS} = case lists:member(Pid, S#state.local_monitors) of
		      true ->
			  {already_present, S};
		      false ->
			  do_monitor(Pid),
			  {ok, S#state{local_monitors = [Pid | S#state.local_monitors]}}
		  end,
    {reply, Res, NewS};
handle_call(global_resync, _From, S) ->
    Nodes = [node() | nodes()],
    [ {?MODULE, N} ! resync || N <- Nodes ],
    error_logger:warning_msg("pg2 resync request sent to ~b node(s)", [length(Nodes)]),
    {reply, {ok, length(Nodes)}, S};
handle_call(Request, From, S) ->
    error_logger:warning_msg("The pg2 server received an unexpected message:\n"
                             "handle_call(~p, ~p, _)\n", 
                             [Request, From]),
    {noreply, S}.

-spec handle_cast(Cast :: {'exchange', node(), Names :: [[Name,...]]},
                  State :: state()) -> {'noreply', state()}
      when Name :: name().

handle_cast({exchange, Node, List}, S) ->
    store(List, Node),
    {noreply, S};
handle_cast(_, S) ->
    %% Ignore {del_member, Name, Pid}.
    {noreply, S}.

-spec handle_info(Tuple :: tuple(), State :: state()) ->
    {'noreply', state()}.

handle_info({'DOWN', MonitorRef, process, Pid, _Info}, S) ->
    NewS = case lists:member(Pid, S#state.local_monitors) of
	       true ->
		   S#state{local_monitors = lists:delete(Pid, S#state.local_monitors)};
	       false ->
		   notify(member_died(MonitorRef), S),
		   S
	   end,
    {noreply, NewS};
handle_info({nodeup, Node}, S) ->
    gen_server:cast({?MODULE, Node}, {exchange, node(), get_exchange_members(Node)}),
    {noreply, S};
handle_info({new_pg2, Node}, S) ->
    gen_server:cast({?MODULE, Node}, {exchange, node(), get_exchange_members(Node)}),
    {noreply, S};
handle_info(resync, S) ->
    Nodes = nodes(),
    [ gen_server:cast({?MODULE, N}, {exchange, node(), get_exchange_members(N)}) || N <- Nodes ],
    error_logger:warning_msg("pg2 resync requested: state sent to ~b node(s)", [length(Nodes)]),
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

-spec terminate(Reason :: any(), State :: state()) -> 'ok'.

terminate(_Reason, _S) ->
    true = ets:delete(pg2_table),
    ok.

%%%
%%% Local functions
%%%

%%% One ETS table, pg2_table, is used for bookkeeping. The type of the
%%% table is ordered_set, and the fast matching of partially
%%% instantiated keys is used extensively.
%%%
%%% {{group, Name}}
%%%    Process group Name.
%%% {{ref, Pid}, RPid, MonitorRef, Counter}
%%% {{ref, MonitorRef}, Pid}
%%%    Each process has one monitor. Sometimes a process is spawned to
%%%    monitor the pid (RPid). Counter is incremented when the Pid joins
%%%    some group.
%%% {{member, Name, Pid}, GroupCounter}
%%% {{local_member, Name, Pid}}
%%%    Pid is a member of group Name, GroupCounter is incremented when the
%%%    Pid joins the group Name.
%%% {{pid, Pid, Name}}
%%%    Pid is a member of group Name.

trans(Name, Op) ->
    Nodes = [node() | nodes()],
    case global:trans({{?MODULE, Name}, self()},
		      fun() ->
			      gen_server:multi_call(Nodes, ?MODULE, Op, ?TRANS_CALL_TIMEOUT)
		      end,
		      Nodes,
		      ?TRANS_LOCK_RETRIES) of
	aborted ->
	    error_logger:warning_msg("Unable to set global lock for pg2 transaction: ~1000p.  Retrying ...", [Op]),
	    trans(Name, Op);
	{_Replies, BadNodes} ->
	    if length(BadNodes) > 0 ->
		   error_logger:warning_msg("pg2 transaction (~w) timed out on node(s): ~w", [Op, BadNodes]);
	       true ->
		   ok
	    end,
	    NewNodes = [node () | nodes()] -- Nodes,
	    %% Send full state to nodes which might have shown up after the Nodes list was obtained above.
	    %% Also attempt to send full state to nodes which didn't respond to the transaction.
	    [ ?MODULE ! {nodeup, N} || N <- NewNodes ++ BadNodes ]
    end,
    ok.

store(List, Node) ->
    store_groups(List, Node).

store_groups([], _Node) ->
    ok;
store_groups([[Name, Members] | List], Node) ->
    case assure_group(Name) of
	true ->
	    Stored = group_members(Name),
	    [ join_group(Name, P) || P <- Members -- Stored ];
	_ ->
	    ok
    end,
    store_groups(List, Node).

assure_group(Name) ->
    Key = {group, Name},
    MKey = {group_members, Name},
    LMKey = {local_group_members, Name},
    (ets:member(pg2_table, Key) orelse true =:= ets:insert(pg2_table, {Key}))
    andalso (ets:member(pg2_table, MKey) orelse true =:= ets:insert(pg2_table, {MKey, []}))
    andalso (ets:member(pg2_table, LMKey) orelse true =:= ets:insert(pg2_table, {LMKey, []})).  

delete_group(Name) ->
    _ = [leave_group(Name, Pid) || Pid <- group_members(Name)],
    true = ets:delete(pg2_table, {group, Name}),
    true = ets:delete(pg2_table, {group_members, Name}),
    true = ets:delete(pg2_table, {local_group_members, Name}),
    [Name].

member_died(Ref) ->
    [{{ref, Ref}, Pid}] = ets:lookup(pg2_table, {ref, Ref}),
    Names = member_groups(Pid),
    _ = [leave_group(Name, P) || 
            Name <- Names,
            P <- member_in_group(Pid, Name)],
    Names.

join_group(Name, Pid) ->
    Ref_Pid = {ref, Pid}, 
    try _ = ets:update_counter(pg2_table, Ref_Pid, {4, +1})
    catch _:_ ->
            {RPid, Ref} = do_monitor(Pid),
            true = ets:insert(pg2_table, {Ref_Pid, RPid, Ref, 1}),
            true = ets:insert(pg2_table, {{ref, Ref}, Pid})
    end,
    Member_Name_Pid = {member, Name, Pid},
    try _ = ets:update_counter(pg2_table, Member_Name_Pid, {2, +1})
    catch _:_ ->
            true = ets:insert(pg2_table, {Member_Name_Pid, 1}),
            _ = [ets:insert(pg2_table, {{local_member, Name, Pid}}) ||
                    node(Pid) =:= node()],
            true = ets:insert(pg2_table, {{pid, Pid, Name}})
    end,
    sync_group_members(Name),
    [Name].

leave_group(Name, Pid) ->
    Member_Name_Pid = {member, Name, Pid},
    try ets:update_counter(pg2_table, Member_Name_Pid, {2, -1}) of
        N ->
            if 
                N =:= 0 ->
                    true = ets:delete(pg2_table, {pid, Pid, Name}),
                    _ = [ets:delete(pg2_table, {local_member, Name, Pid}) ||
                            node(Pid) =:= node()],
                    true = ets:delete(pg2_table, Member_Name_Pid);
                true ->
                    ok
            end,
            Ref_Pid = {ref, Pid}, 
            case ets:update_counter(pg2_table, Ref_Pid, {4, -1}) of
                0 ->
                    [{Ref_Pid,RPid,Ref,0}] = ets:lookup(pg2_table, Ref_Pid),
                    true = ets:delete(pg2_table, {ref, Ref}),
                    true = ets:delete(pg2_table, Ref_Pid),
                    true = erlang:demonitor(Ref, [flush]),
                    kill_monitor_proc(RPid, Pid);
                _ ->
                    ok
            end,
	    sync_group_members(Name),
	    [Name]
    catch _:_ ->
            []
    end.

sync_groups () ->
    [ sync_group_members(G) || G <- all_groups() ].

sync_group_members (Name) ->
    Members = match_group_members(Name),
    true = ets:insert(pg2_table, {{group_members, Name}, Members}),
    LMembers = match_local_group_members(Name),
    true = ets:insert(pg2_table, {{local_group_members, Name}, LMembers}).

get_exchange_members(Node) ->
    [ [G, [ P || P <- group_members(G), node(P) =:= node() orelse node(P) =:= Node ]] || G <- all_groups() ].

group_members(Name) ->
    case ets:lookup(pg2_table, {group_members, Name}) of
	[] ->
	    match_group_members(Name);
	[{{group_members, Name}, Members}] ->
	    Members
    end.

match_group_members(Name) ->
    [P || 
        [P, N] <- ets:match(pg2_table, {{member, Name, '$1'},'$2'}),
        _ <- lists:seq(1, N)].

local_group_members(Name) ->
    case ets:lookup(pg2_table, {local_group_members, Name}) of
	[] ->
	    match_local_group_members(Name);
	[{{local_group_members, Name}, Members}] ->
	    Members
    end.

match_local_group_members (Name) ->
    [P || 
        [Pid] <- ets:match(pg2_table, {{local_member, Name, '$1'}}),
        P <- member_in_group(Pid, Name)].

member_in_group(Pid, Name) ->
    case ets:lookup(pg2_table, {member, Name, Pid}) of
        [] -> [];
        [{{member, Name, Pid}, N}] ->
            lists:duplicate(N, Pid)
    end.

member_groups(Pid) ->
    [Name || [Name] <- ets:match(pg2_table, {{pid, Pid, '$1'}})].

all_groups() ->
    [N || [N] <- ets:match(pg2_table, {{group,'$1'}})].

ensure_started() ->
    case whereis(?MODULE) of
        undefined ->
            C = {pg2, {?MODULE, start_link, []}, permanent,
                 1000, worker, [?MODULE]},
            supervisor:start_child(kernel_safe_sup, C);
        Pg2Pid ->
            {ok, Pg2Pid}
    end.


kill_monitor_proc(RPid, Pid) ->
    RPid =:= Pid orelse exit(RPid, kill).

%% When/if erlang:monitor() returns before trying to connect to the
%% other node this function can be removed.
do_monitor(Pid) ->
    case (node(Pid) =:= node()) orelse lists:member(node(Pid), nodes()) of
        true ->
            %% Assume the node is still up
            {Pid, erlang:monitor(process, Pid)};
        false ->
            F = fun() -> 
                        Ref = erlang:monitor(process, Pid),
                        receive 
                            {'DOWN', Ref, process, Pid, _Info} ->
                                exit(normal)
                        end
                end,
            erlang:spawn_monitor(F)
    end.

notify (Updates, S) ->
    [ P ! {pg2_update, Updates} || P <- S#state.local_monitors ].

get_local_groups () ->
    ets:select(pg2_table, [{{{local_group_members, '$1'}, '$2'}, [{'>', {'length', '$2'}, 0}], ['$1']}]).

verify_cluster_state () ->
    verify_cluster_state('_').

verify_cluster_state (Group) ->
    Nodes = [node() | nodes()],
    check_node_state(Nodes, get_node_state(Group, Nodes)).

get_node_state (Group, Nodes) when is_list(Nodes) ->
    Tab = ets:new(pg2_state, [ordered_set, public, {write_concurrency, true}]),
    lists:foreach(fun (N) ->
			   spawn(?MODULE, get_node_state, [Group, N, Tab, self()])
		  end,
		  Nodes),
    wait_node_state(Nodes, Tab).

wait_node_state ([], Tab) ->
    Tab;
wait_node_state ([N | Nodes], Tab) ->
    receive
	{get_node_state, N} ->
	    wait_node_state(Nodes, Tab)
    end.

get_node_state (Group, Node, Tab, Proc) ->
    lists:foreach(fun ({{local_group_members, G}, M}) ->
			   lists:foreach(fun (GM) ->
						  ets:insert_new(Tab, {{local_group_member, G, GM}})
					 end,
					 M)
		  end,
		  rpc:call(Node, ets, match_object, [pg2_table, {{local_group_members, Group}, '_'}])),
    lists:foreach(fun ({{group_members, G}, M}) ->
			   lists:foreach(fun (GM) ->
						  ets:insert(Tab, {{group, G}}),
						  ets:insert(Tab, {{group, G, Node}}),
						  ets:insert_new(Tab, {{group_member, G, Node, GM}})
					 end,
					 M)
		  end,
		  rpc:call(Node, ets, match_object, [pg2_table, {{group_members, Group}, '_'}])),
    Proc ! {get_node_state, Node}.

check_node_state (Nodes, Tab) when is_list(Nodes) ->
    AllGroups = [ G || {{group, G}} <- ets:match_object(Tab, {{group, '_'}}) ],
    NumMembers = lists:foldl(fun (Group, N) ->
				      GroupMembers = [ M || {{local_group_member, _G, M}} <- ets:match_object(Tab, {{local_group_member, Group, '_'}}) ],
				      ets:insert_new(Tab, {{group_members, Group}, GroupMembers}),
				      N + length(GroupMembers)
			     end,
			     0,
			     AllGroups),
    NodeDiffs = lists:foldl(fun (N, Diffs) ->
				     case check_node_state(N, Tab, AllGroups) of
					 {[], [], []} ->
					     Diffs;
					 {Missing, Extra, MemberDiffs} ->
					     [{N, Missing, Extra, MemberDiffs} | Diffs]
				     end
			    end,
			    [],
			    Nodes),
    [{nodes, length(Nodes)},
     {groups, length(AllGroups)},
     {members, NumMembers},
     {diffs, NodeDiffs}].

check_node_state (Node, Tab, AllGroups) ->
    NodeGroups = [ G || {{group, G, _N}} <- ets:match_object(Tab, {{group, '_', Node}}) ],
    NodeDiffs = lists:foldl(fun (Group, NDiffs) ->
				     GroupMembers = case ets:lookup(Tab, {group_members, Group}) of
							[{{group_members, Group}, GM}] ->
							    GM;
							_ ->
							    []
						    end,
				     NodeGroupMembers = [ M || {{group_member, _Group, _Node, M}} <- ets:match_object(Tab, {{group_member, Group, Node, '_'}}) ],
				     case {GroupMembers -- NodeGroupMembers, NodeGroupMembers -- GroupMembers} of
					 {[], []} ->
					     NDiffs;
					 {Missing, Extra} ->
					     [{Group, [ { node(P), P } || P <- Missing ], [ { node(P), P } || P <- Extra ]} | NDiffs]
				     end
			    end,
			    [],
			    NodeGroups),
    {AllGroups -- NodeGroups, NodeGroups -- AllGroups, NodeDiffs}.
