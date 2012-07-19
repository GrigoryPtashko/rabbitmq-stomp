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
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2012 VMware, Inc.  All rights reserved.
%%

-module(rabbit_stomp_test_frame).

-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_stomp_frame.hrl").
-include("rabbit_stomp_headers.hrl").

parse_simple_frame_test() ->
    parse_simple_frame_gen("\n").
    
parse_simple_frame_crlf_test() ->
    parse_simple_frame_gen("\r\n").
    
parse_simple_frame_gen(Term) ->
    Headers = [{"header1", "value1"}, {"header2", "value2"}],
    Content = frame_string("COMMAND",
                           Headers,
                           "Body Content",
                           Term),
    {"COMMAND", Frame, _State} = parse_complete(Content),
    [?assertEqual({ok, Value},
                  rabbit_stomp_frame:header(Frame, Key)) ||
        {Key, Value} <- Headers],
    #stomp_frame{body_iolist = Body} = Frame,
    ?assertEqual(<<"Body Content">>, iolist_to_binary(Body)).

parse_simple_frame_with_null_test() ->
    Headers = [{"header1", "value1"}, {"header2", "value2"},
               {?HEADER_CONTENT_LENGTH, "12"}],
    Content = frame_string("COMMAND",
                           Headers,
                           "Body\0Content"),
    {"COMMAND", Frame, _State} = parse_complete(Content),
    [?assertEqual({ok, Value},
                  rabbit_stomp_frame:header(Frame, Key)) ||
        {Key, Value} <- Headers],
    #stomp_frame{body_iolist = Body} = Frame,
    ?assertEqual(<<"Body\0Content">>, iolist_to_binary(Body)).

parse_large_content_frame_with_nulls_test() ->
    BodyContent = string:copies("012345678\0", 1024),
    Headers = [{"header1", "value1"}, {"header2", "value2"},
               {?HEADER_CONTENT_LENGTH, integer_to_list(string:len(BodyContent))}],
    Content = frame_string("COMMAND",
                           Headers,
                           BodyContent),
    {"COMMAND", Frame, _State} = parse_complete(Content),
    [?assertEqual({ok, Value},
                  rabbit_stomp_frame:header(Frame, Key)) ||
        {Key, Value} <- Headers],
    #stomp_frame{body_iolist = Body} = Frame,
    ?assertEqual(list_to_binary(BodyContent), iolist_to_binary(Body)).

parse_command_only_test() ->
    {ok, #stomp_frame{command = "COMMAND"}, _Rest} = parse("COMMAND\n\n\0").

parse_ignore_empty_frames_test() ->
    {ok, #stomp_frame{command = "COMMAND"}, _Rest} = parse("\0\0COMMAND\n\n\0").

parse_heartbeat_interframe_test() ->
    {ok, #stomp_frame{command = "COMMAND"}, _Rest} = parse("\nCOMMAND\n\n\0").

parse_crlf_interframe_test() ->
    {ok, #stomp_frame{command = "COMMAND"}, _Rest} = parse("\r\nCOMMAND\n\n\0").

parse_carriage_return_not_ignored_interframe_test() ->
    {ok, #stomp_frame{command = "\rCOMMAND"}, _Rest} = parse("\rCOMMAND\n\n\0").

parse_carriage_return_mid_command_test() ->
    {ok, #stomp_frame{command = "COMM\rAND"}, _Rest} = parse("COMM\rAND\n\n\0").

parse_carriage_return_end_command_test() -> % eol must be \r\n after \r
    {ok, #stomp_frame{command = "COMMAND\r"}, _Rest} = parse("COMMAND\r\r\n\n\0").

parse_resume_mid_command_test() ->
    First = "COMM",
    Second = "AND\n\n\0",
    {more, Resume} = parse(First),
    {ok, #stomp_frame{command = "COMMAND"}, _Rest} = parse(Second, Resume).

parse_resume_mid_header_key_test() ->
    First = "COMMAND\nheade",
    Second = "r1:value1\n\n\0",
    {more, Resume} = parse(First),
    {ok, Frame = #stomp_frame{command = "COMMAND"}, _Rest} =
        parse(Second, Resume),
    ?assertEqual({ok, "value1"},
                 rabbit_stomp_frame:header(Frame, "header1")).

parse_resume_mid_header_val_test() ->
    First = "COMMAND\nheader1:val",
    Second = "ue1\n\n\0",
    {more, Resume} = parse(First),
    {ok, Frame = #stomp_frame{command = "COMMAND"}, _Rest} =
        parse(Second, Resume),
    ?assertEqual({ok, "value1"},
                 rabbit_stomp_frame:header(Frame, "header1")).

parse_resume_mid_body_test() ->
    First = "COMMAND\n\nABC",
    Second = "DEF\0",
    {more, Resume} = parse(First),
    {ok, #stomp_frame{command = "COMMAND", body_iolist = Body}, _Rest} =
         parse(Second, Resume),
    ?assertEqual([<<"ABC">>, <<"DEF">>], Body).

parse_no_header_stripping_test() ->
    Content = "COMMAND\nheader: foo \n\n\0",
    {ok, Frame, _} = parse(Content),
    {ok, Val} = rabbit_stomp_frame:header(Frame, "header"),
    ?assertEqual(" foo ", Val).

parse_multiple_headers_test() ->
    Content = "COMMAND\nheader:correct\nheader:incorrect\n\n\0",
    {ok, Frame, _} = parse(Content),
    {ok, Val} = rabbit_stomp_frame:header(Frame, "header"),
    ?assertEqual("correct", Val).

header_ending_with_cr_test() ->
    Content = "COMMAND\nheader:val\r\r\n\n\0",
    {ok, Frame, _} = parse(Content),
    {ok, Val} = rabbit_stomp_frame:header(Frame, "header"),
    ?assertEqual("val\r", Val),
    Serialized = lists:flatten(rabbit_stomp_frame:serialize(Frame)),
    ?assertEqual(Content, rabbit_misc:format("~s", [Serialized])).

headers_escaping_roundtrip_test() ->
    Content = "COMMAND\nhead\\c\\ner:\\c\\n\\\\\n\n\0",
    {ok, Frame, _} = parse(Content),
    {ok, Val} = rabbit_stomp_frame:header(Frame, "head:\ner"),
    ?assertEqual(":\n\\", Val),
    Serialized = lists:flatten(rabbit_stomp_frame:serialize(Frame)),
    ?assertEqual(Content, rabbit_misc:format("~s", [Serialized])).

parse(Content) ->
    parse(Content, rabbit_stomp_frame:initial_state()).
parse(Content, State) ->
    rabbit_stomp_frame:parse(list_to_binary(Content), State).

parse_complete(Content) ->
    {ok, Frame = #stomp_frame{command = Command}, State} = parse(Content),
    {Command, Frame, State}.

frame_string(Command, Headers, BodyContent) ->
    frame_string(Command, Headers, BodyContent, "\n").

frame_string(Command, Headers, BodyContent, Term) ->
    HeaderString =
        lists:flatten([Key ++ ":" ++ Value ++ Term || {Key, Value} <- Headers]),
    Command ++ Term ++ HeaderString ++ Term ++ BodyContent ++ "\0".

