%%%  This code was developped by IDEALX (http://IDEALX.org/) and
%%%  contributors (their names can be found in the CONTRIBUTORS file).
%%%  Copyright (C) 2000-2001 IDEALX
%%%
%%%  This program is free software; you can redistribute it and/or modify
%%%  it under the terms of the GNU General Public License as published by
%%%  the Free Software Foundation; either version 2 of the License, or
%%%  (at your option) any later version.
%%%
%%%  This program is distributed in the hope that it will be useful,
%%%  but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%  GNU General Public License for more details.
%%%
%%%  You should have received a copy of the GNU General Public License
%%%  along with this program; if not, write to the Free Software
%%%  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
%%% 

%%% This module launch clients (ts_client module) given a number of
%%% clients and the intensity of the arrival process (intensity =
%%% inverse of the mean of inter arrival). The arrival process is a
%%% Poisson Process (ie, inter-arrivals are independant and exponential)

-module(ts_launcher).
-created('Date: 2000/10/23 12:09:57 nniclausse ').
-vc('$Id$ ').
-author('nicolas.niclausse@IDEALX.com').

-include("ts_profile.hrl").

-behaviour(gen_fsm). %% a primitive gen_fsm with two state: launcher and wait

%% External exports
-export([start/0, launch/1]).

%% gen_fsm callbacks
-export([init/1, launcher/2,  wait/2, finish/2, handle_event/3,
		 handle_sync_event/4, handle_info/3, terminate/3]).

-record(state, {nusers,
                phases =[],
                intensity,
                maxusers %% if maxusers are currently active, launch a
                         %% new beam to handle the new users
               }).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: start/0
%%--------------------------------------------------------------------
start() ->
	?LOG("starting ~n", ?DEB),
	gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% Function: launch/1
%%--------------------------------------------------------------------
%% Start clients with given interarrival (can be empty list)
launch({Node, Arrivals}) ->
	?LOGF("starting on node ~p~n",[[Node]], ?DEB),
	gen_fsm:send_event({?MODULE, Node}, {launch, Arrivals}).


%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}                   
%%----------------------------------------------------------------------
init([]) ->
    {Msec, Sec, Nsec} = ts_utils:init_seed(),
    random:seed(Msec,Sec,Nsec),
	{ok, wait, #state{}}.
%	{ok, wait, #state{interarrival = ts_stats:exponential(Intensity,Clients),
%                      intensity = Intensity}}.

%%----------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                         
%%----------------------------------------------------------------------
wait({launch, []}, State) ->
    {ok, MyHostName} = ts_utils:node_to_hostname(node()),
	?LOGF("Launch msg receive (~p)~n",[MyHostName], ?NOTICE),
    {ok, {[{Intensity, Users}| Rest], StartDate, Max}} = 
        ts_config_server:get_client_config(MyHostName),
    WaitBeforeStart = ts_utils:elapsed(now(), StartDate),
    Warm_timeout = round(ts_stats:exponential(Intensity) + WaitBeforeStart),
	?LOGF("Activate launcher (~p users) in ~p msec ~n",[Users, Warm_timeout], ?NOTICE),
	{next_state, launcher, State#state{phases = Rest, nusers = Users, 
                                       intensity = Intensity, maxusers= Max },  Warm_timeout};

wait({launch, {[{Intensity, Users}| Rest], Max}}, State) ->
    ?LOGF("Starting with  ~p users todo in the current phase (max is ~p)~n",
          [Users, Max],?DEB),
	{next_state, launcher, State#state{phases = Rest, nusers = Users, 
                                       intensity = Intensity, maxusers= Max }, ?short_timeout}.

launcher(Event, State=#state{nusers = 0, phases = [] }) ->
	?LOG("no more clients to start, wait  ~n",?DEB),
    {next_state, finish, #state{}, ?check_noclient_timeout};

launcher(timeout, State=#state{nusers    = Users,
                               phases    = Phases,
                               intensity = Intensity}) ->
    Wait = do_launch(Intensity),
    case check_max_raised(State) of
        true ->
            {next_state, finish, State, ?check_noclient_timeout};
        false->
            case {Users, Phases} of 
                {0, [{NewIntensity, NewUsers}|Rest]} -> % new phase
                    ?LOGF("Start a new arrival phase (~p ~p) ~n",
                         [NewUsers, NewIntensity], ?NOTICE),
                    {next_state,launcher,State#state{phases = Rest, 
                                                     nusers = NewUsers,
                                                     intensity = NewIntensity},
                     Wait};
                _  ->{next_state,launcher,State#state{nusers = Users-1} , Wait}
            end
    end.
    
finish(timeout, State) ->
    case ts_client_sup:active_clients() of
       0 -> %% no users left, stop
            ?LOG("No more active users, stop beam~n", ?NOTICE),
            ts_mon:stop(),
            slave:stop(node()), %% commit suicide
            {stop, normal, State}; %% should never be executed
        ActiveClients ->
            ?LOGF("Still ~p active client(s)~n", [ActiveClients],?NOTICE),
            {next_state, finish, State, ?check_noclient_timeout}
    end.


%%----------------------------------------------------------------------
%% Func: StateName/3
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}                    
%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                         
%%----------------------------------------------------------------------
handle_event(Event, StateName, StateData) ->
	{next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}                    
%%----------------------------------------------------------------------
handle_sync_event(Event, From, StateName, StateData) ->
	Reply = ok,
	{reply, Reply, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                         
%%----------------------------------------------------------------------
handle_info(Info, StateName, StateData) ->
	{next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(Reason, StateName, StatData) ->
	?LOGF("launcher terminating for reason~p~n",[Reason], ?INFO),
	ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

check_max_raised(#state{phases=Phases,maxusers=Max,nusers=Users,
                        intensity=Intensity})->
    ActiveClients =  ts_client_sup:active_clients(),
    case ActiveClients >= Max of
        true -> %% max users reached, must start a new beam
            ?LOG("Max number of clients reached, must start a new beam~n", ?NOTICE),
            {ok, MyHostName} = ts_utils:node_to_hostname(node()),
            Args = case Users of 
                       0 ->  Phases;
                       _ -> [{Intensity,Users-1}|Phases]
                   end,
            ts_config_server:newbeam(list_to_atom(MyHostName), {Args, Max}),
            true;
        false ->
            ?LOGF("Current clients on beam: ~p~n", [ActiveClients],?DEB),
            false
    end.

do_launch(Intensity)->
    %%Get one client
    %% Id = ts_user_server:get_idle(),%% FIXME: make it work again with new config server
    %%set the profile of the client
    {ok, Profile} = ts_config_server:get_next_session(),
    ts_client_sup:start_child(Profile),
    X = round(ts_stats:exponential(Intensity)),
    ?LOGF("client launched, waiting ~p msec before launching next client",
          [X],?DEB),
    X.
