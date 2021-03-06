%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 10:52 PM
%%%-------------------------------------------------------------------
-module(minuteman_ipsets).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  minuteman_vip_events:add_sup_handler(fun(Vips) -> gen_server:call(?SERVER, {push_vips, Vips}) end),
  %% Clear the VIP state
  handle_push_vips([]),
  {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
  State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call({push_vips, Vips}, _From, State) ->
  maybe_handle_push_vips(Vips),
  {reply, ok, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
%% Stratio:
%% When a custom event_handler doesn't process callback event correctly and results in
%% an exception, the event manager removes that event handler from the internal
%% list of registered callbacks. The removal of a faulty event handler is a
%% silent operation, however when the event handler is deleted due to a fault,
%% the event manager sends a message {gen_event_EXIT,Handler,Reason} to the
%% calling process. This out-of-band message is catched by handle_info of
%% gen_server behaviour.
%%
%% The fix is trap this error message (matching the gen_event_EXIT) and raising
%% an stop of the server. This is catched by the minuteman_ipsets gen_server
%% supervisor and restarts the server back running the gen_server init code
%% again, that in turn re-register the callback again.
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info({gen_event_EXIT, _Info, Reason}, State) ->
    io:format("stratio: ~w: detected handler ~p shutdown:~n~p~n", [?MODULE, State, Reason]),
    {stop, {handler_died, _Info, Reason}, State};
handle_info(_Info, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
  State :: #state{}) -> term()).
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
  Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
maybe_handle_push_vips(Vips) ->
  case minuteman_config:networking() of
    true ->
      handle_push_vips(Vips);
    false ->
      ok
  end.
handle_push_vips(Vips) ->
  ensure_main_ipset_created(),
  ensure_temp_ipset_destroyed(),
  make_temp_ipset(Vips),
  swap_sets(),
  ensure_temp_ipset_destroyed().
ensure_main_ipset_created() ->
  os:cmd("ipset create minuteman hash:ip,port").
ensure_temp_ipset_destroyed() ->
  os:cmd("ipset destroy minuteman-tmp").
make_temp_ipset(Vips) ->
  os:cmd("ipset create minuteman-tmp hash:ip,port"),
  Keys = orddict:fetch_keys(Vips),
  Pairs = [{inet:ntoa(IP), Port} || {tcp, IP, Port} <- Keys],
  Commands = [lists:flatten(io_lib:format("ipset add minuteman-tmp ~s,~B", [IP, Port])) || {IP, Port} <- Pairs],
  lager:debug("Running commands: ~p", [Commands]),
  lists:foreach(fun os:cmd/1, Commands).
swap_sets() ->
  os:cmd("ipset swap minuteman minuteman-tmp").