%%%-------------------------------------------------------------------
%%% File    : ts_test_recorder.erl
%%% Author  : Nicolas Niclausse <nicolas@niclux.org>
%%% Description : 
%%%
%%% Created : 20 Mar 2005 by Nicolas Niclausse <nicolas@niclux.org>
%%%-------------------------------------------------------------------
-module(ts_test_file_server).

-compile(export_all).

-include("ts_profile.hrl").
-include("ts_config.hrl").
-include_lib("eunit/include/eunit.hrl").

test()-> 
    ok.

config_file_server1_test()->
    myset_env(),
    ts_file_server:start(),
    ts_file_server:read([{default,"./src/test/test_file_server.csv"}, 
                         {user,"./src/test/test_file_server2.csv"} ]),
    ?assertMatch({ok,"username1;glop;"}, ts_file_server:get_next_line()).

config_file_server2_test()->
    myset_env(),
    ?assertMatch({ok,"username2;;"}, ts_file_server:get_next_line()).


config_file_server3_test()->
    myset_env(),
    ?assertMatch({ok,"user1"}, ts_file_server:get_next_line(user)).

config_file_server4_test()->
    myset_env(),
    ?assertMatch({ok,"username3;glop4;"}, ts_file_server:get_next_line()).



config_file_server_cycle_test()->
    myset_env(),
    ts_file_server:stop(),
    ts_file_server:start(),
    ts_file_server:read([{default,"./src/test/test_file_server.csv"}]),
    ts_file_server:get_next_line(),
    ts_file_server:get_next_line(),
    ts_file_server:get_next_line(),
    ?assertMatch({ok,"username1;glop;"}, ts_file_server:get_next_line()).

config_file_server_all_test()->
    myset_env(),
    ?assertMatch({ok,["username1;glop;","username2;;","username3;glop4;"]}, ts_file_server:get_all_lines()).
    

myset_env()->
    application:set_env(stdlib,file_server_timeout,30000),
    application:set_env(stdlib,debug_level,0),
    application:set_env(stdlib,thinktime_override,"false"),
    application:set_env(stdlib,thinktime_random,"false").
