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

%%% In addition, as a special exception, you have the permission to
%%% link the code of this program with any library released under
%%% the EPL license and distribute linked combinations including
%%% the two.

-module(ts_utils).
-vc('$Id$ ').
-author('nicolas.niclausse@niclux.org').

-include("ts_profile.hrl").

%% to get file_info record definition
-include_lib("kernel/include/file.hrl").

%% user interface
-export([debug/3, debug/4, get_val/1, init_seed/0, chop/1, elapsed/2,
         now_sec/0, node_to_hostname/1, add_time/2, keyumerge/3,
         level2int/1, mkey1search/2, close_socket/2, datestr/0, datestr/1,
         erl_system_args/0, erl_system_args/1, setsubdir/1, export_text/1,
         foreach_parallel/2, spawn_par/3, inet_setopts/3, resolve/2,
         stop_all/2, stop_all/3, stop_all/4, join/2, split2/2, split2/3,
         make_dir_rec/1, is_ip/1, from_https/1, to_https/1, keymax/2,
         check_sum/3, check_sum/5, clean_str/1, file_to_list/1]).

level2int("debug")     -> ?DEB;
level2int("info")      -> ?INFO;
level2int("notice")    -> ?NOTICE;
level2int("warning")   -> ?WARN;
level2int("error")     -> ?ERR;
level2int("critical")  -> ?CRIT;
level2int("emergency") -> ?EMERG.

-define(QUOT,"&quot;").
-define(APOS,"&apos;").
-define(AMP,"&amp;").
-define(GT,"&gt;").
-define(LT,"&lt;").

%%----------------------------------------------------------------------
%% Func: get_val/1
%% Purpose: return environnement variable value for the current application
%% Returns: Value | {undef_var, Var}
%%----------------------------------------------------------------------
get_val(Var) ->
	case application:get_env(Var) of 
		{ok, Val} ->
			ensure_string(Var, Val);
		undefined -> % undef, application not started, try to get var from stdlib
            case application:get_env(stdlib,Var) of 
                undefined -> {undef_var, Var};
                {ok,Val}  -> ensure_string(Var, Val)
            end
	end.


%% ensure atom to string conversion of environnement variable
%% This is intended to fix a problem making tsung run under Windows
%%  I convert parameter that are called from the command-line
ensure_string(log_file, Atom) when atom(Atom) ->
    atom_to_list(Atom);
ensure_string(proxy_log_file, Atom) when atom(Atom) ->
    atom_to_list(Atom);
ensure_string(config_file, Atom) when atom(Atom) ->
    atom_to_list(Atom);
ensure_string(_, Other) ->
    Other.

%%----------------------------------------------------------------------
%% Func: debug/3
%% Purpose: print debug message if level is high enough
%%----------------------------------------------------------------------
debug(From, Message, Level) ->
	debug(From, Message, [], Level).

debug(From, Message, Args, Level) ->
	Debug_level = ?config(debug_level),
	if 
		Level =< Debug_level ->
			error_logger:info_msg("~20s:(~p:~p) "++ Message,
					  [From, Level, self()] ++ Args);
		true ->
			nodebug
	end.

%%----------------------------------------------------------------------
%% Func: elapsed/2
%% Purpose: print elapsed time in milliseconds
%% Returns: integer
%%----------------------------------------------------------------------
elapsed({Before1, Before2, Before3}, {After1, After2, After3}) ->
    After  = After1  * 1000000000  + After2  * 1000 + After3/1000,
    Before = Before1 * 1000000000  + Before2 * 1000 + Before3/1000,
    After - Before.

%%----------------------------------------------------------------------
%% Func: chop/1
%% Purpose: remove trailing "\n"
%%----------------------------------------------------------------------
chop(String) ->
	string:strip(String, right, 10).

%%----------------------------------------------------------------------
%% Func: clean_str/1
%% Purpose: remove "\n" and space at the beginning and at that end of a string
%%----------------------------------------------------------------------
clean_str(String) ->
	Str1 = string:strip(String, both, 10),
	Str2 = string:strip(Str1),
	Str3 = string:strip(Str2, both, 10),
	string:strip(Str3).
    

