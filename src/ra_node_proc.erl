-module(ra_node_proc).

-behaviour(gen_statem).

-include("ra.hrl").

%% State functions
-export([leader/3,
         follower/3,
         candidate/3]).

%% gen_statem callbacks
-export([
         init/1,
         format_status/2,
         handle_event/4,
         terminate/3,
         code_change/4,
         callback_mode/0
        ]).

%% API
-export([start_link/1,
         command/3,
         query/3,
         state_query/2
        ]).

-define(SERVER, ?MODULE).
-define(TEST_LOG, ra_log_memory).
-define(DEFAULT_BROADCAST_TIME, 100).
-define(SYNC_INTERVAL, 10).


-type command_reply_mode() :: after_log_append | await_consensus
                                             | notify_on_consensus.

-type query_fun() :: fun((term()) -> term()).

-type ra_command_type() :: '$usr' | '$ra_query' | '$ra_join' | '$ra_leave'
                           | '$ra_cluster_change'.

-type ra_command() :: {ra_command_type(), term(), command_reply_mode()}.

-type ra_leader_call_ret(Result) :: {ok, Result, Leader::ra_node_id()}
                                    | {error, term()}
                                    | {timeout, ra_node_id()}.

-type ra_cmd_ret() :: ra_leader_call_ret(ra_idxterm()).

-export_type([ra_leader_call_ret/1,
              ra_cmd_ret/0]).

-record(state, {node_state :: ra_node:ra_node_state(),
                broadcast_time :: non_neg_integer(),
                proxy :: maybe(pid()),
                sync_scheduled = false :: boolean(),
                pending_commands = [] :: [{{pid(), any()}, term()}]}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Config = #{id := Id}) ->
    Name = ra_node_id_to_local_name(Id),
    gen_statem:start_link({local, Name}, ?MODULE, [Config], []).

-spec command(ra_node_id(), ra_command(), timeout()) ->
    ra_cmd_ret().
command(ServerRef, Cmd, Timeout) ->
    leader_call(ServerRef, {command, Cmd}, Timeout).

-spec query(ra_node_id(), query_fun(), dirty | consistent) ->
    {ok, {ra_idxterm(), term()}, ra_node_id()}.
query(ServerRef, QueryFun, dirty) ->
    gen_statem:call(ServerRef, {dirty_query, QueryFun});
query(ServerRef, QueryFun, consistent) ->
    % TODO: timeout
    command(ServerRef, {'$ra_query', QueryFun, await_consensus}, 5000).


%% used to query the raft state rather than the machine state
-spec state_query(ra_node_id(), all | members) ->  ra_leader_call_ret(term()).
state_query(ServerRef, Spec) ->
    leader_call(ServerRef, {state_query, Spec}, ?DEFAULT_TIMEOUT).

leader_call(ServerRef, Msg, Timeout) ->
    case gen_statem_safe_call(ServerRef, {leader_call, Msg},
                              {dirty_timeout, Timeout}) of
        {redirect, Leader} ->
            leader_call(Leader, Msg, Timeout);
        {error, _} = E ->
            E;
        timeout ->
            % TODO: formatted error message
            {timeout, ServerRef};
        Reply ->
            {ok, Reply, ServerRef}
    end.

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

init([Config]) ->
    process_flag(trap_exit, true),
    #{id := Id,
      cluster := Cluster,
      machine_state := MacState} = NodeState = ra_node:init(Config),
    State = #state{node_state = NodeState,
                   broadcast_time = ?DEFAULT_BROADCAST_TIME},
    ?DBG("~p init machine_state ~p Cluster ~p~n",
         [Id, MacState, maps:keys(Cluster)]),
    {ok, follower, State, election_timeout_action(follower, State)}.

%% callback mode
callback_mode() -> state_functions.

%%%===================================================================
%%% State functions
%%%===================================================================

leader(EventType, {leader_call, Msg}, State) ->
    %  no need to redirect
    leader(EventType, Msg, State);
