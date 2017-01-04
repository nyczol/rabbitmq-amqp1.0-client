-module(amqp10_client_connection).

-behaviour(gen_fsm).

-include("amqp10_client.hrl").
-include("rabbit_amqp1_0_framing.hrl").

%% Public API.
-export([open/2,
         close/1
        ]).

%% Private API.
-export([start_link/1,
         socket_ready/2,
         protocol_header_received/4,
         begin_session/1
        ]).

%% gen_fsm callbacks.
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

%% gen_fsm state callbacks.
-export([expecting_socket/2,
         expecting_protocol_header/2,
         expecting_open_frame/2,
         opened/2,
         expecting_close_frame/2]).

-record(state,
        {next_channel = 1 :: pos_integer(),
         connection_sup :: pid(),
         sessions_sup :: pid() | undefined,
         pending_session_reqs = [] :: [term()],
         reader :: pid() | undefined,
         socket :: gen_tcp:socket() | undefined
        }).

%% -------------------------------------------------------------------
%% Public API.
%% -------------------------------------------------------------------

-spec open(
        inet:socket_address() | inet:hostname(),
        inet:port_number()) -> supervisor:startchild_ret().

open(Addr, Port) ->
    %% Start the supervision tree dedicated to that connection. It
    %% starts at least a connection process (the PID we want to return)
    %% and a reader process (responsible for opening and reading the
    %% socket).
    case supervisor:start_child(amqp10_client_sup, [Addr, Port]) of
        {ok, ConnSup} ->
            %% We query the PIDs of the connection and reader processes. The
            %% reader process needs to know the connection PID to send it the
            %% socket.
            Children = supervisor:which_children(ConnSup),
            {_, Reader, _, _} = lists:keyfind(reader, 1, Children),
            {_, Connection, _, _} = lists:keyfind(connection, 1, Children),
            {_, SessionsSup, _, _} = lists:keyfind(sessions, 1, Children),
            set_other_procs(Connection, #{sessions_sup => SessionsSup,
                                          reader => Reader}),
            {ok, Connection};
        Error ->
            Error
    end.

-spec close(pid()) -> ok.

close(Pid) ->
    gen_fsm:send_event(Pid, close).

%% -------------------------------------------------------------------
%% Private API.
%% -------------------------------------------------------------------

start_link(Sup) ->
    gen_fsm:start_link(?MODULE, Sup, []).

set_other_procs(Pid, OtherProcs) ->
    gen_fsm:send_all_state_event(Pid, {set_other_procs, OtherProcs}).

-spec socket_ready(pid(), gen_tcp:socket()) -> ok.

socket_ready(Pid, Socket) ->
    gen_fsm:send_event(Pid, {socket_ready, Socket}).

-spec protocol_header_received(pid(), non_neg_integer(), non_neg_integer(),
                               non_neg_integer()) -> ok.

protocol_header_received(Pid, Maj, Min, Rev) ->
    gen_fsm:send_event(Pid, {protocol_header_received, Maj, Min, Rev}).

-spec begin_session(pid()) -> supervisor:startchild_ret().

begin_session(Pid) ->
    gen_fsm:sync_send_all_state_event(Pid, begin_session).

%% -------------------------------------------------------------------
%% gen_fsm callbacks.
%% -------------------------------------------------------------------