%%----------------------------------------------------------------------
%% Func: init_seed/0
%%----------------------------------------------------------------------
init_seed()->
    {A,B,C}=now(),
	random:seed(A,B,C).

%%----------------------------------------------------------------------
%% Func: now_sec/0
%% Purpose: returns unix like elapsed time in sec
%%----------------------------------------------------------------------
now_sec() ->
	{MSec, Seconds, _} = now(),
	Seconds+1000000*MSec.

%%----------------------------------------------------------------------
%% Func: add_time/2
%% Purpose: add given Seconds to given Time (same format as now())
%%----------------------------------------------------------------------
add_time({MSec, Seconds, MicroSec}, SecToAdd) when is_integer(SecToAdd)->
    NewSec = Seconds +SecToAdd,
    case NewSec < 1000000 of
        true -> {MSec, NewSec, MicroSec};
        false ->{MSec+ (NewSec div 100000), NewSec-1000000, MicroSec}
    end.

node_to_hostname(Node) ->
    [_Nodename, Hostname] = string:tokens( atom_to_list(Node), "@"),
    {ok, Hostname}.

%%----------------------------------------------------------------------
%% Func: mkey1search/2
%% Purpose: multiple key1search:
%% Take as input list of {Key, Value} tuples (length 2).
%% Return the list of values corresponding to a given key
%% It is assumed here that there might be several identical keys in the list
%% unlike the lists:key... functions.
%%----------------------------------------------------------------------
mkey1search(List, Key) ->
    Results = lists:foldl(
		fun({MatchKey, Value}, Acc) when MatchKey == Key ->
			[Value | Acc];
		   ({_OtherKey, _Value}, Acc) ->
			Acc 
		end,
		[],
		List),
    case Results of 
	[] -> undefined;
	Results -> lists:reverse(Results)
    end.

%% close socket if it exists
close_socket(_Protocol, none) -> ok;
close_socket(gen_tcp, Socket)-> gen_tcp:close(Socket);
close_socket(ssl, Socket)    -> ssl:close(Socket);
close_socket(gen_udp, Socket)-> gen_udp:close(Socket).

%%----------------------------------------------------------------------
%% datestr/0
%% Purpose: print date as a string 'YYYY:MM:DD-HH:MM'
%%----------------------------------------------------------------------
datestr()->
    datestr(erlang:universaltime()).

%%----------------------------------------------------------------------
%% datestr/1
%%----------------------------------------------------------------------
datestr({{Y,M,D},{H,Min,_S}})->
	io_lib:format("~w~2.10.0b~2.10.0b-~2.10.0b:~2.10.0b",[Y,M,D,H,Min]).

%%----------------------------------------------------------------------
%% erl_system_args/0
%%----------------------------------------------------------------------
erl_system_args()->
    erl_system_args(extended).
erl_system_args(basic)->
	Rsh = case  init:get_argument(rsh) of 
              {ok,[["ssh"]]}  -> " -rsh ssh ";
              _ -> " "
          end,
    lists:append([Rsh, " -detached -setcookie  ",
                  atom_to_list(erlang:get_cookie()) ]);
erl_system_args(extended)->
    BasicArgs  = erl_system_args(basic),
    SetArg = fun(A) -> case init:get_argument(A) of 
                           error     -> " ";
                           {ok,[[]]} -> " -" ++atom_to_list(A)++" ";
                           {ok,[[Val|_]]} when is_list(Val)-> " -" ++atom_to_list(A)++Val++" "
                       end 
             end,
	Shared = SetArg(shared),
	Hybrid = SetArg(hybrid),
	Smp = SetArg(smp),
    Inet = case init:get_argument(kernel) of
               {ok,[["inetrc",InetRcFile]]} -> 
                   ?LOGF("Get inetrc= ~p~n",[InetRcFile],?NOTICE),
                   " -kernel inetrc '"++ InetRcFile ++ "'" ;
               _ -> " "
           end,
	Mea = case  erlang:system_info(version) of 
              "5.3" ++ _Tail     -> " +Mea r10b ";
              _ -> " "
          end,
    lists:append([BasicArgs, Shared, Hybrid, Smp, Mea, Inet]).