leader({call, From} = EventType, {command, {CmdType, Data, ReplyMode}},
       State0 = #state{node_state = NodeState0}) ->
    %% Persist command into log
    %% Return raft index + term to caller so they can wait for apply
    %% notifications
    %% Send msg to peer proxy with updated state data
    %% (so they can replicate)
    {leader, NodeState, Effects} =
        ra_node:handle_leader({command, {CmdType, From, Data, ReplyMode}},
                              NodeState0),
    {State, Actions} = handle_effects(Effects, EventType,
                                      State0#state{node_state = NodeState}),
    {keep_state, State, Actions};
leader({call, From}, {dirty_query, QueryFun},
         State = #state{node_state = NodeState}) ->
    Reply = perform_dirty_query(QueryFun, leader, NodeState),
    {keep_state, State, [{reply, From, Reply}]};
leader({call, From}, {state_query, Spec},
         State = #state{node_state = NodeState}) ->
    Reply = do_state_query(Spec, NodeState),
    {keep_state, State, [{reply, From, Reply}]};
leader(_EventType, {'EXIT', Proxy0, Reason},
       State0 = #state{proxy = Proxy0,
                       broadcast_time = Interval,
                       node_state = NodeState = #{id := Id}}) ->
    ?DBG("~p leader proxy exited with ~p~nrestarting..~n", [Id, Reason]),
    % TODO: this is a bit hacky - refactor
    Rpcs = ra_node:make_rpcs(NodeState),
    {ok, Proxy} = ra_proxy:start_link(self(), Interval),
    ok = ra_proxy:proxy(Proxy, true, Rpcs),
    {keep_state, State0#state{proxy = Proxy, node_state = NodeState}};
leader(EventType, sync, State0) ->
    {leader, State1, Effects} = handle_leader(sync,
                                              State0#state{sync_scheduled = false}),
    {State, Actions} = handle_effects(Effects, EventType, State1),
    {keep_state, State, Actions};
leader(EventType, Msg, State0) ->
    case handle_leader(Msg, State0) of
        {leader, State1, Effects} ->
            {State, Actions} = handle_effects(Effects, EventType, State1),
            {keep_state, State, Actions};
        {follower, State1, Effects} ->
            State2 = stop_proxy(State1),
            {State, Actions} = handle_effects(Effects, EventType, State2),
            {next_state, follower, State,
             [election_timeout_action(follower, State) | Actions]};
        {stop, State1, Effects} ->
            % interact before shutting down in case followers need
            % to know about the new commit index
            {State, _Actions} = handle_effects(Effects, EventType, State1),
            {stop, normal, State}
    end.

candidate({call, From}, {leader_call, Msg},
          State = #state{pending_commands = Pending}) ->
    {keep_state, State#state{pending_commands = [{From, Msg} | Pending]}};
candidate({call, From}, {dirty_query, QueryFun},
         State = #state{node_state = NodeState}) ->
    Reply = perform_dirty_query(QueryFun, candidate, NodeState),
    {keep_state, State, [{reply, From, Reply}]};
candidate(EventType, Msg, State0 = #state{node_state = #{id := Id,
                                                         current_term := Term},
                                          pending_commands = Pending}) ->
    case handle_candidate(Msg, State0) of
        {candidate, State1, Effects} ->
            {State, Actions0} = handle_effects(Effects, EventType, State1),
            Actions = case Msg of
                          election_timeout ->
                              [election_timeout_action(candidate, State)
                               | Actions0];
                          _ -> Actions0
                      end,
            {keep_state, State, Actions};
        {follower, State1, Effects} ->
            {State, Actions} = handle_effects(Effects, EventType, State1),
            ?DBG("~p candidate -> follower term: ~p ~p~n", [Id, Term, Actions]),
            {next_state, follower, State,
             [election_timeout_action(follower, State) | Actions]};
        {leader, State1, Effects} ->
            {State, Actions} = handle_effects(Effects, EventType, State1),
            ?DBG("~p candidate -> leader term: ~p~n", [Id, Term]),
            % inject a bunch of command events to be processed when node
            % becomes leader
            NextEvents = [{next_event, {call, F}, Cmd} || {F, Cmd} <- Pending],
            {next_state, leader, State, Actions ++ NextEvents}
    end.

follower({call, From}, {leader_call, _Cmd},
         State = #state{node_state = #{leader_id := LeaderId, id := _Id}}) ->
    % ?DBG("~p follower leader call - redirecting to ~p ~n", [Id, LeaderId]),
    {keep_state, State, {reply, From, {redirect, LeaderId}}};
follower({call, From}, {leader_call, Msg},
         State = #state{pending_commands = Pending, node_state = #{id := Id}}) ->
    ?DBG("~p follower leader call - leader not known. Dropping ~n", [Id]),
    {keep_state, State#state{pending_commands = [{From, Msg} | Pending]}};
follower({call, From}, {dirty_query, QueryFun},
         State = #state{node_state = NodeState}) ->
    Reply = perform_dirty_query(QueryFun, follower, NodeState),
    {keep_state, State, [{reply, From, Reply}]};
follower(EventType, Msg, State0 = #state{node_state = #{id := Id}}) ->
    case handle_follower(Msg, State0) of
        {follower, State1, Effects} ->
            {State, Actions} = handle_effects(Effects, EventType, State1),
            NewState = follower_leader_change(State0, State),
            {keep_state, NewState,
             [election_timeout_action(follower, NewState) | Actions]};
        {candidate, State1, Effects} ->
            {State, Actions} = handle_effects(Effects, EventType, State1),
            ?DBG("~p follower -> candidate term: ~p~n", [Id, current_term(State1)]),
            {next_state, candidate, State,
             [election_timeout_action(candidate, State) | Actions]}
    end.

handle_event(_EventType, EventContent, StateName, State) ->
    ?DBG("handle_event unknown ~p~n", [EventContent]),
    {next_state, StateName, State}.

terminate(Reason, _StateName,
          State = #state{node_state = NodeState = #{id := Id}}) ->
    ?DBG("ra: ~p terminating with ~p~n", [Id, Reason]),
    _ = stop_proxy(State),
    _ = ra_node:terminate(NodeState),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% TODO: we should provide a nice overview here including status
format_status(Opt, [_PDict, StateName, #state{node_state = #{id := Id}}]) ->
    [{id, Id},
     {opt, Opt},
     {raft_state, StateName}
    ].

%%%===================================================================
%%% Internal functions
%%%===================================================================

stop_proxy(#state{proxy = undefined} = State) ->
    State;
stop_proxy(#state{proxy = Proxy} = State) ->
    catch(gen_server:stop(Proxy, normal, 100)),
    State#state{proxy = undefined}.

handle_leader(Msg, #state{node_state = NodeState0} = State) ->
    {NextState, NodeState, Effects} = ra_node:handle_leader(Msg, NodeState0),
    {NextState, State#state{node_state = NodeState}, Effects}.

handle_candidate(Msg, #state{node_state = NodeState0} = State) ->
    {NextState, NodeState, Effects} = ra_node:handle_candidate(Msg, NodeState0),
    {NextState, State#state{node_state = NodeState}, Effects}.

handle_follower(Msg, #state{node_state = NodeState0} = State) ->
    {NextState, NodeState, Effects} = ra_node:handle_follower(Msg, NodeState0),
    {NextState, State#state{node_state = NodeState}, Effects}.

current_term(#state{node_state = #{current_term := T}}) -> T.

perform_dirty_query(QueryFun, leader, #{machine_state := MacState,
                                        last_applied := Last,
                                        id := Leader,
                                        current_term := Term}) ->
    {ok, {{Last, Term}, QueryFun(MacState)}, Leader};
perform_dirty_query(QueryFun, _StateName, #{machine_state := MacState,
                                            last_applied := Last,
                                            current_term := Term} = NodeState) ->
    Leader = maps:get(leader_id, NodeState, not_known),
    {ok, {{Last, Term}, QueryFun(MacState)}, Leader}.

% effect handler: either executes an effect or builds up a list of
% gen_statem 'Actions' to be returned.
handle_effects(Effects, EvtType, State0) ->
    lists:foldl(fun(Effect, {State, Actions}) ->
                        handle_effect(Effect, EvtType, State, Actions)
                end, {State0, []}, Effects).

handle_effect({next_event, Evt}, EvtType, State, Actions) ->
    {State, [{next_event, EvtType, Evt} |  Actions]};
handle_effect({next_event, _Type, _Evt} = Next, _EvtType, State, Actions) ->
    {State, [Next | Actions]};
handle_effect({send_msg, To, Msg}, _EvtType, State, Actions) ->
    To ! Msg,
    {State, Actions};
handle_effect({notify, Who, Reply}, _EvtType, State, Actions) ->
    _ = Who ! {consensus, Reply},
    {State, Actions};
% TODO: optimisation we could send the reply using gen_statem:reply to
% avoid waiting for all effects to finishe processing
handle_effect({reply, _From, _Reply} = Action, _EvtType, State, Actions) ->
    {State, [Action | Actions]};
handle_effect({reply, Reply}, {call, From}, State, Actions) ->
    {State, [{reply, From, Reply} | Actions]};
handle_effect({reply, _Reply}, _, _State, _Actions) ->
    exit(undefined_reply);
handle_effect({send_vote_requests, VoteRequests}, _EvtType, State, Actions) ->
    % transient election processes
    T = {dirty_timeout, 500},
    Me = self(),
    [begin
         _ = spawn(fun () -> Reply = gen_statem:call(N, M, T),
                             ok = gen_statem:cast(Me, Reply)
                   end)
     end || {N, M} <- VoteRequests],
    {State, Actions};
handle_effect({send_rpcs, IsUrgent, AppendEntries}, _EvtType,
               #state{proxy = undefined, broadcast_time = Interval} = State,
               Actions) ->
    {ok, Proxy} = ra_proxy:start_link(self(), Interval),
    ok = ra_proxy:proxy(Proxy, IsUrgent, AppendEntries),
    {State#state{proxy = Proxy}, Actions};
handle_effect({send_rpcs, IsUrgent, AppendEntries}, _EvtType,
               #state{proxy = Proxy} = State, Actions) ->
    ok = ra_proxy:proxy(Proxy, IsUrgent, AppendEntries),
    {State, Actions};
handle_effect({release_cursor, Index}, _EvtType,
              #state{node_state = NodeState0} = State, Actions) ->
    NodeState = ra_node:maybe_snapshot(Index, NodeState0),
    {State#state{node_state = NodeState}, Actions};
handle_effect({snapshot_point, Index}, _EvtType,
              #state{node_state = NodeState0} = State, Actions) ->
    NodeState = ra_node:record_snapshot_point(Index, NodeState0),
    {State#state{node_state = NodeState}, Actions};
handle_effect(schedule_sync, _EvtType, State = #state{sync_scheduled = true},
              Actions) ->
    {State, Actions};
handle_effect(schedule_sync, _EvtType, State, Actions) ->
    % No timer is actually started, instead it is enqueued to be processed after
    % all currently queued events.
    % {State, [{event_timeout, 0, sync} |  Actions]}.
    % TODO: consider allowing sync stategy to be controlled via configuration
    % Schedule sync after sync interval
    {State#state{sync_scheduled = true},
     [{generic_timeout, ?SYNC_INTERVAL, sync} |  Actions]}.



election_timeout_action(follower, #state{broadcast_time = Timeout}) ->
    T = rand:uniform(Timeout * 3) + (Timeout * 2),
    {state_timeout, T, election_timeout};
election_timeout_action(candidate, #state{broadcast_time = Timeout}) ->
    T = rand:uniform(Timeout * 5) + (Timeout * 2),
    {state_timeout, T, election_timeout}.

follower_leader_change(#state{node_state = #{leader_id := L}},
                       #state{node_state = #{leader_id := L}} = New) ->
    % no change
    New;
follower_leader_change(_Old, #state{node_state = #{id := Id, leader_id := L,
                                                   current_term := Term},
                                    pending_commands = Pending} = New)
  when L /= undefined ->
    % leader has either changed or just been set
    ?DBG("~p detected a new leader ~p in term ~p~n", [Id, L, Term]),
    [ok = gen_statem:reply(From, {redirect, L})
     || {From, _Data} <- Pending],
    New#state{pending_commands = []};
follower_leader_change(_Old, New) -> New.

ra_node_id_to_local_name({Name, _}) -> Name;
ra_node_id_to_local_name(Name) when is_atom(Name) -> Name.

gen_statem_safe_call(ServerRef, Msg, Timeout) ->
    try
        gen_statem:call(ServerRef, Msg, Timeout)
    catch
         exit:{timeout, _} ->
            timeout;
         exit:{noproc, _} ->
            {error, noproc};
         exit:{{nodedown, _}, _} ->
            {error, nodedown}
    end.

do_state_query(all, State) -> State;
do_state_query(members, #{cluster := Cluster}) ->
    maps:keys(Cluster).