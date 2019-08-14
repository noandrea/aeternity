%%%============================================================================
%%% @copyright (C) 2019, Aeternity Anstalt
%%% @doc
%%% H1 - height before the the signalling start height;
%%% HS - signalling start height;
%%% HE - signalling end height;
%%% H2 - fork height;
%%%
%%% H1 < HS < HE < H2
%%%
%%% The gen_server process (aec_fork_signalling) makes sure that there is a
%%% fork result at H2 (true, false or pending). In order to compute the fork
%%% result, it manages asynchronous processes that walk the chain and compute
%%% how many blocks include a predefined info field between HE - 1 and HS
%%% (inclusive).
%%%
%%% The block at height HE - 1 is the last signalling block, and there must
%%% be a result computed for it. Once a worker process that computes the
%%% result is spawned, a 'pending' atom for the given block hash is  stored in
%%% results map. Once the worker process is done with the computation it will
%%% send a boolean result and the 'pending' atom is replaced with the boolean
%%% result.
%%%
%%% The blocks with height between HE and H2 - 1 (inclusive) are treated
%%% differently. Once such block arrives, its previous key hash is looked up
%%% in the results map. If it's present, it means that the previous key hash
%%% belongs to the block at height HE - 1 (which has result set to 'true',
%%% 'false' or 'pending'), or the previous key hash has a pointer (key block
%%% hash) to a block at height HE - 1.
%%%
%%% The pointers are used because the result at height HE - 1 can change
%%% asynchronosly (from 'pending' to a boolean value). Moreover, it's not
%%% necessary to search a block at HE - 1 height to get the result in case
%%% a new block arrives. Instead, the results map may have an entry for
%%% previous key hash pointing to the block with HE - 1 height.
%%%
%%% The worst case scenario is restarting the node at height H2 - 1. If the
%%% node has the top key block at height H2 - 1 and the results map is empty,
%%% it needs to start a worker process that will search for a block at HE - 1,
%%% and then it will start computing the fork result. Some components of the
%%% system may be waiting for the final result.
%%%
%%% @end
%%%============================================================================
-module(aec_fork_signalling).

-behaviour(gen_server).

%% API
-export([start_link/0,
         get_fork_result/3,
         compute_fork_result/3
        ]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2
        ]).

-export([worker_process/4]).

-type header_hash()      :: aec_blocks:block_header_hash().

-type worker()           :: {pid(), reference()}.

-type result()           :: true | false | pending.

%% The pointer is a key block hash which belongs to the last signalling block
%% (the block at height HE - 1).
-type pointer()          :: header_hash().

-record(state, {results  :: #{header_hash() := result() | pointer()},
                workers  :: #{worker() := header_hash()}
               }).

-define(SERVER, ?MODULE).
-define(IS_RESULT(X), X =:= true orelse X =:= false orelse X =:= pending).
-define(IS_POINTER(X), is_binary(X)).

%% API

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

get_fork_result(Block, BlockHash, Fork) ->
    gen_server:call(?SERVER, {get_fork_result, Block, BlockHash, Fork}).

compute_fork_result(Block, BlockHash, Fork) ->
    case get_action_from_block_height(Block, Fork) of
        Action when Action =/= skip_block ->
            gen_server:cast(?SERVER, {compute_fork_result, Action, Block,
                                      BlockHash, Fork});
        skip_block ->
            ok
    end.

%% gen_server callbacks

init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{results = maps:new(), workers = maps:new()}}.

handle_call({get_fork_result, Block, BlockHash, Fork}, _From, State) ->
    {Reply, State1} = handle_get_fork_result(Block, BlockHash, Fork, State),
    {reply, Reply, State1};
handle_call(_Request, _From, State) ->
    {reply, ingnored, State}.

handle_cast({compute_fork_result, Action, Block, BlockHash, Fork}, State) ->
    {noreply, handle_compute_fork_result(Action, Block, BlockHash, Fork, State)};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({worker_msg, Pid, Msg}, State) ->
    {noreply, handle_worker_msg(Pid, Msg, State)};