%%----------------------------------------------------------------------
%% setsubdir/1
%% Purpose: all log files are created in a directory whose name is the
%%          start date of the test.
%% ----------------------------------------------------------------------
setsubdir(FileName) ->
    Date = datestr(),
    Path = filename:dirname(FileName),
    Base = filename:basename(FileName),
    Dir  = filename:join(Path, Date),
    case file:make_dir(Dir) of
        ok ->
            {ok, {Dir, Base}};
        {error, eexist} ->
            ?DebugF("Directory ~s already exist~n",[Dir]),
            {ok, {Dir, Base}};
        Err ->
            ?LOGF("Can't create directory ~s (~p)!~n",[Dir, Err],?EMERG),
            {error, Err}
    end.

%%----------------------------------------------------------------------
%% export_text/1
%% Purpose: Escape special characters `<', `&', `'' and `"' flattening
%%          the text.
%%----------------------------------------------------------------------
export_text(T) ->
    export_text(T, []).

export_text(Bin, Cont) when is_binary(Bin) ->
    export_text(binary_to_list(Bin), Cont);
export_text([], Exported) -> 
    lists:flatten(lists:reverse(Exported));
export_text([$< | T], Cont) ->
    export_text(T, [?LT | Cont]);
export_text([$> | T], Cont) ->
    export_text(T, [?GT | Cont]);
export_text([$& | T], Cont) ->
    export_text(T, [?AMP | Cont]);
