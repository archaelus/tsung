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
%%%  Created : 15 Feb 2001 by Nicolas Niclausse <nniclausse@IDEALX.com>

-module(ts_client).
-vc('$Id$ ').
-author('nicolas.niclausse@IDEALX.com').
-modified_by('jflecomte@IDEALX.com').

-behaviour(gen_server).

-include("../include/ts_profile.hrl").

%% External exports
-export([start/1, next/1, close/1]).

%% gen_server callbacks
-export([init/1, init/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {rcvpid, % pid of receiving process
				server, % name (or IP) of server
				port,   % server port
				protocol,   % gen_tcp, gen_udp or ssl
				socket,     % 
				clienttype, %
				parsetype,  % type of client (parse or noparse)
				mestype,    % type of messages (dynamic or static)
				profile,    % list of requests parameters
				persistent, % if true, don't exit when connexion is closed
				lasttimeout,% value of the last timeout
				timestamp,  % previous message date
				count       % number of requests waiting to be sent
			   }).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(Opts) ->
	?PRINTDEBUG("Starting with opts: ~p~n",[Opts],?DEB),
	gen_server:start(?MODULE, Opts, []).

close(Pid) ->
	gen_server:cast(Pid, {closed, Pid}).

next(Pid) ->
	gen_server:cast(Pid, {next_msg}).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_server
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%----------------------------------------------------------------------
init([Profile, {CType, PType, static, Persistent}]) ->
	?PRINTDEBUG2("Init ... static~n",?DEB),
	init([Profile, {CType, PType, static, Persistent}], length(Profile));

init([Profile, {CType, PType, dynamic, Persistent}]) ->
	?PRINTDEBUG2("Init ... dynamic~n",?DEB),
	random:seed(),
	init([Profile, {CType, PType, static, Persistent}],
		 ?messages_number + length(Profile) - 1);

init(Args) ->
	?PRINTDEBUG("Init ... with unknown args ~p~n",[Args],?DEB).
	

init([Profile, {CType, PType, MType, Persistent}], Count) ->
	%%init seed
	?PRINTDEBUG("Init ... started with count = ~p  ~n",[Count],?DEB),
%    random:seed(ts_utils:init_seed()),
%	?PRINTDEBUG2("seed OK  ~n",?DEB),

    {ServerName, Port, Protocol} = ts_profile:get_server(), % get server profile
    % open connection
	Opts = protocol_options(Protocol),
    case Protocol:connect(ServerName, Port, Opts) of
		{ok, Socket} -> 
	    % start a new process for receiving messages from the server
			case ts_client_rcv:start({PType,
									CType, self(),
									Socket,
									?tcp_timeout, 
									no_ack,
									?monitoring}) of 
				{ok, Pid} ->
					?PRINTDEBUG2("rcv server started ~n",?DEB),
					ts_mon:newclient({self(), now()}),
					Protocol:controlling_process(Socket, Pid),
					{ok, #state{rcvpid = Pid, socket = Socket, port = Port,
								server= ServerName, profile= Profile,
								protocol = Protocol,
								clienttype = CType, mestype = MType,
								persistent = Persistent,
								count = Count, parsetype = PType}, 1};
				{error, Reason} ->
					?PRINTDEBUG("Can't start rcv process ~p~n",
								[Reason],?ERR),
					{stop, Reason}
			end;
		{error, Reason} ->
			?PRINTDEBUG("Connect Error: ~p~n",[Reason],?ERR),
			{stop, connfailed}
    end.


%%----------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_call(Request, From, State) ->
	Reply = ok,
	{reply, Reply, State}.

