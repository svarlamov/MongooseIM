%%%----------------------------------------------------------------------
%%% File    : mod_muc.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : MUC support (XEP-0045)
%%% Created : 19 Mar 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_muc).
-author('alexey@process-one.net').
-xep([{xep, 45}, {version, "1.25"}]).
-behaviour(gen_server).
-behaviour(gen_mod).

%% API
-export([start_link/2,
         start/2,
         stop/1,
         room_destroyed/4,
         store_room/3,
         restore_room/2,
         forget_room/2,
         create_instant_room/5,
         process_iq_disco_items/4,
         broadcast_service_message/2,
         can_use_nick/3,
         room_jid_to_pid/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Internal exports
-export([route/2]).

%% Hooks handlers
-export([is_room_owner/3,
         muc_room_pid/2,
         can_access_room/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").


-export_type([access/0,
             room/0,
             nick/0,
             packet/0,
             role/0,
             affiliation/0
            ]).

-type role() :: moderator | participant | visitor | none.
-type affiliation() :: admin | owner | member | outcast | none.
-type room() :: binary().
-type nick() :: binary().
-type room_host() :: ejabberd:simple_bare_jid().
-type packet() :: jlib:xmlel().
-type from_to_packet() ::
        {From :: ejabberd:jid(), To :: ejabberd:jid(), Packet :: packet()}.
-type access() :: {_AccessRoute, _AccessCreate, _AccessAdmin, _AccessPersistent}.

-record(muc_room, {
          name_host,
          opts
         }).

-type muc_room() :: #muc_room{
                       name_host    :: room_host(),
                       opts         :: list()
                      }.

-record(muc_online_room, {name_host,
                          pid
                         }).

-type muc_online_room() :: #muc_online_room{
                              name_host :: room_host(),
                              pid       :: pid()
                             }.

-record(muc_registered, {
          us_host,
          nick
         }).

-type muc_registered() :: #muc_registered{
                             us_host    :: ejabberd:literal_jid(),
                             nick       :: nick()
                            }.

-record(state, {host                :: ejabberd:server(),
                server_host         :: ejabberd:literal_jid(),
                access,
                history_size        :: integer(),
                default_room_opts   :: list(),
                room_shaper         :: shaper:shaper(),
                http_auth_pool      :: mongoose_http_client:pool()
              }).

-type state() :: #state{}.

-export_type([muc_room/0, muc_registered/0]).

-define(PROCNAME, ejabberd_mod_muc).


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
-spec start_link(ejabberd:server(), list())
            -> 'ignore' | {'error',_} | {'ok',pid()}.
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).


-spec start(ejabberd:server(),_) -> {'error',_}
            | {'ok','undefined' | pid()} | {'ok','undefined' | pid(),_}.
start(Host, Opts) ->
    start_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec =
        {Proc,
         {?MODULE, start_link, [Host, Opts]},
         temporary,
         1000,
         worker,
         [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).


-spec stop(ejabberd:server()) -> 'ok'
    | {'error','not_found' | 'restarting' | 'running' | 'simple_one_for_one'}.
stop(Host) ->
    stop_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:delete_child(ejabberd_sup, Proc).


%% @doc This function is called by a room in three situations:
%% A) The owner of the room destroyed it
%% B) The only participant of a temporary room leaves it
%% C) mod_muc:stop was called, and each room is being terminated
%%    In this case, the mod_muc process died before the room processes
%%    So the message sending must be catched
-spec room_destroyed(ejabberd:server(), room(), pid(),
                     ejabberd:server()) -> 'ok'.
room_destroyed(Host, Room, Pid, ServerHost) ->
    catch gen_mod:get_module_proc(ServerHost, ?PROCNAME) !
        {room_destroyed, {Room, Host}, Pid},
    ok.


%% @doc Create a room.
%% If Opts = default, the default room options are used.
%% Else use the passed options as defined in mod_muc_room.
-spec create_instant_room(ejabberd:server(), Name :: room(),
    From :: ejabberd:jid(), Nick :: nick(), Opts :: list()) -> any().
create_instant_room(Host, Name, From, Nick, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, {create_instant, Name, From, Nick, Opts}).


-spec store_room(ejabberd:server(), room(), list())
            -> {'aborted',_} | {'atomic',_}.
store_room(Host, Name, Opts) ->
    F = fun() ->
                mnesia:write(#muc_room{name_host = {Name, Host},
                                       opts = Opts})
        end,
    mnesia:transaction(F).


-spec restore_room(ejabberd:server(), room())
                                    -> 'error' | 'undefined' | [any()].
restore_room(Host, Name) ->
    case catch mnesia:dirty_read(muc_room, {Name, Host}) of
        [#muc_room{opts = Opts}] ->
            Opts;
        _ ->
            error
    end.


-spec forget_room(ejabberd:server(), room()) -> 'ok'.
forget_room(Host, Name) ->
    F = fun() ->
                mnesia:delete({muc_room, {Name, Host}})
        end,
    mnesia:transaction(F),
    ejabberd_hooks:run(forget_room, Host, [Host, Name]),
    ok.


-spec process_iq_disco_items(Host :: ejabberd:server(), From :: ejabberd:jid(),
        To :: ejabberd:jid(), ejabberd:iq()) -> ok | {error, lager_not_started}.
process_iq_disco_items(Host, From, To, #iq{lang = Lang} = IQ) ->
    Rsm = jlib:rsm_decode(IQ),
    Res = IQ#iq{type = result,
                sub_el = [#xmlel{name = <<"query">>,
                                 attrs = [{<<"xmlns">>, ?NS_DISCO_ITEMS}],
                                 children = iq_disco_items(Host, From, Lang, Rsm)}]},
    ejabberd_router:route(To,
                          From,
                          jlib:iq_to_xml(Res)).