handle_info({'DOWN', Ref, process, Pid, Rsn}, State) ->
    {noreply, handle_down({Pid, Ref}, Rsn, State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Rsn, #state{workers = Workers} = State) ->
    maps:foldl(fun(W, _BH, S1) -> kill_worker(W, S1) end, State, Workers).

%% Internal functions

get_action_from_block_height(Block, Fork) ->
    case {is_last_signalling_block(Block, Fork),
          is_signalling_result_required(Block, Fork)} of
        {true, _}      -> spawn_worker;
        {false, true}  -> set_prev_result_or_spawn_worker;
        {false, false} -> skip_block
    end.

handle_get_fork_result(Block, BlockHash, Fork, #state{results = Results} = State) ->
    case is_last_block_before_fork(Block, Fork) of
        true ->
            %% Only pointer and 'undefined' are considered. If the actual
            %% result was returned, it would mean HE - 1 == H2 - 1 and so
            %% HE < H2 wouldn't apply (the configuration check handles this
            %% situation).
            case get_result(BlockHash, Results) of
                Pointer when ?IS_POINTER(Pointer) ->
                    %% The block at height H2 - 1 is supposed to have a pointer
                    %% (in the best case scenario) to the block hash at height
                    %% HE - 1 with the actual result.
                    {ok, Result} = get_result(Pointer, Results),
                    {{ok, Result}, State};
                undefined ->
                    %% If there is no entry, a worker needs to be spawned and
                    %% the returned result is 'pending'.
                    State1 = spawn_worker(Block, BlockHash, Fork, State),
                    {{ok, pending}, State1}
            end;
        false ->
            {{error, not_last_block_before_fork}, State}
    end.

handle_compute_fork_result(spawn_worker, Block, BlockHash, Fork, State) ->
    spawn_worker(Block, BlockHash, Fork, State);
handle_compute_fork_result(set_prev_result_or_spawn_worker, Block, BlockHash, Fork, State) ->
    set_prev_result_or_spawn_worker(Block, BlockHash, Fork, State).

handle_worker_msg({Pid, _Ref}, {check_result, BlockHash, LastSigBlockHash},
                  #state{results = Results} = State) ->
    case get_result(LastSigBlockHash, Results) of
        Result when Result =/= undefined ->
            %% Another process computed or is computing the result for this
            %% block hash (at height HE - 1).
            send_server_msg(Pid, abort),
            State#state{results = add_result(BlockHash, LastSigBlockHash, Results)};
        undefined ->
            send_server_msg(Pid, compute),
            Results1 = add_result(BlockHash, LastSigBlockHash, Results),
            Results2 = add_result(LastSigBlockHash, pending, Results1),
            State#state{results = Results2}
    end;
handle_worker_msg(_Worker, {add_result, BlockHash, Result},
                  #state{results = Results} = State) ->
    State#state{results = add_result(BlockHash, Result, Results)}.

handle_down(Worker, _Rsn, #state{workers = Workers} = State) ->
    State#state{workers = del_worker(Worker, Workers)}.

spawn_worker(Block, BlockHash, Fork, #state{workers = Workers} = State) ->
    Worker = new_worker([Block, BlockHash, Fork]),
    State#state{workers = add_worker(Worker, BlockHash, Workers)}.

kill_worker({Pid, Ref} = Worker, #state{workers = Workers} = State) ->
    cancel_monitor(Ref),
    exit(Pid, shutdown),
    flush_worker_msgs(),
    State#state{workers = del_worker(Worker, Workers)}.

set_prev_result_or_spawn_worker(Block, BlockHash, Fork,
                                #state{results = Results} = State) ->
    PrevKeyHash = aec_blocks:prev_key_hash(Block),
    case get_result(PrevKeyHash, Results) of
        R when ?IS_RESULT(R) ->
            %% The PrevKeyHash key is associated with a result (PrevKeyhash is
            %% a block hash of block at height HE - 1). The BlockHash is
            %% set to point to the PrevKeyHash (so it's possible to retrieve
            %% the result for BlockHash).
            State#state{results = add_result(BlockHash, PrevKeyHash, Results)};
        P when ?IS_POINTER(P) ->
            %% The PrevKeyhash is associated with a pointer that is a block
            %% hash at height HE - 1, which has the result. The BlockHash is
            %% set to point to the same block hash at height HE - 1.
            %% The PrevKeyhash associated with the pointer can now be discarded
            %% to avoid caching results for all the blocks between HE and
            %% H2 - 1 (inclusive).
            Results1 = add_result(BlockHash, P, Results),
            Results2 = del_result(PrevKeyHash, Results1),
            State#state{results = Results2};
        undefined ->
            %% There is no result reachable via PrevKeyhash. A new process is
            %% spawned, it will set both a pointer (for BlockHash) and
            %% a result for a block hash at height HE - 1.
            spawn_worker(Block, BlockHash, Fork, State)
    end.

worker_process(Parent, Block, BlockHash, Fork) ->
    case search_last_signalling_block(Block, BlockHash, Fork) of
        {ok, LastSigBlock, LastSigBlockHash} ->
            send_worker_msg(Parent, {check_result, BlockHash, LastSigBlockHash}),
            case await_server_msg(Parent) of
                {ok, compute} ->
                    case compute_signalling_result(LastSigBlock, LastSigBlockHash, Fork) of
                        {ok, Result} ->
                            send_worker_msg(Parent, {add_result, LastSigBlockHash, Result});
                        {error, _Rsn} = Err ->
                            Err
                    end;
                {ok, abort} ->
                    aborted;
                {error, _Rsn} = Err ->
                    Err
            end;
        {error, _Rsn} = Err ->
            Err
    end.

search_last_signalling_block(Block, BlockHash, Fork) ->
    case is_last_signalling_block(Block, Fork) of
        true ->
            {ok, Block, BlockHash};
        false ->
            PrevKeyHash = aec_blocks:prev_key_hash(Block),
            case get_key_block(PrevKeyHash) of
                Block1 when Block1 =/= not_found ->
                    search_last_signalling_block(Block1, PrevKeyHash, Fork);
                not_found ->
                    {error, block_not_found}
            end
    end.

compute_signalling_result(Block, BlockHash, Fork) ->
    case compute_signalling_result(Block, BlockHash, Fork, 0) of
        {ok, Count}         -> signalling_result(Count, Fork);
        {error, _Rsn} = Err -> Err
    end.

compute_signalling_result(Block, _BlockHash, Fork, Count) ->
    case is_first_signalling_block(Block, Fork) of
        true ->
            {ok, Count + count_inc(is_matching_info_present(Block, Fork))};
        false ->
            PrevKeyHash = aec_blocks:prev_key_hash(Block),
            case get_key_block(PrevKeyHash) of
                Block1 when Block1 =/= not_found ->
                    Count1 = Count + count_inc(is_matching_info_present(Block, Fork)),
                    compute_signalling_result(Block1, PrevKeyHash, Fork, Count1);
                not_found ->
                    {error, block_not_found}
            end
    end.

is_first_signalling_block(Block, #{signalling_start_height := StartHeight}) ->
    aec_blocks:height(Block) =:= StartHeight.

is_last_signalling_block(Block, #{signalling_end_height := EndHeight}) ->
    aec_blocks:height(Block) =:= (EndHeight - 1).

is_last_block_before_fork(Block, #{fork_height := ForkHeight}) ->
    aec_blocks:height(Block) =:= (ForkHeight - 1).

is_signalling_result_required(Block, #{signalling_end_height := EndHeight,
                                       fork_height := ForkHeight}) ->
    BlockHeight = aec_blocks:height(Block),
    (BlockHeight >= (EndHeight - 1)) andalso (BlockHeight < ForkHeight).

signalling_result(Count, #{signalling_block_count := BlockCount}) ->
    Count >= BlockCount.

is_matching_info_present(Block, #{info_field := InfoField}) ->
    Info = aec_headers:info(aec_blocks:to_header(Block)),
    Info =:= InfoField.

get_key_block(PrevKeyHash) ->
    case aec_chain:get_block(PrevKeyHash) of
        {ok, Block} -> Block;
        error       -> not_found
    end.

add_result(BlockHash, Result, Results) ->
    maps:put(BlockHash, Result, Results).

del_result(BlockHash, Results) ->
    maps:remove(BlockHash, Results).

get_result(BlockHash, Results) ->
    maps:get(BlockHash, Results, undefined).

new_worker(Args) ->
    spawn_monitor(?MODULE, worker_process, [self() | Args]).

add_worker(Worker, BlockHash, Workers) ->
    maps:put(Worker, BlockHash, Workers).

del_worker(Worker, Workers) ->
    maps:remove(Worker, Workers).

count_inc(true)  -> 1;
count_inc(false) -> 0.

send_worker_msg(Parent, Msg) ->
    Parent ! {worker_msg, self(), Msg}.

send_server_msg(Worker, Msg) ->
    Worker ! {server_msg, self(), Msg}.

await_server_msg(Parent) ->
    receive
        {server_msg, Parent, Msg} ->
            {ok, Msg}
    after
        5000 ->
            {error, timeout}
    end.

cancel_monitor(Ref) when is_reference(Ref) ->
    demonitor(Ref, [flush]).

flush_worker_msgs() ->
    receive
        {worker_msg, _Pid, _Msg} -> ok
    after
        0 -> ok
    end.
