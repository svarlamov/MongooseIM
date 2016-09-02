-module(rest_client_SUITE).
-compile(export_all).

all() ->
    [{group, all}].

groups() ->
    [{all, [parallel], test_cases()}].

test_cases() ->
    [msg_is_sent_and_delivered,
     all_messages_are_archived,
     messages_with_user_are_archived,
     messages_can_be_paginated,
     room_is_created,
     user_is_invited_to_a_room,
     msg_is_sent_and_delivered_in_room,
     messages_are_archived_in_room,
     messages_can_be_paginated_in_room
     ].

init_per_suite(C) ->
    Host = ct:get_config({hosts, mim, domain}),
    MUCLightHost = <<"muclight.", Host/binary>>,
    C1 = rest_helper:maybe_enable_mam(mam_helper:backend(), Host, C),
    dynamic_modules:start(Host, mod_muc_light,
                          [{host, binary_to_list(MUCLightHost)},
                           {rooms_in_rosters, true}]),
    escalus:init_per_suite(C1).

end_per_suite(Config) ->
    escalus_fresh:clean(),
    Host = ct:get_config({hosts, mim, domain}),
    rest_helper:maybe_disable_mam(proplists:get_value(mam_enabled, Config), Host),
    dynamic_modules:stop(Host, mod_muc_light),
    escalus:end_per_suite(Config).

init_per_group(_GN, C) ->
    C.

end_per_group(_GN, C) ->
    C.

init_per_testcase(TC, Config) ->
    MAMTestCases = [all_messages_are_archived,
                    messages_with_user_are_archived,
                    messages_can_be_paginated,
                    messages_are_archived_in_room
                   ],
    rest_helper:maybe_skip_mam_test_cases(TC, MAMTestCases, Config).

end_per_testcase(TC, C) ->
    escalus:end_per_testcase(TC, C).

msg_is_sent_and_delivered(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}], fun(Alice, Bob) ->
        M = send_message(alice, Alice, Bob),
        Msg = escalus:wait_for_stanza(Bob),
        escalus:assert(is_chat_message, [maps:get(body, M)], Msg)
    end).

all_messages_are_archived(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}, {kate, 1}], fun(Alice, Bob, Kate) ->
        Sent = [M1 | _] = send_messages(Config, Alice, Bob, Kate),
        AliceJID = maps:get(to, M1),
        AliceCreds = {AliceJID, user_password(alice)},
        GetPath = lists:flatten("/messages/"),
        {{<<"200">>, <<"OK">>}, Msgs} = rest_helper:gett(GetPath, AliceCreds),
        Received = [_Msg1, _Msg2, _Msg3] = rest_helper:decode_maplist(Msgs),
        assert_messages(Sent, Received)

    end).

messages_with_user_are_archived(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}, {kate, 1}], fun(Alice, Bob, Kate) ->
        [M1, _M2, M3] = send_messages(Config, Alice, Bob, Kate),
        AliceJID = maps:get(to, M1),
        KateJID = escalus_utils:jid_to_lower(escalus_client:short_jid(Kate)),
        AliceCreds = {AliceJID, user_password(alice)},
        GetPath = lists:flatten(["/messages/", binary_to_list(KateJID)]),
        {{<<"200">>, <<"OK">>}, Msgs} = rest_helper:gett(GetPath, AliceCreds),
        Recv = [_Msg2] = rest_helper:decode_maplist(Msgs),
        assert_messages([M3], Recv)

    end).

messages_can_be_paginated(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}], fun(Alice, Bob) ->
        AliceJID = escalus_utils:jid_to_lower(escalus_client:short_jid(Alice)),
        BobJID = escalus_utils:jid_to_lower(escalus_client:short_jid(Bob)),
        rest_helper:fill_archive(Alice, Bob),
        mam_helper:maybe_wait_for_yz(Config),
        AliceCreds = {AliceJID, user_password(alice)},
        % recent msgs with a limit
        M1 = get_messages(AliceCreds, BobJID, 10),
        6 = length(M1),
        M2 = get_messages(AliceCreds, BobJID, 3),
        3 = length(M2),
        % older messages - earlier then the previous midnight
        PriorTo = rest_helper:make_timestamp(-1, {0, 0, 1}),
        M3 = get_messages(AliceCreds, BobJID, PriorTo, 10),
        4 = length(M3),
        [Oldest|_] = M3,
        <<"A">> = maps:get(body, Oldest),
        % same with limit
        M4 = get_messages(AliceCreds, BobJID, PriorTo, 2),
        2 = length(M4),
        [Oldest2|_] = M4,
        <<"B">> = maps:get(body, Oldest2)
    end).