-spec can_use_nick(ejabberd:server(), ejabberd:jid(), nick()) -> boolean().
can_use_nick(_Host, _JID, <<>>) ->
    false;
can_use_nick(Host, JID, Nick) ->
    {LUser, LServer, _} = jid:to_lower(JID),
    LUS = {LUser, LServer},
    case catch mnesia:dirty_select(
                 muc_registered,
                 [{#muc_registered{us_host = '$1',
                                   nick = Nick,
                                   _ = '_'},
                   [{'==', {element, 2, '$1'}, Host}],
                   ['$_']}]) of
        {'EXIT', _Reason} ->
            true;
        [] ->
            true;
        [#muc_registered{us_host = {U, _Host}}] ->
            U == LUS
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
-spec init([ejabberd:server() | list(),...]) -> {'ok',state()}.
init([Host, Opts]) ->
    mnesia:create_table(muc_room,
                        [{disc_copies, [node()]},
                         {attributes, record_info(fields, muc_room)}]),
    mnesia:create_table(muc_registered,
                        [{disc_copies, [node()]},
                         {attributes, record_info(fields, muc_registered)}]),
    mnesia:create_table(muc_online_room,
                        [{ram_copies, [node()]},
                         {attributes, record_info(fields, muc_online_room)}]),
    mnesia:add_table_copy(muc_online_room, node(), ram_copies),
    mnesia:add_table_copy(muc_room, node(), disc_copies),
    mnesia:add_table_copy(muc_registered, node(), disc_copies),
    catch ets:new(muc_online_users, [bag, named_table, public, {keypos, 2}]),
    MyHost = gen_mod:get_opt_host(Host, Opts, <<"conference.@HOST@">>),
    update_tables(MyHost),
    clean_table_from_bad_node(node(), MyHost),
    mnesia:add_table_index(muc_registered, nick),
    mnesia:subscribe(system),
    Access = gen_mod:get_opt(access, Opts, all),
    AccessCreate = gen_mod:get_opt(access_create, Opts, all),
    AccessAdmin = gen_mod:get_opt(access_admin, Opts, none),
    AccessPersistent = gen_mod:get_opt(access_persistent, Opts, all),
    HttpAuthPool = case gen_mod:get_opt(http_auth_pool, Opts, none) of
                       none -> none;
                       PoolName -> mongoose_http_client:get_pool(PoolName)
                   end,
    HistorySize = gen_mod:get_opt(history_size, Opts, 20),
    DefRoomOpts = gen_mod:get_opt(default_room_options, Opts, []),
    RoomShaper = gen_mod:get_opt(room_shaper, Opts, none),

    State = #state{host = MyHost,
                   server_host = Host,
                   access = {Access, AccessCreate, AccessAdmin, AccessPersistent},
                   default_room_opts = DefRoomOpts,
                   history_size = HistorySize,
                   room_shaper = RoomShaper,
                   http_auth_pool = HttpAuthPool},

    ejabberd_hooks:add(is_muc_room_owner, MyHost, ?MODULE, is_room_owner, 50),
    ejabberd_hooks:add(muc_room_pid, MyHost, ?MODULE, muc_room_pid, 50),
    ejabberd_hooks:add(can_access_room, MyHost, ?MODULE, can_access_room, 50),

    F = fun(From, To, Packet) ->
            mod_muc:route({From, To, Packet}, State)
        end,
    ejabberd_router:register_route(MyHost, {apply_fun, F}),

    load_permanent_rooms(MyHost, Host,
                         {Access, AccessCreate, AccessAdmin, AccessPersistent},
                         HistorySize, RoomShaper, HttpAuthPool),
    {ok, State}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
    ejabberd_hooks:delete(is_muc_room_owner, State#state.host, ?MODULE, is_room_owner, 50),
    ejabberd_hooks:delete(muc_room_pid, State#state.host, ?MODULE, muc_room_pid, 50),
    ejabberd_hooks:delete(can_access_room, State#state.host, ?MODULE, can_access_room, 50),

    {stop, normal, ok, State};

handle_call({create_instant, Room, From, Nick, Opts},
            _From,
            #state{host = Host,
                   server_host = ServerHost,
                   access = Access,
                   default_room_opts = DefOpts,
                   history_size = HistorySize,
                   room_shaper = RoomShaper,
                   http_auth_pool = HttpAuthPool} = State) ->
    ?DEBUG("MUC: create new room '~s'~n", [Room]),
    NewOpts = case Opts of
                  default -> DefOpts;
                  _ -> Opts
              end,
    {ok, Pid} = mod_muc_room:start(
                  Host, ServerHost, Access,
                  Room, HistorySize,
                  RoomShaper, HttpAuthPool, From,
          Nick, [{instant, true}|NewOpts]),
    register_room(Host, Room, Pid),
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({route, From, To, Packet}, State) ->
    case catch route({From, To, Packet}, State) of
        {'EXIT', Reason} ->
            ?ERROR_MSG("~p", [Reason]);
        _ ->
            ok
    end,
    {noreply, State};
handle_info({room_destroyed, RoomHost, Pid}, State) ->
    F = fun() ->
                mnesia:delete_object(#muc_online_room{name_host = RoomHost,
                                                      pid = Pid})
        end,
    mnesia:transaction(F),
    {noreply, State};
handle_info({mnesia_system_event, {mnesia_down, Node}}, State) ->
    clean_table_from_bad_node(Node),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    ejabberd_router:unregister_route(State#state.host),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
-spec start_supervisor(ejabberd:server()) -> {'error',_}
                                           | {'ok','undefined' | pid()}
                                           | {'ok','undefined' | pid(),_}.
start_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host, ejabberd_mod_muc_sup),
    ChildSpec =
        {Proc,
         {ejabberd_tmp_sup, start_link,
          [Proc, mod_muc_room]},
         permanent,
         infinity,
         supervisor,
         [ejabberd_tmp_sup]},
    supervisor:start_child(ejabberd_sup, ChildSpec).


-spec stop_supervisor(ejabberd:server()) -> 'ok'
    | {'error','not_found' | 'restarting' | 'running' | 'simple_one_for_one'}.
stop_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host, ejabberd_mod_muc_sup),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).