init(Sup) ->
    {ok, expecting_socket, #state{connection_sup = Sup}}.

expecting_socket({socket_ready, Socket}, State) ->
    State1 = State#state{socket = Socket},
    ok = gen_tcp:send(Socket, ?PROTOCOL_HEADER),
    {next_state, expecting_protocol_header, State1}.

expecting_protocol_header({protocol_header_received, 1, 0, 0}, State) ->
    case send_open(State) of
        ok    -> {next_state, expecting_open_frame, State};
        Error -> {stop, Error, State}
    end;
expecting_protocol_header({protocol_header_received, Maj, Min, Rev}, State) ->
    error_logger:info_msg("Unsupported protocol version: ~b.~b.~b~n",
                          [Maj, Min, Rev]),
    {stop, normal, State}.

expecting_open_frame(
  #'v1_0.open'{},
  #state{pending_session_reqs = PendingSessionReqs} = State) ->
    error_logger:info_msg("-- CONNECTION OPENED --~n", []),
    State3 = lists:foldr(
      fun(From, State1) ->
              {Ret, State2} = handle_begin_session(State1),
              _ = gen_fsm:reply(From, Ret),
              State2
      end, State, PendingSessionReqs),
    {next_state, opened, State3}.

opened(close, State) ->
    %% We send the first close frame and wait for the reply.
    case send_close(State) of
        ok              -> {next_state, expecting_close_frame, State};
        {error, closed} -> {stop, normal, State};
        Error           -> {stop, Error, State}
    end;
opened(#'v1_0.close'{}, State) ->
    %% We receive the first close frame, reply and terminate.
    _ = send_close(State),
    {stop, normal, State};
opened(_Frame, State) ->
    {next_state, opened, State}.

expecting_close_frame(#'v1_0.close'{}, State) ->
    {stop, normal, State}.

handle_event({set_other_procs, OtherProcs}, StateName, State) ->
    #{sessions_sup := SessionsSup,
      reader := Reader} = OtherProcs,
    amqp10_client_frame_reader:set_connection(Reader, self()),
    State1 = State#state{sessions_sup = SessionsSup,
                         reader = Reader},
    {next_state, StateName, State1};
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(begin_session, _, opened, State) ->
    {Ret, State1} = handle_begin_session(State),
    {reply, Ret, opened, State1};
handle_sync_event(begin_session, From, StateName,
                  #state{pending_session_reqs = PendingSessionReqs} = State)
  when StateName =:= expecting_socket orelse
       StateName =:= expecting_protocol_header orelse
       StateName =:= expecting_open_frame ->
    %% The caller already asked for a new session but the connection
    %% isn't fully opened. Let's queue this request until the connection
    %% is ready.
    State1 = State#state{pending_session_reqs = [From | PendingSessionReqs]},
    {next_state, StateName, State1};
handle_sync_event(begin_session, _, StateName, State) ->
    {reply, {error, connection_closed}, StateName, State};
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(Reason, _StateName, #state{connection_sup = Sup}) ->
    case Reason of
        normal -> sys:terminate(Sup, normal);
        _      -> ok
    end,
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% -------------------------------------------------------------------
%% Internal functions.
%% -------------------------------------------------------------------

handle_begin_session(#state{sessions_sup = Sup,
                          reader = Reader,
                          next_channel = Channel} = State) ->
    Ret = supervisor:start_child(Sup, [Channel, Reader]),
    State1 = case Ret of
                 {ok, _} -> State#state{next_channel = Channel + 1};
                 _       -> State
             end,
    {Ret, State1}.

send_open(#state{socket = Socket}) ->
    {ok, Product} = application:get_key(description),
    {ok, Version} = application:get_key(vsn),
    Platform = "Erlang/OTP " ++ erlang:system_info(otp_release),
    Props = {map, [{{symbol, <<"product">>},
                    {utf8, list_to_binary(Product)}},
                   {{symbol, <<"version">>},
                    {utf8, list_to_binary(Version)}},
                   {{symbol, <<"platform">>},
                    {utf8, list_to_binary(Platform)}}
                  ]},
    Open = #'v1_0.open'{container_id = {utf8, <<"test">>},
                        hostname = {utf8, <<"localhost">>},
                        max_frame_size = {uint, ?MAX_FRAME_SIZE},
                        channel_max = {ushort, 100},
                        idle_time_out = {uint, 0},
                        properties = Props},
    Encoded = rabbit_amqp1_0_framing:encode_bin(Open),
    Frame = rabbit_amqp1_0_binary_generator:build_frame(0, Encoded),
    gen_tcp:send(Socket, Frame).

send_close(#state{socket = Socket}) ->
    Close = #'v1_0.close'{},
    Encoded = rabbit_amqp1_0_framing:encode_bin(Close),
    Frame = rabbit_amqp1_0_binary_generator:build_frame(0, Encoded),
    Ret = gen_tcp:send(Socket, Frame),
    case Ret of
        ok -> _ = gen_tcp:shutdown(Socket, write),
              ok;
        _  -> ok
    end,
    Ret.