room_is_created(Config) ->
    escalus:fresh_story(Config, [{alice, 1}], fun(Alice) ->
        RoomID = given_new_room({alice, Alice}),
        get_room_info({alice, Alice}, RoomID)
    end).

user_is_invited_to_a_room(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}], fun(Alice, Bob) ->
        RoomID = given_new_room_with_users({alice, Alice}, [{bob, Bob}]),
        get_room_info({alice, Alice}, RoomID)
    end).

msg_is_sent_and_delivered_in_room(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}], fun(Alice, Bob) ->
        given_new_room_with_users_and_msgs({alice, Alice}, [{bob, Bob}])
    end).

messages_are_archived_in_room(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}], fun(Alice, Bob) ->
        {RoomID, Msgs} = given_new_room_with_users_and_msgs({alice, Alice}, [{bob, Bob}]),
        mam_helper:maybe_wait_for_yz(Config),
        ct:pal("~p", [Msgs]),
        Path = <<"/rooms/", RoomID/binary, "/messages">>,
        Creds = credentials({alice, Alice}),
        {{<<"200">>, <<"OK">>}, Result} = rest_helper:gett(Path, Creds),
        [Aff, _Msg1, _Msg2] = MsgsRecv = rest_helper:decode_maplist(Result),
        %% The oldest message is aff change
        <<"affiliation">> = maps:get(type, Aff),
        <<"member">> = maps:get(affiliation, Aff),
        BobJID = escalus_utils:jid_to_lower(escalus_client:short_jid(Bob)),
        BobJID = maps:get(user, Aff),
        ct:pal("~p", [MsgsRecv])
    end).

messages_can_be_paginated_in_room(Config) ->
    escalus:fresh_story(Config, [{alice, 1}, {bob, 1}], fun(Alice, Bob) ->
        RoomID = given_new_room_with_users({alice, Alice}, [{bob, Bob}]),
        [GenMsgs1, GenMsgs2 | _] = Msgs = rest_helper:fill_room_archive(RoomID, [Alice, Bob]),
        mam_helper:maybe_wait_for_yz(Config),
        ct:print("~p", [Msgs]),
        Msgs10 = get_room_messages({alice, Alice}, RoomID, 10),
        Msgs10Len = length(Msgs10),
        true = Msgs10Len > 0 andalso Msgs10Len =< 10,
        Msgs3 = get_room_messages({alice, Alice}, RoomID, 3),
        [_, _, _] = Msgs3,
        {_, Time} = calendar:now_to_datetime(os:timestamp()),
        PriorTo = rest_helper:make_timestamp(-1, Time),
        [OldestMsg1 | _] = get_room_messages({alice, Alice}, RoomID, 4, PriorTo),
        assert_room_messages(OldestMsg1, hd(lists:keysort(1, GenMsgs1))),
        [OldestMsg2 | _] = get_room_messages({alice, Alice}, RoomID, 2, PriorTo),
        assert_room_messages(OldestMsg2, hd(lists:keysort(1, GenMsgs2)))
    end).

assert_room_messages(RecvMsg, {_ID, _GenFrom, GenMsg}) ->
    ct:print("~p", [RecvMsg]),
    ct:print("~p", [GenMsg]),
    escalus:assert(is_chat_message, [maps:get(body, RecvMsg)], GenMsg),
    ok.

get_room_info(User, RoomID) ->
    Creds = credentials(User),
    {{<<"200">>, <<"OK">>}, {Result}} = rest_helper:gett(<<"/rooms/", RoomID/binary>>,
                                                         Creds),
    ct:pal("~p", [Result]),
    Result.

given_new_room_with_users_and_msgs(Owner, Users) ->
    RoomID = given_new_room_with_users(Owner, Users),
    Msgs = [given_message_sent_to_room(RoomID, Sender) || Sender <- [Owner | Users]],
    wait_for_room_msgs(Msgs, [Owner | Users]),
    {RoomID, Msgs}.

wait_for_room_msgs([], _) ->
    ok;
wait_for_room_msgs([Msg | Rest], Users) ->
    [wait_for_room_msg(Msg, User) || {_, User} <- Users],
    wait_for_room_msgs(Rest, Users).

wait_for_room_msg(Msg, User) ->
    Stanza = escalus:wait_for_stanza(User),
    escalus:assert(is_groupchat_message, [maps:get(body, Msg)], Stanza).

given_message_sent_to_room(RoomID, Sender) ->
    Creds = credentials(Sender),
    Path = <<"/rooms/", RoomID/binary, "/messages">>,
    Body = #{body => <<"Hi all!">>},
    {{<<"200">>, <<"OK">>}, {Result}} = rest_helper:post(Path, Body, Creds),
    MsgId = proplists:get_value(<<"id">>, Result),
    true = is_binary(MsgId),
    Body#{id => MsgId}.