-spec route({From :: ejabberd:jid(),
    To :: ejabberd:simple_jid() | ejabberd:jid(), Packet :: any()}, state())
            -> 'ok' | pid().
route(Routed, State) ->
    route_by_privilege(Routed, State).


-spec route_by_privilege({From :: ejabberd:jid(),
    To :: ejabberd:simple_jid() | ejabberd:jid(), Packet :: any()},
        state()) -> 'ok' | pid().
route_by_privilege({From, To, Packet} = Routed,
                   #state{access={AccessRoute,_,_,_},
                          server_host=ServerHost} = State) ->
    case acl:match_rule(ServerHost, AccessRoute, From) of
        allow ->
            {Room, _, _} = jid:to_lower(To),
            route_to_room(Room, Routed, State);
        _ ->
            #xmlel{attrs = Attrs} = Packet,
            Lang = xml:get_attr_s(<<"xml:lang">>, Attrs),
            ErrText = <<"Access denied by service policy">>,
            Err = jlib:make_error_reply(Packet,
                                        ?ERRT_FORBIDDEN(Lang, ErrText)),
            ejabberd_router:route_error(To, From, Err, Packet)
    end.


-spec route_to_room(room(), from_to_packet(), state()) -> 'ok' | pid().
route_to_room(<<>>, {_,To,_} = Routed, State) ->
    {_, _, Nick} = jid:to_lower(To),
    route_by_nick(Nick, Routed, State);
