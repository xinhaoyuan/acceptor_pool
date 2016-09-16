-module(acceptor_pool).

-behaviour(gen_server).

%% public api

-export([start_link/2,
         start_link/3,
         attach/3]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

-type pool() :: pid() | atom() | {atom(), node()} | {via, module(), any()} |
                {global, any()}.

-type pool_flags() :: #{}.

-type acceptor_spec() :: #{id := term(),
                           start := {module(), any(), [acceptor:option()]}}.

-type name() ::
    {inet:ip_address(), inet:port_number()} | inet:returned_non_ip_address().

-export_type([pool/0,
              pool_flags/0,
              acceptor_spec/0,
              name/0]).

-record(state, {name,
                mod :: module(),
                args :: any(),
                start :: {module(), any(), [acceptor:option()]},
                sockets = #{} :: #{reference() =>
                                   {module(), name(), gen_tcp:socket()}},
                acceptors = #{} :: #{reference() => reference()},
                conns = #{} :: #{pid() => reference()}}).

-callback init(Args) -> {ok, PoolFlags, [AcceptorSpec, ...]} | ignore when
      Args :: any(),
      PoolFlags :: pool_flags(),
      AcceptorSpec :: acceptor_spec().

%% public api

-spec start_link(Module, Args) -> {ok, Pid} | ignore | {error, Reason} when
      Module :: module(),
      Args :: any(),
      Pid :: pid(),
      Reason :: any().
start_link(Module, Args) ->
    gen_server:start_link(?MODULE, {self, Module, Args}, []).

-spec start_link(Name, Module, Args) ->
    {ok, Pid} | ignore | {error, Reason} when
      Name :: {local, atom()} | {via, module, any()} | {global, any()},
      Module :: module(),
      Args :: any(),
      Pid :: pid(),
      Reason :: any().
start_link(Name, Module, Args) ->
    gen_server:start_link(Name, ?MODULE, {Name, Module, Args}, []).

-spec attach(Pool, Sock, Acceptors) -> {ok, Ref} | {error, Reason} when
      Pool :: pool(),
      Sock :: gen_tcp:socket(),
      Acceptors :: pos_integer(),
      Ref :: reference(),
      Reason :: inet:posix().
attach(Pool, Sock, Acceptors)
  when is_port(Sock), is_integer(Acceptors), Acceptors > 0 ->
    gen_server:call(Pool, {attach, Sock, Acceptors}, infinity).

%% gen_server api

%% @private
init({self, Mod, Args}) ->
    init({self(), Mod, Args});
init({Name, Mod, Args}) ->
    _ = process_flag(trap_exit, true),
    try Mod:init(Args) of
        Res ->
            init(Name, Mod, Args, Res)
    catch
        throw:Res ->
            init(Name, Mod, Args, Res)
    end.

handle_call({attach, Sock, Acceptors}, _, State) ->
    SockRef = monitor(port, Sock),
    case socket_info(Sock) of
        {ok, SockInfo} ->
            NState = start_conns(SockRef, SockInfo, Acceptors, State),
            {reply, {ok, SockRef}, NState};
        {error, _} = Error ->
            demonitor(SockRef, [flush]),
            {reply, Error, State}
    end.


handle_cast(Req, State) ->
    {stop, {bad_cast, Req}, State}.

%% TODO: Reply to {which|count}_children supervisor calls
handle_info({'EXIT', Conn, _}, #state{conns=Conns} = State) ->
    {noreply, State#state{conns=maps:remove(Conn, Conns)}};
handle_info({'ACCEPT', AcceptRef}, #state{acceptors=Acceptors} = State) ->
    case maps:take(AcceptRef, Acceptors) of
        {SockRef, NAcceptors} ->
            NState = start_conn(SockRef, NAcceptors, State),
            demonitor(AcceptRef, [flush]),
            {noreply, NState};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', AcceptRef, process, _, _},
            #state{acceptors=Acceptors} = State) ->
    case maps:take(AcceptRef, Acceptors) of
        {SockRef, NAcceptors} ->
            {noreply, start_conn(SockRef, NAcceptors, State)};
        error ->
            {noreply, State}
    end;
handle_info({'DOWN', SockRef, port, _, _}, #state{sockets=Sockets} = State) ->
    {noreply, State#state{sockets=maps:remove(SockRef, Sockets)}};
handle_info(_, State) ->
    % TODO: log unexpected message
    {noreply, State}.

code_change(_, State, _) ->
    % TODO: Support supervisor style reconfiguration with code change
    {ok, State}.

terminate(_, #state{conns=Conns}) ->
    _ = [exit(Conn, shutdown) || {Conn, _} <- maps:to_list(Conns)],
    terminate(Conns).

%% internal

terminate(Conns) ->
    % TODO: send supervisor_report for abnormal exit
    Conn = receive {'EXIT', Pid, _} -> Pid end,
    case maps:remove(Conn, Conns) of
        NConns when map_size(NConns) == 0 ->
            ok;
        NConns ->
            terminate(NConns)
    end.

%% TODO: Handle some pool flags and acceptor specs
init(Name, Mod, Args, {ok, #{}, [#{start := {_, _, _} = Start}]}) ->
    {ok, #state{name=Name, mod=Mod, args=Args, start=Start}};
init(_, _, _, ignore) ->
    ignore;
init(_, Mod, _, Other) ->
    {stop, {bad_return, {Mod, init, Other}}}.

socket_info(Sock) ->
    case inet_db:lookup_socket(Sock) of
        {ok, SockMod}      -> socket_info(SockMod, Sock);
        {error, _} = Error -> Error
    end.

socket_info(SockMod, Sock) ->
    case inet:sockname(Sock) of
        {ok, SockName}     -> {ok, {SockMod, SockName, Sock}};
        {error, _} = Error -> Error
    end.

start_conns(SockRef, SockInfo, NumAcceptors, #state{sockets=Sockets} = State) ->
    NState = State#state{sockets=Sockets#{SockRef => SockInfo}},
    start_conns(SockRef, NumAcceptors, NState).

start_conns(_, 0, State) ->
    State;
start_conns(SockRef, N, #state{acceptors=Acceptors} = State) ->
    start_conns(SockRef, N-1, start_conn(SockRef, Acceptors, State)).

start_conn(SockRef, Acceptors,
           #state{sockets=Sockets, start={Mod, Args, Opts},
                  conns=Conns} = State) ->
    case Sockets of
        #{SockRef := {SockMod, SockName, Sock}} ->
            {Pid, AcceptRef} =
                acceptor:spawn_opt(Mod, SockMod, SockName, Sock, Args, Opts),
            State#state{acceptors=Acceptors#{AcceptRef => SockRef},
                        conns=Conns#{Pid => SockRef}};
        _ ->
            State#state{acceptors=Acceptors}
    end.