given_new_room_with_users(Owner, Users) ->
    RoomID = given_new_room(Owner),
    [given_user_invited(Owner, RoomID, User) || {_, User} <- Users],
    RoomID.

given_new_room(Owner) ->
    Creds = credentials(Owner),
    RoomName = <<"new_room_name">>,
    create_room(Creds, RoomName, <<"This room subject">>).

given_user_invited({_, Inviter} = Owner, RoomID, Invitee) ->
    Creds = credentials(Owner),
    JID = escalus_utils:jid_to_lower(escalus_client:short_jid(Invitee)),
    Body = #{user => JID},
    {{<<"204">>, <<"No Content">>}, _} = rest_helper:putt(<<"/rooms/", RoomID/binary>>,
                                                          Body, Creds),
    Stanza = escalus:wait_for_stanza(Invitee),
    ct:pal("Invitee ~p", [Stanza]),
    Stanza2 = escalus:wait_for_stanza(Inviter),
    ct:pal("Inviter ~p", [Stanza2]).


credentials({User, UserClient}) ->
    JID = escalus_utils:jid_to_lower(escalus_client:short_jid(UserClient)),
    {JID, user_password(User)}.


user_password(User) ->
    [{User, Props}] = escalus:get_users([User]),
    proplists:get_value(password, Props).

send_message(User, From, To) ->
    AliceJID = escalus_utils:jid_to_lower(escalus_client:short_jid(From)),
    BobJID = escalus_utils:jid_to_lower(escalus_client:short_jid(To)),
    M = #{to => BobJID, body => <<"hello, ", BobJID/binary," it's me">>},
    Cred = {AliceJID, user_password(User)},
    {{<<"200">>, <<"OK">>}, {Result}} = rest_helper:post(<<"/messages">>, M, Cred),
    ID = proplists:get_value(<<"id">>, Result),
    M#{id => ID, from => AliceJID}.

get_messages(MeCreds, Other, Count) ->
    GetPath = lists:flatten(["/messages/",
                             binary_to_list(Other),
                             "?limit=", integer_to_list(Count)]),
    get_messages(GetPath, MeCreds).

get_messages(Path, Creds) ->
    {{<<"200">>, <<"OK">>}, Msgs} = rest_helper:gett(Path, Creds),
    rest_helper:decode_maplist(Msgs).

get_messages(MeCreds, Other, Before, Count) ->
    GetPath = lists:flatten(["/messages/",
                             binary_to_list(Other),
                             "?before=", integer_to_list(Before),
                             "&limit=", integer_to_list(Count)]),
    get_messages(GetPath, MeCreds).


get_room_messages(Client, RoomID, Count) ->
    get_room_messages(Client, RoomID, Count, undefined).

get_room_messages(Client, RoomID, Count, Before) ->
    Creds = credentials(Client),
    BasePathList = ["/rooms/", RoomID, "/messages?limit=", integer_to_binary(Count)],
    PathList = BasePathList ++ [["&before=",integer_to_binary(Before)] || Before /= undefined],
    Path = erlang:iolist_to_binary(PathList),
    get_messages(Path, Creds).

create_room({_AliceJID, _} = Creds, RoomID, Subject) ->
    Room = #{name => RoomID,
             subject => Subject},
    {{<<"200">>, <<"OK">>}, {Result}} = rest_helper:post(<<"/rooms">>, Room, Creds),
    proplists:get_value(<<"id">>, Result).

assert_messages([], []) ->
    ok;
assert_messages([SentMsg | SentRest], [RecvMsg | RecvRest]) ->
    ct:pal("sent msg: ~p~nrecv msg: ~p", [SentMsg, RecvMsg]),
    FromJID = maps:get(from, SentMsg),
    FromJID = maps:get(from, RecvMsg),
    MsgId = maps:get(id, SentMsg),
    MsgId = maps:get(id, RecvMsg), %checks if there is an ID
    _ = maps:get(timestamp, RecvMsg), %checks if there ia timestamp
    MsgBody = maps:get(body, SentMsg),
    MsgBody = maps:get(body, RecvMsg),
    assert_messages(SentRest, RecvRest);
assert_messages(_Sent, _Recv) ->
    ct:fail("Send and Recv messages are not equal").

send_messages(Config, Alice, Bob, Kate) ->
    M1 = send_message(bob, Bob, Alice),
    M2 = send_message(alice, Alice, Bob),
    M3 = send_message(kate, Kate, Alice),
    mam_helper:maybe_wait_for_yz(Config),
    [M1, M2, M3].