route_to_room(Room, {From,To,Packet} = Routed, #state{host=Host} = State) ->
    case mnesia:dirty_read(muc_online_room, {Room, Host}) of
        [] ->
            route_to_nonexistent_room(Room, Routed, State);
        [R] ->
            Pid = R#muc_online_room.pid,
            ?DEBUG("MUC: send to process ~p~n", [Pid]),
            {_, _, Nick} = jid:to_lower(To),
            mod_muc_room:route(Pid, From, Nick, Packet),
            ok
    end.


-spec route_to_nonexistent_room(room(), from_to_packet(), state()) -> 'ok'.
route_to_nonexistent_room(Room, {From, To, Packet},
                          #state{host=Host} = State) ->
    #xmlel{name = Name, attrs = Attrs} = Packet,
    Type = xml:get_attr_s(<<"type">>, Attrs),
    case {Name, Type} of
        {<<"presence">>, <<>>} ->
            ServerHost = State#state.server_host,
            Access = State#state.access,
            {_, AccessCreate, _, _} = Access,
            case check_user_can_create_room(ServerHost, AccessCreate,
                                            From, Room) of
                true ->
                    #state{history_size = HistorySize,
                           room_shaper = RoomShaper,
                           http_auth_pool = HttpAuthPool,
                           default_room_opts = DefRoomOpts} = State,
                    {_, _, Nick} = jid:to_lower(To),
                    {ok, Pid} = start_new_room(Host, ServerHost, Access, Room,
                                               HistorySize, RoomShaper, HttpAuthPool,
                                               From, Nick, DefRoomOpts),
                    register_room(Host, Room, Pid),
                    mod_muc_room:route(Pid, From, Nick, Packet),
                    ok;
                false ->
                    Lang = xml:get_attr_s(<<"xml:lang">>, Attrs),
                    ErrText = <<"Room creation is denied by service policy">>,
                    Err = jlib:make_error_reply(
                            Packet, ?ERRT_NOT_ALLOWED(Lang, ErrText)),
                    ejabberd_router:route(To, From, Err)
            end;
        _ ->
            Lang = xml:get_attr_s(<<"xml:lang">>, Attrs),
            ErrText = <<"Conference room does not exist">>,
            Err = jlib:make_error_reply(
                    Packet, ?ERRT_ITEM_NOT_FOUND(Lang, ErrText)),
            ejabberd_router:route(To, From, Err)
    end.


-spec route_by_nick(room(), from_to_packet(), state()) -> 'ok' | pid().
route_by_nick(<<>>, {_,_,Packet} = Routed, State) ->
    #xmlel{name = Name} = Packet,
    route_by_type(Name, Routed, State);
route_by_nick(_Nick, {From, To, Packet}, _State) ->
    #xmlel{attrs = Attrs} = Packet,
    case xml:get_attr_s(<<"type">>, Attrs) of
        <<"error">> ->
            ok;
        <<"result">> ->
            ok;
        _ ->
            Err = jlib:make_error_reply(Packet, ?ERR_ITEM_NOT_FOUND),
            ejabberd_router:route(To, From, Err)
    end.


-spec route_by_type(binary(), from_to_packet(), state()) -> 'ok' | pid().
route_by_type(<<"iq">>, {From, To, Packet}, #state{host = Host} = State) ->
    ServerHost = State#state.server_host,
    case jlib:iq_query_info(Packet) of
        #iq{type = get, xmlns = ?NS_DISCO_INFO = XMLNS, lang = Lang} = IQ ->
            Info = ejabberd_hooks:run_fold(disco_info, ServerHost, [],
                                           [ServerHost, ?MODULE, "", Lang]),
            Res = IQ#iq{type = result,
                        sub_el = [#xmlel{name = <<"query">>,
                                         attrs = [{<<"xmlns">>, XMLNS}],
                                         children = iq_disco_info(Lang) ++ Info}]},
            ejabberd_router:route(To, From, jlib:iq_to_xml(Res));
        #iq{type = get, xmlns = ?NS_DISCO_ITEMS} = IQ ->
            spawn(?MODULE, process_iq_disco_items, [Host, From, To, IQ]);
        #iq{type = get, xmlns = ?NS_REGISTER = XMLNS, lang = Lang} = IQ ->
            Res = IQ#iq{type = result,
                        sub_el = [#xmlel{name = <<"query">>,
                                         attrs = [{<<"xmlns">>, XMLNS}],
                                         children = iq_get_register_info(Host, From, Lang)}]},
            ejabberd_router:route(To, From, jlib:iq_to_xml(Res));
        #iq{type = set,
            xmlns = ?NS_REGISTER = XMLNS,
            lang = Lang,
            sub_el = SubEl} = IQ ->
            case process_iq_register_set(Host, From, SubEl, Lang) of
                {result, IQRes} ->
                    Res = IQ#iq{type = result,
                                sub_el = [#xmlel{name = <<"query">>,
                                                 attrs = [{<<"xmlns">>, XMLNS}],
                                                 children = IQRes}]},
                    ejabberd_router:route(To, From, jlib:iq_to_xml(Res));
                {error, Error} ->
                    Err = jlib:make_error_reply(Packet, Error),
                    ejabberd_router:route(To, From, Err)
            end;
        #iq{type = get, xmlns = ?NS_VCARD = XMLNS, lang = Lang} = IQ ->
            Res = IQ#iq{type = result,
                        sub_el = [#xmlel{name = <<"vCard">>,
                                         attrs = [{<<"xmlns">>, XMLNS}],
                                         children = iq_get_vcard(Lang)}]},
            ejabberd_router:route(To, From, jlib:iq_to_xml(Res));
        #iq{type = get, xmlns = ?NS_MUC_UNIQUE} = IQ ->
           Res = IQ#iq{type = result,
                       sub_el = [#xmlel{name = <<"unique">>,
                                        attrs = [{<<"xmlns">>, ?NS_MUC_UNIQUE}],
                                        children = [iq_get_unique(From)]}]},
           ejabberd_router:route(To, From, jlib:iq_to_xml(Res));
        #iq{} ->
            Err = jlib:make_error_reply(Packet, ?ERR_FEATURE_NOT_IMPLEMENTED),
            ejabberd_router:route(To, From, Err);
        _ ->
            ok
    end;
route_by_type(<<"message">>, {From, To, Packet},
              #state{host = Host, server_host = ServerHost,
                     access = {_,_,AccessAdmin,_}}) ->
    #xmlel{attrs = Attrs} = Packet,
    case xml:get_attr_s(<<"type">>, Attrs) of
        <<"error">> ->
            ok;
        _ ->
            case acl:match_rule(ServerHost, AccessAdmin, From) of
                allow ->
                    Msg = xml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),
                    broadcast_service_message(Host, Msg);
                _ ->
                    Lang = xml:get_attr_s(<<"xml:lang">>, Attrs),
                    ErrText = <<"Only service administrators are allowed to send service messages">>,
                    Err = ?ERRT_FORBIDDEN(Lang, ErrText),
                    ErrorReply = jlib:make_error_reply(Packet, Err),
                    ejabberd_router:route(To, From, ErrorReply)
            end
    end;
route_by_type(<<"presence">>, _Routed, _State) ->
    ok.


-spec check_user_can_create_room('global' | ejabberd:server(),
        'allow' | atom(), ejabberd:jid(), room()) -> boolean().
check_user_can_create_room(ServerHost, AccessCreate, From, RoomID) ->
    case acl:match_rule(ServerHost, AccessCreate, From) of
        allow ->
            (size(RoomID) =< gen_mod:get_module_opt(ServerHost, mod_muc,
                                                    max_room_id, infinite));
        _ ->
            false
    end.


