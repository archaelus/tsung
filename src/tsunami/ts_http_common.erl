%%%  This code was developped by IDEALX (http://IDEALX.org/) and
%%%  contributors (their names can be found in the CONTRIBUTORS file).
%%%  Copyright (C) 2000-2004 IDEALX
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

%%%  In addition, as a special exception, you have the permission to
%%%  link the code of this program with any library released under
%%%  the EPL license and distribute linked combinations including
%%%  the two.

%%% common functions used by http clients to:
%%%  - set HTTP requests
%%%  - parse HTTP response from server

-module(ts_http_common).
-vc('$Id$ ').
-author('nicolas.niclausse@IDEALX.com').

-include("ts_profile.hrl").
-include("ts_http.hrl").

-include("ts_config.hrl").

-export([
         http_get/1,
         http_post/1,
         parse/2,
         parse_req/1,
         parse_req/2
		]).

%%----------------------------------------------------------------------
%% Func: http_get/1
%% Args: #http_request
%%----------------------------------------------------------------------
http_get(#http_request{url=URL, version=Version, cookie=Cookie, 
                       get_ims_date=undefined, soap_action=SOAPAction,
                       server_name=Host, userid=UserId, passwd=Passwd})->
	list_to_binary([?GET, " ", URL," ", "HTTP/", Version, ?CRLF, 
                    "Host: ", Host, ?CRLF,
                    user_agent(),
                    authenticate(UserId,Passwd),
                    soap_action(SOAPAction),
                    set_cookie_header({Cookie, Host, URL}),
                    ?CRLF]);

http_get(#http_request{url=URL, version=Version, cookie=Cookie,
                       get_ims_date=Date, soap_action=SOAPAction,
                       server_name=Host, userid=UserId, passwd=Passwd}) ->
	list_to_binary([?GET, " ", URL," ", "HTTP/", Version, ?CRLF,
                    ["If-Modified-Since: ", Date, ?CRLF],
                    "Host: ", Host, ?CRLF,
                    user_agent(),
                    soap_action(SOAPAction),
                    authenticate(UserId,Passwd),
                    set_cookie_header({Cookie, Host, URL}),
                    ?CRLF]).

%%----------------------------------------------------------------------
%% Func: http_post/1
%% Args: #http_request
%%----------------------------------------------------------------------
http_post(#http_request{url=URL, version=Version, cookie=Cookie,
                        soap_action=SOAPAction, content_type=ContentType,
                        body=Content, server_name=Host,
                        userid=UserId, passwd=Passwd}) ->
	ContentLength=integer_to_list(size(Content)),
	?DebugF("Content Length of POST: ~p~n.", [ContentLength]),
	Headers = [?POST, " ", URL," ", "HTTP/", Version, ?CRLF,
               "Host: ", Host, ?CRLF,
               user_agent(),
               authenticate(UserId,Passwd),
               soap_action(SOAPAction),
               set_cookie_header({Cookie, Host, URL}),
               "Content-Type: ", ContentType, ?CRLF,
               "Content-Length: ",ContentLength, ?CRLF,
               ?CRLF
              ],
	list_to_binary([Headers, Content ]).

%%----------------------------------------------------------------------
%% some HTTP headers functions
%%----------------------------------------------------------------------
authenticate(undefined,_)-> [];
authenticate(_,undefined)-> [];
authenticate(UserId,Passwd)->
    AuthStr = httpd_util:encode_base64(lists:append([UserId,":",Passwd])),
    ["Authorization: Basic ",AuthStr,?CRLF].

user_agent() ->
	["User-Agent: ", ?USER_AGENT, ?CRLF].

soap_action(undefined) -> [];
soap_action(SOAPAction) -> ["SOAPAction: \"", SOAPAction, "\"", ?CRLF].
    