%%----------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_cast({next_msg}, State) when State#state.lasttimeout == infinity ->
	?PRINTDEBUG("next_msg, count is ~p~n", [State#state.count], ?DEB),
	{noreply, State#state{lasttimeout=1}, 1};
handle_cast({next_msg}, State) ->
	?PRINTDEBUG2("next_msg (infinite timeout)",?DEB),
	{noreply, State, State#state.lasttimeout};
%% more case to handle ?


%% to be done : what about the current timer ?
handle_cast({add_messages, Messages}, State) ->
	OldProfile = State#state.profile,
	OldCount = State#state.count,
	{noreply, State#state{profile = Messages ++ OldProfile, 
						  count = OldCount + length(Messages)}, 1};

handle_cast({closed, Pid}, State) when State#state.persistent == true   ->
	?PRINTDEBUG2("connection closed, stay alive (persistent)",?DEB),
	%% TODO: set the timeout correctly ?
	Elapsed  = ts_utils:elapsed(State#state.timestamp, now()),
	ThinkTime= round(State#state.lasttimeout-Elapsed/1000),
	if 
		ThinkTime > 0 ->
			?PRINTDEBUG("setting new thinktime to: ~p~n!",[ThinkTime], ?DEB),
			{noreply,  State#state{socket = none}, ThinkTime};
		true ->
			?PRINTDEBUG("negative thinktime after connexion closed ~p:~p~n!",[State#state.lasttimeout, Elapsed/1000], ?WARN),
			{noreply,  State#state{socket = none}, 1}
	end;
handle_cast({closed, Pid}, State) ->
	{stop, normal, State};

handle_cast({timeout, Pid}, State) ->
	{stop, timeoutrcv, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%----------------------------------------------------------------------
handle_info(timeout, State) when State#state.count > 0 ->
	Len = length(State#state.profile), % length is O(n), maybe we should do it differently
	[Profile | Pending] = State#state.profile,
	case {Profile#message.type, State#state.count} of 
		{dynamic, Len } -> % don't forget that Len is already set !
			%% no dynamic message remaining
			Thinktime = thinktime(),
			PendingProfile = Pending;
		{static, _Len} ->
			Thinktime = Profile#message.thinktime,
			PendingProfile = Pending;
		{dynamic, _} -> %% keep the same profile until all dynamic messages done
			Thinktime = thinktime(),
			PendingProfile = State#state.profile
	end,
	Count = State#state.count-1,
	Message = ts_profile:get_message(State#state.clienttype,
								  Profile#message.param),
	Now = now(),
	ts_client_rcv:wait_ack(State#state.rcvpid,Profile#message.ack, Now),
	%% reconnect if needed
	Protocol = State#state.protocol,
	Socket = reconnect(State#state.socket, State#state.server, State#state.port,
					   Protocol, State#state.rcvpid),
	case {Profile#message.ack, Count} of 
		{no_ack, _} ->
			Timeout = Thinktime;
		{Else, 0} ->
			?PRINTDEBUG("Last Message, setting Thinktime to: ~p~n.", [Thinktime], ?DEB),
			Timeout = Thinktime;
		{Else, _} ->
			Timeout = infinity
	end,
    case send(Protocol, Socket, Message) of
		ok -> 
			ts_mon:sendmes({self(), Now, Message}),
			{noreply, State#state{socket= Socket, count = Count,
								  profile = PendingProfile,
								  timestamp = Now,
								  lasttimeout = Thinktime},
			 Timeout}; 
		{error, closed} -> 
			?PRINTDEBUG2("connection close while sending message !~n.",  ?WARN),
			case State#state.persistent of 
				true ->
					RetryTimeout = ?client_retry_timeout,
					{noreply, State#state{lasttimeout=RetryTimeout}, 
					 RetryTimeout}; % try again in 10ms
				_ ->
					{stop, closed, State}
			end;
		{error, Reason} -> 
			?PRINTDEBUG(
			   "Error: Unable to send data from process ~p, reason: ~p~n.", 
			   [self(), Reason],?ERR),
			{stop, Reason, State}
	end;

%% no more messages to send
handle_info(timeout, State)  ->
	Protocol = State#state.protocol,
	case State#state.socket of 
		none ->
			{stop, normal, State};
		Else ->
			Protocol:close(State#state.socket),
			{stop, normal, State}
	end.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%%----------------------------------------------------------------------
terminate(Reason, State) ->
	?PRINTDEBUG("Stop, reason= ~p~n",[Reason],?INFO),
	ts_mon:endclient({self(), now()}),
	ts_client_rcv:stop(State#state.rcvpid),
	ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: reconnect/4
%% Returns: {Socket   }          |
%%          {stop, Reason}
%% purpose: try to reconnect if this is needed (when the socket is set to none)
%%----------------------------------------------------------------------
reconnect(none, ServerName, Port, Protocol, Pid) ->
	?PRINTDEBUG("Try to reconnect to: ~p (~p)~n",[ServerName, Pid], ?DEB),
	Opts = protocol_options(Protocol),
    case Protocol:connect(ServerName, Port, Opts) of
		{ok, Socket} -> 
			Protocol:controlling_process(Socket, Pid),
			Socket;
		{error, Reason} ->
			?PRINTDEBUG("Error: ~p~n",[Reason],?ERR),
			{stop, connfailed}
    end;
reconnect(Socket, Server, Port, Protocol, Pid) ->
	Socket.

%%----------------------------------------------------------------------
%% Func: thinktime/0
%%----------------------------------------------------------------------
thinktime() ->
	round(ts_stats:exponential(?messages_intensity)).

%%----------------------------------------------------------------------
%% this fonction is used to avoid the costly M:fun form of function call
%% see http://www.erlang.org/doc/r9b/doc/efficiency_guide/
%%----------------------------------------------------------------------
send(gen_tcp,Socket,Message) ->
    gen_tcp:send(Socket,Message);
send(ssl,Socket,Message) ->
    ssl:send(Socket,Message);
send(gen_udp,Socket,Message) ->
    gen_udp:send(Socket,Message).
%%----------------------------------------------------------------------
%% Func: protocol_options/1
%%----------------------------------------------------------------------
protocol_options(ssl) ->
	[binary, 
	 {active, true},
	 {ciphers, ?ssl_ciphers}
	];
protocol_options(gen_tcp) ->
	[binary, 
	 {active, true},
	 {keepalive, true}
	];
protocol_options(gen_udp) ->
	[binary, 
	 {active, true},
	 {keepalive, true}
	].
	