export_text([$' | T], Cont) ->
    export_text(T, [?APOS | Cont]);
export_text([$" | T], Cont) ->
    export_text(T, [?QUOT | Cont]);
export_text([C | T], Cont) ->
    export_text(T, [C | Cont]).

%%----------------------------------------------------------------------
%% stop_all/2
%%----------------------------------------------------------------------
stop_all(Host, Name) ->
	stop_all(Host, Name, "Tsung").

stop_all([Host],Name,MsgName)  ->
    VoidFun = fun(_A)-> ok end,
    stop_all([Host],Name,MsgName, VoidFun ).

stop_all([Host],Name,MsgName,Fun) when atom(Host) ->
    _List= net_adm:world_list([Host]),
    global:sync(),
	case global:whereis_name(Name) of 
		undefined ->
			Msg = MsgName ++" is not running on " ++ atom_to_list(Host),
			erlang:display(Msg);
		Pid ->
			Controller_Node = node(Pid),
            Fun(Controller_Node),
			slave:stop(Controller_Node)
	end;
stop_all(_,_,_,_)->
	erlang:display("Bad Hostname").

%%----------------------------------------------------------------------
%% make_dir_rec/1
%% Purpose: create directory. Missing parent directories ARE created
%%----------------------------------------------------------------------
make_dir_rec(DirName) when list(DirName) ->
    case  file:read_file_info(DirName) of 
        {ok, #file_info{type=directory}} ->
            ok;
        {error,enoent} ->
            make_dir_rec("", filename:split(DirName));
        {error, Reason}  ->
            {error,Reason}
    end.

make_dir_rec(_Path, []) ->
    ok;
make_dir_rec(Path, [Parent|Childs]) ->
    CurrentDir=filename:join([Path,Parent]),
    case  file:read_file_info(CurrentDir) of 
        {ok, #file_info{type=directory}} ->
            make_dir_rec(CurrentDir, Childs);
        {error,enoent} ->
            case file:make_dir(CurrentDir) of
                ok ->
                    make_dir_rec(CurrentDir, Childs);
                Error ->
                    Error
            end;
        {error, Reason}  ->
            {error,Reason}
    end.

%% check if a string is an IP (as "192.168.0.1")
is_ip(String) when list(String) ->
    EightBit="(2[0-4][0-9]|25[0-5]|1[0-9][0-9]|[0-9][0-9]|[0-9])",
    RegExp = lists:append(["^",EightBit,"\.",EightBit,"\.",EightBit,"\.",EightBit,"$"]), %"
    case regexp:first_match(String, RegExp) of 
       {match,_,_} -> true;
       _ -> false
    end;                            
is_ip(_) -> false.

%%----------------------------------------------------------------------
%% to_https/1
%% Purpose: rewrite https URL, to act as a pure non ssl proxy
%%----------------------------------------------------------------------
to_https({url, "http://{"++Rest})-> "https://" ++ Rest;
to_https({url, "http://%7B"++Rest})-> "https://" ++ Rest;
to_https({url, URL})-> URL;
to_https({request, String}) when is_list(String) ->
    {ok,TmpString,_} = regexp:gsub(String,"http://{","https://"),
    {ok,NewString,_} = regexp:gsub(TmpString,"http://%7B","https://"),
    {ok,TmpString2,_} = regexp:gsub(NewString,"Host: {","Host: "),
    {ok,RealString,_} = regexp:gsub(TmpString2,"Host: %7B","Host: "),
    {ok, RealString};
to_https(_) -> {error, bad_input}.

from_https(String) when is_list(String)->
    {ok,NewString,RepCount} = regexp:gsub(String,"https://","http://{"),
    case RepCount of 
        0    -> ok;
        Count-> ?LOGF("substitute https: ~p times~n",[Count],?DEB)
    end,
    {ok, NewString};
from_https(_) -> {error, bad_input}.
    

%% A Perl-style join --- concatenates all strings in Strings,
%% separated by Sep.
join(_Sep, []) -> [];
join(Sep, List) when is_list(List)->
    join2(Sep, lists:reverse(List)).
join2(Sep, [First | List]) when is_integer(First)->
    join2(Sep, [integer_to_list(First) | List]);
join2(Sep, [First | List]) when is_float(First)->
    join2(Sep, [float_to_list(First) | List]);
join2(Sep, [First | List]) when is_list(First)->
        lists:foldl(fun(X, Sum) -> X ++ Sep ++ Sum end, First, List).

%% split a string in 2 (at first occurence of char)
split2(String,Chr) ->
    split2(String,Chr,nostrip).

split2(String,Chr,strip) -> % split and strip blanks
    {A, B} = split2(String,Chr,nostrip),
    {string:strip(A), string:strip(B)};
split2(String,Chr,nostrip) ->
    case string:chr(String, Chr) of
        0   -> {String,[]};
        Pos -> {string:substr(String,1,Pos-1), string:substr(String,Pos+1)}
    end.


foreach_parallel(Fun, List)->
    SpawnFun = fun(A) -> spawn(?MODULE, spawn_par, lists:append([[Fun,self()], [A]])) end,
    lists:foreach(SpawnFun, List),
    wait_pids(length(List)).

wait_pids(0) -> done;
wait_pids(N) ->
    receive
        {ok, _Pid, _Res } ->
            wait_pids(N-1)
    after ?TIMEOUT_PARALLEL_SPAWN ->
            {error, {timout, N}} % N missing answer
    end.

spawn_par(Fun, PidFrom, Args) ->
    Res = Fun(Args),
    PidFrom ! {ok, self(), Res}.

%%----------------------------------------------------------------------
%% Func: inet_setopts/3
%% Purpose: set inet options depending on the protocol (gen_tcp, gen_udp,
%%  ssl)
%%----------------------------------------------------------------------
inet_setopts(_, none, _) -> %socket was closed before
    none;
inet_setopts(ssl, Socket, Opts) ->
	case ssl:setopts(Socket, Opts) of
		ok ->
			Socket;
		{error, closed} ->
			none;
		Error ->
			?LOGF("Error while setting ssl options ~p ~p ~n", [Opts, Error], ?ERR),
            none
	end;
inet_setopts(Type, Socket,  Opts) when ( (Type == tcp) or (Type == gen_tcp)) ->
	case inet:setopts(Socket, Opts) of
		ok ->
			Socket;
		{error, closed} ->
			none;
		Error ->
			?LOGF("Error while setting inet options ~p ~p ~n", [Opts, Error], ?ERR),
            none
	end;
%% FIXME: UDP not tested
inet_setopts(Type, Socket,  Opts)  when ( (Type == udp) or (Type == gen_udp)) ->
	ok = inet:setopts(Socket, Opts),
    Socket.

%%----------------------------------------------------------------------
%% Func: check_sum/3
%% Purpose: check sum of int equals 100. 
%% Args: List of tuples, index of int in tuple, Error msg
%% Returns ok | {error, {bad_sum, Msg}}
%%----------------------------------------------------------------------
check_sum(RecList, Index, ErrorMsg) ->
    %% popularity may be a float number. 5.10-2 precision
    check_sum(RecList, Index, 100, 0.05, ErrorMsg).
check_sum(RecList, Index, Total, Epsilon, ErrorMsg) ->
    %% we use the tuple representation of a record !
    Sum = lists:foldl(fun(X, Sum) -> element(Index,X)+Sum end, 0, RecList),
    Delta = abs(Sum - Total),
    case Delta < Epsilon of
        true -> ok;
        false -> {error, {bad_sum, Sum ,ErrorMsg}}
    end.

%%----------------------------------------------------------------------
%% Func: file_to_list/1
%% Purpose: read a file line by line and put them in a list
%% Args: filename
%% Returns {ok, List} | {error, Reason}
%%----------------------------------------------------------------------
file_to_list(FileName) ->
    case file:open(FileName, read) of
        {error, Reason} ->
			{error, Reason};
        {ok , File} ->
            Lines = read_lines(File),
            file:close(File),
			{ok, Lines}
    end.

read_lines(FD) ->read_lines(FD,io:get_line(FD,""),[]).

read_lines(_FD, eof, L) ->
    lists:reverse(L);
read_lines(FD, Line, L) ->
    read_lines(FD, io:get_line(FD,""),[chop(Line)|L]).

%%----------------------------------------------------------------------
%% Func: keyumerge/3
%% Purpose: Same as lists:keymerge, but remove duplicates (use items from A)
%% Returns: List
%%----------------------------------------------------------------------
keyumerge(_N,[],B)->B;
keyumerge(N,[A|Rest],B)->
    Key = element(N,A),
    % remove old values if it exists
    NewB = lists:keydelete(Key, N, B),
    keyumerge(N,Rest, [A|NewB]).

%%----------------------------------------------------------------------
%% Func: keymax/2
%% Purpose: Return Max of Nth element of a list of tuples
%% Returns: Number
%%----------------------------------------------------------------------
keymax(N,[L])-> element(N,L);
keymax(N,[E|Tail])->
    keymax(N,Tail,element(N,E)).

keymax(_N,[],Max)-> Max;
keymax(N,[E|Tail],Max)->
    keymax(N,Tail,lists:max([Max,element(N,E)])).

%%--------------------------------------------------------------------
%% Function: resolve/2
%% Description: return cached hostname or gethostbyaddr for given ip
%%--------------------------------------------------------------------
resolve(Ip, Cache) ->
    case lists:keysearch(Ip, 1, Cache) of
        {value, {Ip, ReverseHostname}} ->
            {ReverseHostname, Cache};
        false ->
            case inet:gethostbyaddr(Ip) of
                {ok, {hostent,ReverseHostname,_,inet,_,_}} ->
                    %% cache dns result and return it
                    ?LOGF("Add ~p -> ~p to DNS cache ~n", [Ip, ReverseHostname],?DEB),
                    {ReverseHostname, [{Ip, ReverseHostname} | Cache]};
                {error, Reason} ->
                    ?LOGF("DNS resolution error on ~p: ~p~n", [Ip, Reason],?WARN),
                    %% cache dns name as IP : {ip, ip} and return Ip
                    NewCache = lists:keymerge(1, Cache, [{Ip, Ip}]),
                    {Ip, NewCache}
            end
    end.