-spec load_permanent_rooms(Host :: ejabberd:server(), Srv :: ejabberd:server(),
        Access :: access(), HistorySize :: 'undefined' | integer(),
        RoomShaper :: shaper:shaper(), HttpAuthPool :: none | mongoose_http_client:pool()) -> 'ok'.
load_permanent_rooms(Host, ServerHost, Access, HistorySize, RoomShaper, HttpAuthPool) ->
    case catch mnesia:dirty_select(
                 muc_room, [{#muc_room{name_host = {'_', Host}, _ = '_'},
                             [],
                             ['$_']}]) of
        {'EXIT', Reason} ->
            ?ERROR_MSG("~p", [Reason]),
            ok;
        Rs ->
            lists:foreach(
              fun(R) ->
                      {Room, Host} = R#muc_room.name_host,
                      case mnesia:dirty_read(muc_online_room, {Room, Host}) of
                          [] ->
                              {ok, Pid} = mod_muc_room:start(
                                            Host,
                                            ServerHost,
                                            Access,
                                            Room,
                                            HistorySize,
                                            RoomShaper,
                                            HttpAuthPool,
                                            R#muc_room.opts),
                              register_room(Host, Room, Pid);
                          _ ->
                              ok
                      end
              end, Rs)
    end.


-spec start_new_room(Host :: 'undefined' | ejabberd:server(),
        Srv :: ejabberd:server(), Access :: access(), room(),
        HistorySize :: 'undefined' | integer(), RoomShaper :: shaper:shaper(),
        HttpAuthPool :: none | mongoose_http_client:pool(), From :: ejabberd:jid(), nick(),
        DefRoomOpts :: 'undefined' | [any()])
            -> {'error',_}
             | {'ok','undefined' | pid()}
             | {'ok','undefined' | pid(),_}.
start_new_room(Host, ServerHost, Access, Room,
               HistorySize, RoomShaper, HttpAuthPool, From,
               Nick, DefRoomOpts) ->
    case mnesia:dirty_read(muc_room, {Room, Host}) of
        [] ->
            ?DEBUG("MUC: open new room '~s'~n", [Room]),
            mod_muc_room:start(Host, ServerHost, Access,
                               Room, HistorySize,
                               RoomShaper, HttpAuthPool, From,
                               Nick, DefRoomOpts);
        [#muc_room{opts = Opts}|_] ->
            ?DEBUG("MUC: restore room '~s'~n", [Room]),
            mod_muc_room:start(Host, ServerHost, Access,
                               Room, HistorySize,
                               RoomShaper, HttpAuthPool, Opts)
    end.


-spec register_room('undefined' | ejabberd:server(), room(),
                    'undefined' | pid()) -> {'aborted',_} | {'atomic',_}.
register_room(Host, Room, Pid) ->
    F = fun() ->
                mnesia:write(#muc_online_room{name_host = {Room, Host},
                                              pid = Pid})
        end,
    mnesia:transaction(F).


-spec room_jid_to_pid(RoomJID :: ejabberd:jid()) -> {ok, pid()} | {error, not_found}.
room_jid_to_pid(#jid{luser=RoomName, lserver=MucService}) ->
    case mnesia:dirty_read(muc_online_room, {RoomName, MucService}) of
        [R] ->
        {ok, R#muc_online_room.pid};
    [] ->
        {error, not_found}
    end.


-spec iq_disco_info(ejabberd:lang()) -> [jlib:xmlel(),...].
iq_disco_info(Lang) ->
    [#xmlel{name = <<"identity">>,
            attrs = [{<<"category">>, <<"conference">>},
                     {<<"type">>, <<"text">>},
                     {<<"name">>, translate:translate(Lang, <<"Chatrooms">>)}]},
     #xmlel{name = <<"feature">>, attrs = [{<<"var">>, ?NS_DISCO_INFO}]},
     #xmlel{name = <<"feature">>, attrs = [{<<"var">>, ?NS_DISCO_ITEMS}]},
     #xmlel{name = <<"feature">>, attrs = [{<<"var">>, ?NS_MUC}]},
     #xmlel{name = <<"feature">>, attrs = [{<<"var">>, ?NS_MUC_UNIQUE}]},
     #xmlel{name = <<"feature">>, attrs = [{<<"var">>, ?NS_REGISTER}]},
     #xmlel{name = <<"feature">>, attrs = [{<<"var">>, ?NS_RSM}]},
     #xmlel{name = <<"feature">>, attrs = [{<<"var">>, ?NS_VCARD}]}].


-spec iq_disco_items(ejabberd:server(), ejabberd:jid(), ejabberd:lang(),
        Rsm :: none | jlib:rsm_in()) -> any().
iq_disco_items(Host, From, Lang, none) ->
    lists:zf(fun(#muc_online_room{name_host = {Name, _Host}, pid = Pid}) ->
                     case catch gen_fsm:sync_send_all_state_event(
                                  Pid, {get_disco_item, From, Lang}, 100) of
                         {item, Desc} ->
                             flush(),
                             {true,
                              #xmlel{name = <<"item">>,
                                     attrs = [{<<"jid">>, jid:to_binary({Name, Host, <<>>})},
                                              {<<"name">>, Desc}]}};
                         _ ->
                             false
                     end
             end, get_vh_rooms(Host));
iq_disco_items(Host, From, Lang, Rsm) ->
    {Rooms, RsmO} = get_vh_rooms(Host, Rsm),
    RsmOut = jlib:rsm_encode(RsmO),
    lists:zf(fun(#muc_online_room{name_host = {Name, _Host}, pid = Pid}) ->
                     case catch gen_fsm:sync_send_all_state_event(
                                  Pid, {get_disco_item, From, Lang}, 100) of
                         {item, Desc} ->
                             flush(),
                             {true,
                              #xmlel{name = <<"item">>,
                                     attrs = [{<<"jid">>, jid:to_binary({Name, Host, <<>>})},
                                              {<<"name">>, Desc}]}};
                         _ ->
                             false
                     end
             end, Rooms) ++ RsmOut.


-spec get_vh_rooms(ejabberd:server(), jlib:rsm_in()) -> {list(), jlib:rsm_out()}.
get_vh_rooms(Host, #rsm_in{max=M, direction=Direction, id=I, index=Index}) ->
    AllRooms = lists:sort(get_vh_rooms(Host)),
    Count = erlang:length(AllRooms),
    Guard = case Direction of
                _ when Index =/= undefined ->
            [{'=:=', {element, 2, '$1'}, Host}];
                aft ->
            [{'=:=', {element, 2, '$1'}, Host},
             {'>',   {element, 1, '$1'}, I}]; %% not exact here
        before when I =/= <<>> ->
            [{'=:=', {element, 2, '$1'}, Host},
             {'<',   {element, 1, '$1'}, I}]; %% not exact here
                _ ->
            [{'=:=', {element, 2, '$1'}, Host}]
            end,
    L = lists:sort(
          mnesia:dirty_select(muc_online_room,
                              [{#muc_online_room{name_host = '$1', _ = '_'},
                                Guard,
                                ['$_']}])),
    L2 = if
             Index == undefined andalso Direction == before ->
                 lists:reverse(lists:sublist(lists:reverse(L), 1, M));
             Index == undefined ->
                 lists:sublist(L, 1, M);
             Index > Count  orelse Index < 0 ->
                 [];
             true ->
                 lists:sublist(L, Index+1, M)
         end,
    if
        L2 == [] ->
            {L2, #rsm_out{count=Count}};
        true ->
            H = hd(L2),
            NewIndex = get_room_pos(H, AllRooms),
            T=lists:last(L2),
            {F, _} = H#muc_online_room.name_host,
            {Last, _} = T#muc_online_room.name_host,
            {L2, #rsm_out{first=F, last=Last, count=Count, index=NewIndex}}
    end.

%% @doc Return the position of desired room in the list of rooms.
%% The room must exist in the list. The count starts in 0.
-spec get_room_pos(muc_online_room(), [muc_online_room()]) -> integer().
get_room_pos(Desired, Rooms) ->
    get_room_pos(Desired, Rooms, 0).
get_room_pos(Desired, [HeadRoom | _], HeadPosition)
  when (Desired#muc_online_room.name_host ==
        HeadRoom#muc_online_room.name_host) ->
    HeadPosition;
get_room_pos(Desired, [_ | Rooms], HeadPosition) ->
    get_room_pos(Desired, Rooms, HeadPosition + 1).


-spec flush() -> 'ok'.
flush() ->
    receive
        _ ->
            flush()
    after 0 ->
            ok
    end.


-spec xfield(Type :: binary(), Label :: binary(), Var :: binary(),
             Val :: binary(), ejabberd:lang()) -> jlib:xmlel().
xfield(Type, Label, Var, Val, Lang) ->
    #xmlel{name = <<"field">>,
           attrs = [{<<"type">>, Type},
                     {<<"label">>, translate:translate(Lang, Label)},
                     {<<"var">>, Var}],
           children = [#xmlel{name = <<"value">>,
                              children = [#xmlcdata{content = Val}]}]}.


%% @doc Get a pseudo unique Room Name. The Room Name is generated as a hash of
%%      the requester JID, the local time and a random salt.
%%
%%      <<"pseudo">> because we don't verify that there is not a room
%%       with the returned Name already created, nor mark the generated Name
%%       as <<"already used">>.  But in practice, it is unique enough. See
%%       http://xmpp.org/extensions/xep-0045.html#createroom-unique
-spec iq_get_unique(ejabberd:jid()) -> jlib:xmlcdata().
iq_get_unique(From) ->
        #xmlcdata{content = sha:sha1_hex(term_to_binary([From, now(), randoms:get_string()]))}.


-spec iq_get_register_info('undefined' | ejabberd:server(),
        ejabberd:simple_jid() | ejabberd:jid(), ejabberd:lang())
            -> [jlib:xmlel(),...].
iq_get_register_info(Host, From, Lang) ->
    {LUser, LServer, _} = jid:to_lower(From),
    LUS = {LUser, LServer},
    {Nick, Registered} =
        case catch mnesia:dirty_read(muc_registered, {LUS, Host}) of
            {'EXIT', _Reason} ->
                {<<>>, []};
            [] ->
                {<<>>, []};
            [#muc_registered{nick = N}] ->
                {N, [#xmlel{name = <<"registered">>}]}
        end,
    Registered ++
        [#xmlel{name = <<"instructions">>,
                children = [#xmlcdata{content = translate:translate(
                                                  Lang, <<"You need a client that supports x:data to register the nickname">>)}]},
         #xmlel{name = <<"x">>, attrs = [{<<"xmlns">>, ?NS_XDATA}],
                children = [#xmlel{name = <<"title">>,
                                   children = [#xmlcdata{content = <<(translate:translate(
                                                                     Lang, <<"Nickname Registration at ">>))/binary, Host/binary>>}]},
                            #xmlel{name = <<"instructions">>,
                                   children = [#xmlcdata{content = translate:translate(
                                                                     Lang, <<"Enter nickname you want to register">>)}]},
                            xfield(<<"text-single">>, <<"Nickname">>, <<"nick">>, Nick, Lang)]}].


-spec iq_set_register_info(ejabberd:server(),
        ejabberd:simple_jid() | ejabberd:jid(), nick(), ejabberd:lang())
            -> {'error',jlib:xmlel()} | {'result',[]}.
iq_set_register_info(Host, From, Nick, Lang) ->
    {LUser, LServer, _} = jid:to_lower(From),
    LUS = {LUser, LServer},
    F = fun() ->
                case Nick of
                    <<>> ->
                        mnesia:delete({muc_registered, {LUS, Host}}),
                        ok;
                    _ ->
                        Allow =
                            case mnesia:select(
                                   muc_registered,
                                   [{#muc_registered{us_host = '$1',
                                                     nick = Nick,
                                                     _ = '_'},
                                     [{'==', {element, 2, '$1'}, Host}],
                                     ['$_']}]) of
                                [] ->
                                    true;
                                [#muc_registered{us_host = {U, _Host}}] ->
                                    U == LUS
                            end,
                        if
                            Allow ->
                                mnesia:write(
                                  #muc_registered{us_host = {LUS, Host},
                                                  nick = Nick}),
                                ok;
                            true ->
                                false
                        end
                end
        end,
    case mnesia:transaction(F) of
        {atomic, ok} ->
            {result, []};
        {atomic, false} ->
            ErrText = <<"That nickname is registered by another person">>,
            {error, ?ERRT_CONFLICT(Lang, ErrText)};
        _ ->
            {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.


-spec process_iq_register_set(ejabberd:server(), ejabberd:jid(),
        jlib:xmlel(), ejabberd:lang())
            -> {'error', jlib:xmlel()} | {'result',[]}.
process_iq_register_set(Host, From, SubEl, Lang) ->
    #xmlel{children = Els} = SubEl,
    case xml:get_subtag(SubEl, <<"remove">>) of
        false ->
            case xml:remove_cdata(Els) of
                [#xmlel{name = <<"x">>} = XEl] ->
                    case {xml:get_tag_attr_s(<<"xmlns">>, XEl),
                          xml:get_tag_attr_s(<<"type">>, XEl)} of
                        {?NS_XDATA, <<"cancel">>} ->
                            {result, []};
                        {?NS_XDATA, <<"submit">>} ->
                            XData = jlib:parse_xdata_submit(XEl),
                            case XData of
                                invalid ->
                                    {error, ?ERR_BAD_REQUEST};
                                _ ->
                                    case lists:keysearch(<<"nick">>, 1, XData) of
                                        {value, {_, [Nick]}} when Nick /= <<>> ->
                                            iq_set_register_info(Host, From, Nick, Lang);
                                        _ ->
                                            ErrText = <<"You must fill in field \"Nickname\" in the form">>,
                                            {error, ?ERRT_NOT_ACCEPTABLE(Lang, ErrText)}
                                    end
                            end;
                        _ ->
                            {error, ?ERR_BAD_REQUEST}
                    end;
                _ ->
                    {error, ?ERR_BAD_REQUEST}
            end;
        _ ->
            iq_set_register_info(Host, From, <<>>, Lang)
    end.


-spec iq_get_vcard(ejabberd:lang()) -> [jlib:xmlel(),...].
iq_get_vcard(Lang) ->
    [#xmlel{name = <<"FN">>,
            children = [#xmlcdata{content = <<"ejabberd/mod_muc">>}]},
     #xmlel{name = <<"URL">>, children = [#xmlcdata{content = ?EJABBERD_URI}]},
     #xmlel{name = <<"DESC">>,
            children = [#xmlcdata{content =
                                  <<(translate:translate(Lang, <<"ejabberd MUC module">>))/binary,
                                    "\nCopyright (c) 2003-2011 ProcessOne">>}]}].


-spec broadcast_service_message(ejabberd:server(), binary() | string()) -> ok.
broadcast_service_message(Host, Msg) ->
    lists:foreach(
      fun(#muc_online_room{pid = Pid}) ->
              gen_fsm:send_all_state_event(
                Pid, {service_message, Msg})
      end, get_vh_rooms(Host)).


-spec get_vh_rooms(ejabberd:server()) -> [muc_online_room()].
get_vh_rooms(Host) ->
    mnesia:dirty_select(muc_online_room,
                        [{#muc_online_room{name_host = '$1', _ = '_'},
                          [{'==', {element, 2, '$1'}, Host}],
                          ['$_']}]).


-spec clean_table_from_bad_node(node()) -> any().
clean_table_from_bad_node(Node) ->
    F = fun() ->
                Es = mnesia:select(
                       muc_online_room,
                       [{#muc_online_room{pid = '$1', _ = '_'},
                         [{'==', {node, '$1'}, Node}],
                         ['$_']}]),
                lists:foreach(fun(E) ->
                                      mnesia:delete_object(E)
                              end, Es)
        end,
    mnesia:async_dirty(F).


-spec clean_table_from_bad_node(node(), ejabberd:server()) -> any().
clean_table_from_bad_node(Node, Host) ->
    F = fun() ->
                Es = mnesia:select(
                       muc_online_room,
                       [{#muc_online_room{pid = '$1',
                                          name_host = {'_', Host},
                                          _ = '_'},
                         [{'==', {node, '$1'}, Node}],
                         ['$_']}]),
                lists:foreach(fun(E) ->
                                      mnesia:delete_object(E)
                              end, Es)
        end,
    mnesia:async_dirty(F).


-spec update_tables(ejabberd:server()) -> any().
update_tables(Host) ->
    update_muc_room_table(Host),
    update_muc_registered_table(Host).


-spec update_muc_room_table(ejabberd:server()) -> any().
update_muc_room_table(Host) ->
    Fields = record_info(fields, muc_room),
    case mnesia:table_info(muc_room, attributes) of
        Fields ->
            ok;
        [name, opts] ->
            ?INFO_MSG("Converting muc_room table from {name, opts} format", []),
            {atomic, ok} = mnesia:create_table(
                             mod_muc_tmp_table,
                             [{disc_only_copies, [node()]},
                              {type, bag},
                              {local_content, true},
                              {record_name, muc_room},
                              {attributes, record_info(fields, muc_room)}]),
            mnesia:transform_table(muc_room, ignore, Fields),
            F1 = fun() ->
                         mnesia:write_lock_table(mod_muc_tmp_table),
                         mnesia:foldl(
                           fun(#muc_room{name_host = Name} = R, _) ->
                                   mnesia:dirty_write(
                                     mod_muc_tmp_table,
                                     R#muc_room{name_host = {Name, Host}})
                           end, ok, muc_room)
                 end,
            mnesia:transaction(F1),
            mnesia:clear_table(muc_room),
            F2 = fun() ->
                         mnesia:write_lock_table(muc_room),
                         mnesia:foldl(
                           fun(R, _) ->
                                   mnesia:dirty_write(R)
                           end, ok, mod_muc_tmp_table)
                 end,
            mnesia:transaction(F2),
            mnesia:delete_table(mod_muc_tmp_table);
        _ ->
            ?INFO_MSG("Recreating muc_room table", []),
            mnesia:transform_table(muc_room, ignore, Fields)
    end.


-spec update_muc_registered_table(ejabberd:server()) -> any().
update_muc_registered_table(Host) ->
    Fields = record_info(fields, muc_registered),
    case mnesia:table_info(muc_registered, attributes) of
        Fields ->
            ok;
        [user, nick] ->
            ?INFO_MSG("Converting muc_registered table from {user, nick} format", []),
            {atomic, ok} = mnesia:create_table(
                             mod_muc_tmp_table,
                             [{disc_only_copies, [node()]},
                              {type, bag},
                              {local_content, true},
                              {record_name, muc_registered},
                              {attributes, record_info(fields, muc_registered)}]),
            mnesia:del_table_index(muc_registered, nick),
            mnesia:transform_table(muc_registered, ignore, Fields),
            F1 = fun() ->
                         mnesia:write_lock_table(mod_muc_tmp_table),
                         mnesia:foldl(
                           fun(#muc_registered{us_host = US} = R, _) ->
                                   mnesia:dirty_write(
                                     mod_muc_tmp_table,
                                     R#muc_registered{us_host = {US, Host}})
                           end, ok, muc_registered)
                 end,
            mnesia:transaction(F1),
            mnesia:clear_table(muc_registered),
            F2 = fun() ->
                         mnesia:write_lock_table(muc_registered),
                         mnesia:foldl(
                           fun(R, _) ->
                                   mnesia:dirty_write(R)
                           end, ok, mod_muc_tmp_table)
                 end,
            mnesia:transaction(F2),
            mnesia:delete_table(mod_muc_tmp_table);
        _ ->
            ?INFO_MSG("Recreating muc_registered table", []),
            mnesia:transform_table(muc_registered, ignore, Fields)
    end.

%%====================================================================
%% Hooks handlers
%%====================================================================

-spec is_room_owner(Acc :: boolean(), Room :: ejabberd:jid(), User :: ejabberd:jid()) -> boolean().
is_room_owner(_, Room, User) ->
    mod_muc_room:is_room_owner(Room, User) =:= {ok, true}.

-spec muc_room_pid(Acc :: any(), Room :: ejabberd:jid()) -> {ok, pid()} | {error, not_found}.
muc_room_pid(_, Room) ->
    room_jid_to_pid(Room).

-spec can_access_room(Acc :: boolean(), From :: ejabberd:jid(), To :: ejabberd:jid()) ->
    boolean().
can_access_room(_, From, To) ->
    case mod_muc_room:can_access_room(To, From) of
        {error, _} -> false;
        {ok, CanAccess} -> CanAccess
    end.