%%----------------------------------------------------------------------
%% Function: set_cookie_header/1
%% Args: Cookies (list), Hostname (string), URL
%% Purpose: set Cookie: Header
%%----------------------------------------------------------------------
set_cookie_header({none, _, _}) -> []; % is it useful ?
set_cookie_header({[], _, _})   -> [];
set_cookie_header({Cookies, Host, URL})-> 
    MatchDomain = fun (A) -> matchdomain_url(A,Host,URL) end,
    CurCookies = lists:filter(MatchDomain, Cookies),
    set_cookie_header(CurCookies, Host, []).

set_cookie_header([], _Host, Acc)   -> [lists:reverse(Acc), ?CRLF];
set_cookie_header([Cookie|Cookies], Host, []) ->
    set_cookie_header(Cookies, Host, [["Cookie: ", cookie_rec2str(Cookie)]]);
set_cookie_header([Cookie|Cookies], Host, Acc) ->
    set_cookie_header(Cookies, Host, [["; ", cookie_rec2str(Cookie)]|Acc]).

cookie_rec2str(#cookie{key=Key, value=Val}) ->
    lists:append([Key,"=",Val]).
                       
matchdomain_url(Cookie, Host, URL) -> % return a cookie only if domain match
    case {string:str(Host,Cookie#cookie.domain), % should use regexp:match
          string:str(URL,Cookie#cookie.path)} of
        {0,_} -> false;
        {_,1} -> true;
        {_,_} -> false
    end.


%%----------------------------------------------------------------------
%% Func: parse/2
%% Args: Data, State
%% Returns: {NewState, Options for socket (list), Close}
%% Purpose: parse the response from the server and keep information
%%  about the response if State#state_rcv.session
%%----------------------------------------------------------------------
parse(closed, State) ->
    {State#state_rcv{session= #http{}, ack_done = true}, [], true};
    
parse(Data, State=#state_rcv{session=HTTP}) when HTTP#http.status == none;
												 HTTP#http.partial == true ->
    List = binary_to_list(Data),
    TotalSize = size(Data),
    Header = State#state_rcv.acc ++ List,

    case parse_headers(HTTP, Header, State#state_rcv.host) of
		%% Partial header:
		{more, HTTPRec, Tail} ->
            ?LOGF("Partial Header: [HTTP=~p : Tail=~p]~n",[HTTPRec, Tail],?DEB),
			{State#state_rcv{ack_done=false,session=HTTPRec,acc=Tail},[],false};
        %% Complete header, chunked encoding
		{ok, Http=#http{content_length=0, chunk_toread=0}, Tail} ->
			DynData = concat_cookies(Http#http.cookie, State#state_rcv.dyndata),
			case parse_chunked(Tail, State#state_rcv{session=Http, acc=[]}) of
				{NewState=#state_rcv{ack_done=false}, Opts} ->
					{NewState#state_rcv{dyndata=DynData}, Opts, false};
				{NewState, Opts} ->
					{NewState#state_rcv{acc=[],dyndata=DynData}, Opts, Http#http.close}
			end;
		{ok, Http=#http{content_length=0, close=true}, _} ->
            %% no content length, close=true: the server will close the connection
			DynData = concat_cookies(Http#http.cookie, State#state_rcv.dyndata),
			{State#state_rcv{session= Http, ack_done = false, 
							 datasize = TotalSize,
							 dyndata= DynData}, [], true};
		{ok, Http, Tail} ->
			DynData = concat_cookies(Http#http.cookie, State#state_rcv.dyndata),
			check_resp_size(Http, length(Tail), DynData, State#state_rcv{acc=[]}, TotalSize)
	end;

%% continued chunked tranfer
parse(Data, State=#state_rcv{session=Http}) when Http#http.chunk_toread >=0 ->
    ?DebugF("Parse chunk data = [~p]~n", [binary_to_list(Data)]),
    case read_chunk_data(Data,State,Http#http.chunk_toread,Http#http.body_size) of
		{NewState=#state_rcv{ack_done=false}, NewOpts}->
            {NewState, NewOpts, false};
		{NewState, NewOpts}->
            {NewState#state_rcv{acc=[]}, NewOpts, Http#http.close}
	end;

%% continued normal tranfer
parse(Data, State) ->
    PreviousSize = State#state_rcv.datasize,
	DataSize = size(Data),
	?DebugF("HTTP Body size=~p ~n",[DataSize]),
    Http = State#state_rcv.session,
	CLength = Http#http.content_length,
	case Http#http.body_size + DataSize of
		CLength -> % end of response
			{State#state_rcv{session=#http{}, acc=[], ack_done = true, datasize = CLength},
			 [], Http#http.close};
		Size ->
			NewHttp = (State#state_rcv.session)#http{body_size = Size},
			{State#state_rcv{session = NewHttp, ack_done = false,
                             datasize = DataSize+PreviousSize}, [], false}
	end.

%%----------------------------------------------------------------------
%% Func: check_resp_size/5
%% Purpose: Check response size
%% Returns: {NewState= record(state_rcv), SockOpts, Close}
%%----------------------------------------------------------------------
check_resp_size(#http{content_length=CLength, close=Close}, CLength, 
				DynData, State, DataSize) ->
	%% end of response
	{State#state_rcv{session= #http{}, ack_done = true,
					 datasize = DataSize,
					 dyndata= DynData}, [], Close};
check_resp_size(#http{content_length=CLength, close = Close}, 
				BodySize, DynData, State, DataSize) when BodySize > CLength ->
	?LOGF("Error: HTTP Body (~p)> Content-Length (~p) !~n",
		  [BodySize, CLength], ?ERR),
	ts_mon:add({ count, http_bad_content_length }),
	{State#state_rcv{session= #http{}, ack_done = true,
					 datasize = DataSize,
					 dyndata= DynData}, [], Close};
check_resp_size(Http, BodySize, DynData, State, DataSize) -> 
    %% need to read more data
	{State#state_rcv{session  = Http#http{ body_size=BodySize},
					 ack_done = false,
					 datasize = DataSize,
					 dyndata  = DynData},[],false}.
												 
%%----------------------------------------------------------------------
%% Func: parse_chunked/2
%% Purpose: parse 'Transfer-Encoding: chunked' for HTTP/1.1
%% Returns: {NewState= record(state_rcv), SockOpts, Close}
%%----------------------------------------------------------------------
parse_chunked(Body, State)->
    ?DebugF("Parse chunk data = [~p]~n", [Body]),
    read_chunk(list_to_binary(Body), State, 0, 0).

%%----------------------------------------------------------------------
%% Func: read_chunk/4
%% Purpose: the real stuff for parsing chunks is here
%% Returns: {NewState= record(state_rcv), SockOpts, Close}
%%----------------------------------------------------------------------
read_chunk(<<>>, State, Int, Acc) ->
    ?LOGF("No data in chunk [Int=~p, Acc=~p] ~n", [Int,Acc],?INFO),
    AccInt = list_to_binary(httpd_util:integer_to_hexlist(Int)),
    { State#state_rcv{acc = AccInt, ack_done = false }, [] }; % read more data
%% this code has been inspired by inets/http_lib.erl
%% Extensions not implemented
read_chunk(<<Char:1/binary, Data/binary>>, State, Int, Acc) ->
    case Char of
	<<C>> when $0=<C,C=<$9 ->
	    read_chunk(Data, State, 16*Int+(C-$0), Acc+1);
	<<C>> when $a=<C,C=<$f ->
	    read_chunk(Data, State, 16*Int+10+(C-$a), Acc+1);
	<<C>> when $A=<C,C=<$F ->
	    read_chunk(Data, State, 16*Int+10+(C-$A), Acc+1);
	<<?CR>> when Int>0 ->
	    read_chunk_data(Data, State, Int+3, Acc+1);
	<<?CR>> when Int==0, size(Data) == 3 -> %% should be the end of transfer
            ?DebugF("Finish tranfer chunk ~p~n", [binary_to_list(Data)]),
            {State#state_rcv{session= #http{}, ack_done = true,
                             datasize = Acc %% FIXME: is it the correct size?
                            }, []};
	<<?CR>> when Int==0, size(Data) < 3 ->  % lack ?CRLF, continue 
            { State#state_rcv{acc =  <<48, ?CR, ?LF>> }, [] };
	<<C>> when C==$ -> % Some servers (e.g., Apache 1.3.6) throw in
			   % additional whitespace...
	    read_chunk(Data, State, Int, Acc+1);
	_Other ->
            ?LOGF("Unexpected error while parsing chunk ~p~n", [_Other] ,?WARN),
			ts_mon:add({count, http_unexpected_chunkdata}),
            {State#state_rcv{session= #http{}, ack_done = true}, []}
    end.

%%----------------------------------------------------------------------
%% Func: read_chunk_data/4
%% Purpose: read 'Int' bytes of data
%% Returns: {NewState= record(state_rcv), SockOpts}
%%----------------------------------------------------------------------
read_chunk_data(Data, State=#state_rcv{acc=[]}, Int, Acc) when size(Data) > Int->
    ?DebugF("Read ~p bytes of chunk with size = ~p~n", [Int, size(Data)]),
    <<NewData:Int/binary, Rest/binary >> = Data,
    read_chunk(Rest, State,  0, Int + Acc);
read_chunk_data(Data, State=#state_rcv{acc=[]}, Int, Acc) -> % not enough data in buffer
    BodySize = size(Data),
    ?DebugF("Partial chunk received (~p/~p)~n", [BodySize,Int]),
    NewHttp = (State#state_rcv.session)#http{chunk_toread   = Int-BodySize,
											 body_size      = BodySize + Acc},
    {State#state_rcv{session  = NewHttp,
					 ack_done = false, % continue to read data
                     datasize = BodySize + Acc},[]};
read_chunk_data(Data, State=#state_rcv{acc=Acc}, _Int, AccSize) ->
    ?DebugF("Accumulated data = [~p]~n", [Acc]),
    NewData = <<Acc/binary, Data/binary>>,
    read_chunk(NewData, State#state_rcv{acc=[]}, 0, AccSize).

%%----------------------------------------------------------------------
%% Func: add_new_cookie/3
%% Purpose: Separate cookie values from attributes
%%----------------------------------------------------------------------
add_new_cookie(Cookie, Host, OldCookies) ->
    Fields = splitcookie(Cookie),
    New = parse_set_cookie(Fields, #cookie{domain=Host,path="/"}),
    concat_cookies([New],OldCookies).

%%----------------------------------------------------------------------
%% Function: splitcookie/3
%% Purpose:  split according to string ";". 
%%  Not very elegant but 5x faster than the regexp:split version
%%----------------------------------------------------------------------
splitcookie(Cookie) -> splitcookie(Cookie, [], []).
splitcookie([], Cur, Acc) -> [lists:reverse(Cur)|Acc];
splitcookie(";"++Rest,Cur,Acc) -> 
    splitcookie(string:strip(Rest, both),[],[lists:reverse(Cur)|Acc]);
splitcookie([Char|Rest],Cur,Acc)->splitcookie(Rest, [Char|Cur], Acc).

%%----------------------------------------------------------------------
%% Func: concat_cookie/2
%% Purpose: add new cookies to a list of old ones. If the keys already
%%          exists, replace with the new ones
%%----------------------------------------------------------------------
concat_cookies(New, DynData=#dyndata{proto=#http_dyndata{cookies=Cookies}}) ->
    NewCookies = concat_cookies(New,  Cookies),
    DynData#dyndata{proto=#http_dyndata{cookies=NewCookies}};
concat_cookies([],  DynData) -> DynData;
concat_cookies(New, []) -> New;
concat_cookies([New=#cookie{}|Rest], OldCookies)->
    case lists:keysearch(New#cookie.key, #cookie.key, OldCookies) of
        {value, _OldVal} ->
            ?DebugF("Reset key ~p with new value ~p~n",[New#cookie.key,
                                                        New#cookie.value]),
            NewList = lists:keyreplace(New#cookie.key, #cookie.key, OldCookies, New),
            concat_cookies(Rest, NewList);
        false ->
            concat_cookies(Rest, [New | OldCookies])
    end.

%%----------------------------------------------------------------------
%% Func: parse_set_cookie/2
%%       cf. RFC 2965 
%%----------------------------------------------------------------------
parse_set_cookie([], Cookie) -> Cookie;
parse_set_cookie([Field| Rest], Cookie=#cookie{}) ->
    {Key,Val} = get_cookie_key(Field,[]),
    ?DebugF("Parse cookie key ~p with value ~p~n",[Key, Val]),
    parse_set_cookie(Rest, set_cookie_key(Key, Val, Cookie)).

%%----------------------------------------------------------------------
set_cookie_key([L|"ersion"],Val,Cookie) when L == $V; L==$v ->
    Cookie#cookie{version=Val};
set_cookie_key([L|"omain"],Val,Cookie) when L == $D; L==$d ->
    Cookie#cookie{domain=Val};
set_cookie_key([L|"ath"],Val,Cookie) when L == $P; L==$p ->
    Cookie#cookie{path=Val};
set_cookie_key([L|"ax-Age"],Val,Cookie) when L == $M; L==$m ->
    Cookie#cookie{max_age=Val}; % NOT IMPLEMENTED
set_cookie_key([L|"xpires"],Val,Cookie) when L == $E; L==$e ->
    Cookie#cookie{expires=Val}; % NOT IMPLEMENTED
set_cookie_key([L|"ort"],Val,Cookie) when L == $P; L==$p ->
    Cookie#cookie{port=Val};
set_cookie_key([L|"iscard"],Val,Cookie) when L == $D; L==$d ->
    Cookie#cookie{discard=true}; % NOT IMPLEMENTED
set_cookie_key([L|"ecure"],Val,Cookie) when L == $S; L==$s ->
    Cookie#cookie{secure=true}; % NOT IMPLEMENTED
set_cookie_key([L|"ommenturl"],Val,Cookie) when L == $C; L==$c ->
    Cookie; % don't care about comment
set_cookie_key([L|"omment"],Val,Cookie) when L == $C; L==$c ->
    Cookie; % don't care about comment
set_cookie_key(Key,Val,Cookie) ->
    Cookie#cookie{key=Key,value=Val}.

%%----------------------------------------------------------------------
get_cookie_key([],Acc)         -> {lists:reverse(Acc), []};
get_cookie_key([$=|Rest],Acc)  -> {lists:reverse(Acc), Rest};
get_cookie_key([Char|Rest],Acc)-> get_cookie_key(Rest, [Char|Acc]).



%%--------------------------------------------------------------------
%% Func: parse_headers/3
%% Purpose: Parse HTTP headers line by line
%% Returns: {ok, #http, Body}
%%--------------------------------------------------------------------
parse_headers(H, Tail, Host) ->
    case get_line(Tail) of
	{line, Line, Tail2} ->
	    parse_headers(parse_line(Line, H, Host), Tail2, Host);
	{lastline, Line, Tail2} ->
	    {ok, parse_line(Line, H#http{partial=false}, Host), Tail2};
	{more} -> %% Partial header
	    {more, H#http{partial=true}, Tail}
    end.

%%--------------------------------------------------------------------
%% Func: parse_req/1
%% Purpose: Parse HTTP request
%% Returns: {ok, #http_request, Body} | {more, Http , Tail}
%%--------------------------------------------------------------------
parse_req(Data) ->
    parse_req([], Data).
parse_req([], Data) ->
    FunV = fun("http/"++V)->V;("HTTP/"++V)->V end,
    case get_line(Data) of
        {more} -> %% Partial header
            {more, [], Data};
        {line, Line, Tail} ->
            [Method, RequestURI, Version] = string:tokens(Line," "),
            parse_req(#http_request{method=http_method(Method), 
                                    url=RequestURI,
                                    version=FunV(Version)},Tail);
        {lastline, Line, Tail} ->
            [Method, RequestURI, Version] = string:tokens(Line," "),
            {ok, #http_request{method=http_method(Method), 
                               url=RequestURI,
                               version=FunV(Version)},Tail}
    end;
parse_req(Http=#http_request{headers=H}, Data) ->
    case get_line(Data) of
        {line, Line, Tail} ->
            NewH= [ts_utils:split2(Line,$:,strip) | H],
            parse_req(Http#http_request{headers=NewH}, Tail);
        {lastline, Line, Tail} ->
            NewH= [ts_utils:split2(Line,$:,strip) | H],
            {ok, Http#http_request{headers=NewH}, Tail};
        {more} -> %% Partial header
            {more, Http#http_request{id=partial}, Data} 
    end.

http_method("get")-> get;
http_method("post")-> post;
http_method("head")-> head;
http_method("put")-> put;
http_method("delete")-> delete;
http_method(_) -> not_implemented.
    
%%--------------------------------------------------------------------
%% Func: parse_status/2
%% Purpose: Parse HTTP status
%% Returns: #http
%%--------------------------------------------------------------------
parse_status([A,B,C|_],  Http) ->
	Status=list_to_integer([A,B,C]),
	?DebugF("HTTP Status ~p~n",[Status]),
	ts_mon:add({ count, Status }),
	Http#http{status=Status}.

%%--------------------------------------------------------------------
%% Func: parse_line/3
%% Purpose: Parse a HTTP header
%% Returns: #http
%%--------------------------------------------------------------------
parse_line("http/1.1 " ++ TailLine, Http, _Host )->
	parse_status(TailLine, Http);
parse_line("http/1.0 " ++ TailLine, Http, _Host)->
	parse_status(TailLine, Http#http{close=true});

parse_line("content-length: "++Tail, Http, _Host)->
	CL=list_to_integer(Tail),
	?DebugF("HTTP Content-Length ~p~n",[CL]),
	Http#http{content_length=CL};
parse_line("connection: close"++Tail, Http, _Host)->
	?Debug("Connection Closed in Header ~n"),
	Http#http{close=true};
parse_line("transfer-encoding: chunked"++Tail, Http, _Host)->
	?LOG("Chunked transfer encoding~n",?DEB),
	Http#http{chunk_toread=0};
parse_line("transfer-encoding: Chunked"++Tail, Http, _Host)->
	?LOG("Chunked transfer encoding~n",?DEB),
	Http#http{chunk_toread=0};
parse_line("transfer-encoding:"++Tail, Http, _Host)->
	?LOGF("Unknown tranfer encoding ~p~n",[Tail],?NOTICE),
	Http;
parse_line("set-cookie: "++Tail, Http=#http{cookie=PrevCookies}, Host)->
	Cookie = add_new_cookie(Tail, Host, PrevCookies),
	?DebugF("HTTP New cookie val ~p~n",[Cookie]),
	Http#http{cookie=Cookie};
parse_line(Line, Http, _Host) ->
	?DebugF("Skip header ~p (Http record is ~p)~n", [Line, Http]),
	Http.

%% code taken from yaws
is_nb_space(X) ->
    lists:member(X, [$\s, $\t]).
% ret: {line, Line, Trail} | {lastline, Line, Trail}
get_line(L) ->
    get_line(L, true, []).
get_line("\r\n\r\n" ++ Tail, _Cap, Cur) ->
    {lastline, lists:reverse(Cur), Tail};
get_line("\r\n", _, _) ->
    {more};
get_line("\r\n" ++ Tail, Cap, Cur) ->
    case is_nb_space(hd(Tail)) of
        true ->  %% multiline ... continue 
            get_line(Tail, Cap,[$\n, $\r | Cur]);
        false ->
            {line, lists:reverse(Cur), Tail}
    end;
get_line([$:|T], true, Cur) -> % ':' separator
    get_line(T, false, [$:|Cur]);%the rest of the header isn't set to lower char
get_line([H|T], false, Cur) ->
    get_line(T, false, [H|Cur]);
get_line([Char|T], true, Cur) when Char >= $A, Char =< $Z ->
    get_line(T, true, [Char + 32|Cur]);
get_line([H|T], true, Cur) ->
    get_line(T, true, [H|Cur]);
get_line([], _, _) -> %% Headers are fragmented ... We need more data
    {more}.
