%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%-------------------------------------------------------------------
%% Created : 18 Mar 2003 by Ulf Wiger <etxuwig@cbe1066>
%%-------------------------------------------------------------------
%% @author Ulf Wiger <ulf.wiger@feuerlabs.com>
%% @author Thomas Arts <thomas.arts@quviq.com>
%%
%% @doc Example callback module for the locks_leader behaviour.
%% <p>This particular callback module implements a global dictionary,
%% and is the back-end for the <code>gdict</code> module.</p>
%% @end
%%
%%
%% @type dictionary() = tuple().
%%   Same as from {@link dict:new(). dict:new()}; used in this module as State.
%%
%% @type info() = term(). Opaque state of the gen_leader behaviour.
%% @type state() = dictionary().
%%    Internal server state; In the general case, it can be any term.
%% @type broadcast() = term().
%%    Whatever the leader decides to broadcast to the candidates.
%% @type reason()  = term(). Error information.
%% @type commonReply() = {ok, state()} |
%%                       {ok, broadcast(), state()} |
%%                       {stop, reason(), state()}.
%%   Common set of valid replies from most callback functions.
%%
-module(test_cb).

-behaviour(locks_leader).

-export([init/1,
	 elected/3,
	 surrendered/3,
	 handle_DOWN/3,
	 handle_leader_call/4,
	 handle_leader_cast/3,
	 from_leader/3,
	 handle_call/4,
	 handle_cast/3,
	 handle_info/3,
	 terminate/2,
	 code_change/4]).

-record(st, {am_leader = false,
	     dict}).

