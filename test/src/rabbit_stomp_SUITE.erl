%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_stomp_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).
-import(rabbit_misc, [pget/2]).
-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_stomp_frame.hrl").
-define(DESTINATION, "/queue/bulk-test").

all() ->
    [
     test_messages_not_dropped_on_disconnect,
     test_direct_client_connections_are_not_leaked
    ].

-define(GARBAGE, <<"bdaf63dda9d78b075c748b740e7c3510ad203b07\nbdaf63dd">>).

count_connections() ->
    %% The default port is 61613 but it's in the middle of the ephemeral
    %% ports range on many operating systems. Therefore, there is a
    %% chance this port is already in use. Let's use a port close to the
    %% AMQP default port.
    IPv4Count = try
        %% Count IPv4 connections. On some platforms, the IPv6 listener
        %% implicitely listens to IPv4 connections too so the IPv4
        %% listener doesn't exist. Thus this try/catch. This is the case
        %% with Linux where net.ipv6.bindv6only is disabled (default in
        %% most cases).
        ranch_server:count_connections({acceptor, {0,0,0,0}, 5673})
    catch
        _:badarg -> 0
    end,
    IPv6Count = try
        %% Count IPv6 connections. We also use a try/catch block in case
        %% the host is not configured for IPv6.
        ranch_server:count_connections({acceptor, {0,0,0,0,0,0,0,0}, 5673})
    catch
        _:badarg -> 0
    end,
    IPv4Count + IPv6Count.

test_direct_client_connections_are_not_leaked() ->
    N = count_connections(),
    lists:foreach(fun (_) ->
                          {ok, Client = {Socket, _}} = rabbit_stomp_client:connect(),
                          %% send garbage which trips up the parser
                          gen_tcp:send(Socket, ?GARBAGE),
                          rabbit_stomp_client:send(
                           Client, "LOL", [{"", ""}])
                  end,
                  lists:seq(1, 100)),
    timer:sleep(5000),
    N = count_connections(),
    ok.

test_messages_not_dropped_on_disconnect() ->
    N = count_connections(),
    {ok, Client} = rabbit_stomp_client:connect(),
    N1 = N + 1,
    N1 = count_connections(),
    [rabbit_stomp_client:send(
       Client, "SEND", [{"destination", ?DESTINATION}],
       [integer_to_list(Count)]) || Count <- lists:seq(1, 1000)],
    rabbit_stomp_client:disconnect(Client),
    QName = rabbit_misc:r(<<"/">>, queue, <<"bulk-test">>),
    timer:sleep(3000),
    N = count_connections(),
    rabbit_amqqueue:with(
      QName, fun(Q) ->
                     1000 = pget(messages, rabbit_amqqueue:info(Q, [messages]))
             end),
    ok.