%% @spec init(Arg::term()) -> {ok, State}
%%
%%   State = state()
%%
%% @doc Equivalent to the init/1 function in a gen_server.
%%
init(Dict) ->
    io:fwrite("init(~p)~n", [Dict]),
    {ok, #st{dict = Dict}}.

%% @spec elected(State::state(), I::info(), Cand::pid() | undefined) ->
%%   {ok, Broadcast, NState}
%% | {reply, Msg, NState}
%% | {ok, AmLeaderMsg, FromLeaderMsg, NState}
%% | {error, term()}
%%
%%     Broadcast = broadcast()
%%     NState    = state()
%%
%% @doc Called by the leader when it is elected leader, and each time a
%% candidate recognizes the leader.
%%
%% This function is only called in the leader instance, and `Broadcast'
%% will be sent to all candidates (when the leader is first elected),
%% or to the new candidate that has appeared.
%%
%% `Broadcast' might be the same as `NState', but doesn't have to be.
%% This is up to the application.
%%
%% If `Cand == undefined', it is possible to obtain a list of all new
%% candidates that we haven't synced with (in the normal case, this will be
%% all known candidates, but if our instance is re-elected after a netsplit,
%% the 'new' candidates will be the ones that haven't yet recognized us as
%% leaders). This gives us a chance to talk to them before crafting our
%% broadcast message.
%%
%% We can also choose a different message for the new candidates and for
%% the ones that already see us as master. This would be accomplished by
%% returning `{ok, AmLeaderMsg, FromLeaderMsg, NewState}', where
%% `AmLeaderMsg' is sent to the new candidates (and processed in
%% {@link surrendered/3}, and `FromLeaderMsg' is sent to the old
%% (and processed in {@link from_leader/3}).
%%
%% If `Cand == Pid', a new candidate has connected. If this affects our state
%% such that all candidates need to be informed, we can return `{ok, Msg, NSt}'.
%% If, on the other hand, we only need to get the one candidate up to speed,
%% we can return `{reply, Msg, NSt}', and only the candidate will get the
%% message. In either case, the candidate (`Cand') will receive the message
%% in {@link surrendered/3}. In the former case, the other candidates will
%% receive the message in {@link from_leader/3}.
%%
%% Example:
%%
%% <pre lang="erlang">
%%   elected(#st{dict = Dict} = St, _I, undefined) -&gt;
%%       {ok, Dict, St};
%%   elected(#st{dict = Dict} = St, _I, Pid) when is_pid(Pid) -&gt;
%%       %% reply only to Pid
%%       {reply, Dict, St}.
%% </pre>
%% @end
%%
elected(#st{dict = Dict} = S, I, undefined) ->
    io:fwrite("elected leader, merging~n", []),
    case locks_leader:new_candidates(I) of
	[] ->
	    io:fwrite("elected(~p)~n", [dict:to_list(Dict)]),
	    {ok, {sync, Dict}, S#st{am_leader = true}};
	Cands ->
	    io:fwrite("New candidates = ~p~n", [Cands]),
	    NewDict = merge_dicts(Dict, I),
	    {ok, {sync, NewDict}, S#st{am_leader = true, dict = NewDict}}
    end;
elected(#st{dict = Dict} = S, _E, Pid) when is_pid(Pid) ->
    io:fwrite("new cand: syncing with ~p (~p)~n", [Pid, dict:to_list(Dict)]),
    {reply, {sync, Dict}, S#st{am_leader = true}}.

%% This is sub-optimal, but it's only an example!
merge_dicts(D, I) ->
    {Good, _Bad} = locks_leader:ask_candidates(merge, I),
    lists:foldl(
      fun({C, {true, D2}}, Acc) ->
	      io:fwrite("merge: got ~p from ~w~n", [dict:to_list(D2),C]),
	      dict:merge(fun(_K,V1,_) -> V1 end, Acc, D2);
	 ({C, false}, Acc) ->
	      io:fwrite("merge: got ~p from ~w~n", [false, C]),
	      Acc
      end, D, Good).


%% @spec surrendered(State::state(), Synch::broadcast(), I::info()) ->
%%          {ok, NState}
%%
%%    NState = state()
%%
%% @doc Called by each candidate when it recognizes another instance as
%% leader.
%%
%% Strictly speaking, this function is called when the candidate
%% acknowledges a leader and receives a Synch message in return.
%%
%% Example:
%%
%% <pre lang="erlang">
%%  surrendered(_OurDict, LeaderDict, _I) -&gt;
%%      {ok, LeaderDict}.
%% </pre>
%% @end
surrendered(#st{dict = OurDict} = S, {sync, LeaderDict}, _I) ->
    io:fwrite("surrendered(Old:~p, New:~p)~n", [dict:to_list(OurDict),
						dict:to_list(LeaderDict)]),
    {ok, S#st{dict = LeaderDict, am_leader = false}}.

%% @spec handle_DOWN(Candidate::pid(), State::state(), I::info()) ->
%%    {ok, NState} | {ok, Broadcast, NState}
%%
%%   Broadcast = broadcast()
%%   NState    = state()
%%
%% @doc Called by the leader when it detects loss of a candidate.
%%
%% If the function returns a `Broadcast' object, this will be sent to all
%% candidates, and they will receive it in the function {@link from_leader/3}.
%% @end
handle_DOWN(Pid, S, _I) ->
    io:fwrite("handle_DOWN(~p,Dict,E)~n", [Pid]),
    {ok, S}.

%% @spec handle_leader_call(Msg::term(), From::callerRef(), State::state(),
%%                          I::info()) ->
%%    {reply, Reply, NState} |
%%    {reply, Reply, Broadcast, NState} |
%%    {noreply, state()} |
%%    {stop, Reason, Reply, NState} |
%%    commonReply()
%%
%%   Broadcast = broadcast()
%%   NState    = state()
%%
%% @doc Called by the leader in response to a
%% {@link locks_leader:leader_call/2. leader_call()}.
%%
%% If the return value includes a `Broadcast' object, it will be sent to all
%% candidates, and they will receive it in the function {@link from_leader/3}.
%%
%%
%% Example:
%%
%% <pre lang="erlang">
%%   handle_leader_call({store,F}, From, #st{dict = Dict} = S, E) -&gt;
%%       NewDict = F(Dict),
%%       {reply, ok, {store, F}, S#st{dict = NewDict}};
%%   handle_leader_call({leader_lookup,F}, From, #st{dict = Dict} = S, E) -&gt;
%%       Reply = F(Dict),
%%       {reply, Reply, S}.
%% </pre>
%%
%% In this particular example, `leader_lookup' is not actually supported
%% from the {@link gdict. gdict} module, but would be useful during
%% complex operations, involving a series of updates and lookups. Using
%% `leader_lookup', all dictionary operations are serialized through the
%% leader; normally, lookups are served locally and updates by the leader,
%% which can lead to race conditions.
%% @end
handle_leader_call({store,F} = Op, _From, #st{dict = Dict} = S, _I) ->
    io:fwrite("handle_leader_call(~p, _From, Dict, I)~n", [Op]),
    NewDict = F(Dict),
    {reply, ok, {store, F}, S#st{dict = NewDict}};
handle_leader_call({leader_lookup,F} = Op, _From, #st{dict = Dict} = S, _I) ->
    io:fwrite("handle_leader_call(~p, From, Dict, I)~n", [Op]),
    Reply = F(Dict),
    {reply, Reply, S#st{dict = Dict}}.


%% @spec handle_leader_cast(Msg::term(), State::term(), I::info()) ->
%%   commonReply()
%%
%% @doc Called by the leader in response to a {@link locks_leader:leader_cast/2.
%% leader_cast()}.
%% @end
handle_leader_cast(_Msg, S, _I) ->
    io:fwrite("handle_leader_cast(~p, Dict, I)~n", [_Msg]),
    {ok, S}.

%% @spec from_leader(Msg::term(), State::state(), I::info()) ->
%%    {ok, NState}
%%
%%   NState = state()
%%
%% @doc Called by each candidate in response to a message from the leader.
%%
%% In this particular module, the leader passes an update function to be
%% applied to the candidate's state.
%% @end
from_leader({sync, D}, #st{} = S, _I) ->
    {ok, S#st{dict = D}};
from_leader({store,F} = Op, #st{dict = Dict} = S, _I) ->
    io:fwrite("from_leader(~p, Dict, I)~n", [Op]),
    NewDict = F(Dict),
    {ok, S#st{dict = NewDict}}.


%% @spec handle_call(Request::term(), From::callerRef(), State::state(),
%%                   I::info()) ->
%%    {reply, Reply, NState}
%%  | {noreply, NState}
%%  | {stop, Reason, Reply, NState}
%%  | commonReply()
%%
%% @doc Equivalent to `Mod:handle_call/3' in a gen_server.
%%
%% Note the difference in allowed return values. `{ok,NState}' and
%% `{noreply,NState}' are synonymous.
%%
%% `{noreply,NState}' is allowed as a return value from `handle_call/3',
%% since it could arguably add some clarity, but mainly because people are
%% used to it from gen_server.
%% @end
%%
handle_call(merge, _From, #st{am_leader = AmLeader,
			      dict = Dict} = S, _I) ->
    if AmLeader ->
	    {reply, {true, Dict}, S};
       true ->
	    {reply, false, S}
    end;
handle_call({lookup, F}, _From, #st{dict = Dict} = S, _I) ->
    Reply = F(Dict),
    {reply, Reply, S}.

%% @spec handle_cast(Msg::term(), State::state(), I::info()) ->
%%    {noreply, NState}
%%  | commonReply()
%%
%% @doc Equivalent to `Mod:handle_call/3' in a gen_server, except
%% (<b>NOTE</b>) for the possible return values.
%%
handle_cast(_Msg, S, _I) ->
    {noreply, S}.

%% @spec handle_info(Msg::term(), State::state(), I::info()) ->
%%     {noreply, NState}
%%   | commonReply()
%%
%% @doc Equivalent to `Mod:handle_info/3' in a gen_server,
%% except (<b>NOTE</b>) for the possible return values.
%%
%% This function will be called in response to any incoming message
%% not recognized as a call, cast, leader_call, leader_cast, from_leader
%% message, internal leader negotiation message or system message.
%% @end
handle_info(_Msg, S, _I) ->
    {noreply, S}.

%% @spec code_change(FromVsn::string(), OldState::term(),
%%                   I::info(), Extra::term()) ->
%%       {ok, NState}
%%
%%    NState = state()
%%
%% @doc Similar to `code_change/3' in a gen_server callback module, with
%% the exception of the added argument.
%% @end
code_change(_FromVsn, S, _I, _Extra) ->
    {ok, S}.

%% @spec terminate(Reason::term(), State::state()) -> Void
%%
%% @doc Equivalent to `terminate/2' in a gen_server callback
%% module.
%% @end
terminate(_Reason, _S) ->
    ok.
