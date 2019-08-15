%%%============================================================================
%%% @copyright (C) 2019, Aeternity Anstalt
%%% @doc
%%% EUnit tests for aec_fork_signalling.
%%% @end
%%%============================================================================
-module(aec_fork_signalling_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("aecore/include/blocks.hrl").

-define(TEST_MODULE, aec_fork_signalling).

-define(SIGNALLING_START_HEIGHT, 2).
-define(SIGNALLING_END_HEIGHT, 5).
-define(SIGNALLING_BLOCK_COUNT, 2).

-define(FORK_HEIGHT, 7).

-define(INFO_FIELD_AGAINST, make_info(0)).
-define(INFO_FIELD_SUPPORT, make_info(1)).
-define(INFO_FIELD_OTHER, make_info(999)).

-define(VERSION_OLD, 4).
-define(VERSION_NEW, 5).

%% [0] --- [1] --- [2] --- [3] --- [4] --- [5] --- [6] --- [7] ---
%%         H1      HS            HE - 1    HE    H2 - 1    H2

-define(FORK_CFG,
        #{signalling_start_height => ?SIGNALLING_START_HEIGHT,
          signalling_end_height   => ?SIGNALLING_END_HEIGHT,
          signalling_block_count  => ?SIGNALLING_BLOCK_COUNT,
          fork_height             => ?FORK_HEIGHT,
          info_field              => ?INFO_FIELD_SUPPORT,
          version                 => ?VERSION_NEW}).

-define(BASIC_CHAIN_NEGATIVE_RESULT,
        #{1                        => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER},
          ?SIGNALLING_START_HEIGHT => #{version => ?VERSION_OLD, info => ?INFO_FIELD_AGAINST},
          ?SIGNALLING_END_HEIGHT   => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER}}).

-define(BASIC_CHAIN_POSITIVE_RESULT,
        #{1                        => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER},
          ?SIGNALLING_START_HEIGHT => #{version => ?VERSION_OLD, info => ?INFO_FIELD_SUPPORT},
          ?SIGNALLING_END_HEIGHT   => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER}}).

basic_chain_test_() ->
    {foreach,
     fun() ->
             aec_test_utils:mock_genesis_and_forks(),
             ?TEST_MODULE:start_link(),
             aec_test_utils:start_chain_db(),
             aec_test_utils:aec_keys_setup()
     end,
     fun(TmpDir) ->
             aec_test_utils:aec_keys_cleanup(TmpDir),
             aec_test_utils:stop_chain_db(),
             ?TEST_MODULE:stop(),
             aec_test_utils:unmock_genesis_and_forks()
     end,
     [{"Basic chain negative result test", fun() -> basic_chain(?BASIC_CHAIN_NEGATIVE_RESULT, false) end},
      {"Basic chain positive result test", fun() -> basic_chain(?BASIC_CHAIN_POSITIVE_RESULT, true) end}
     ]}.

basic_chain(BlockCfgs, ExpectedForkResult) ->
    %% FORK_HEIGHT blocks are needed to be generated (including the genesis),
    %% so the chain ends up at H2 - 1 height where it's possible to find out
    %% the fork signalling result.
    Chain = [B0, B1, B2, B3, B4, B5, B6] =
        aec_test_utils:gen_blocks_only_chain(?FORK_HEIGHT, BlockCfgs),
    [BH0, BH1, BH2, BH3, BH4, BH5, BH6] = [block_hash(B) || B <- Chain],

    ok = insert_block(B0),
    ?TEST_MODULE:compute_fork_result(B0, BH0, ?FORK_CFG),
    {error, not_last_block_before_fork} = ?TEST_MODULE:get_fork_result(B0, BH0, ?FORK_CFG),

    ok = insert_block(B1),
    ?TEST_MODULE:compute_fork_result(B1, BH1, ?FORK_CFG),
    {error, not_last_block_before_fork} = ?TEST_MODULE:get_fork_result(B1, BH1, ?FORK_CFG),

    ok = insert_block(B2),
    ?TEST_MODULE:compute_fork_result(B2, BH2, ?FORK_CFG),
    {error, not_last_block_before_fork} = ?TEST_MODULE:get_fork_result(B2, BH2, ?FORK_CFG),

    ok = insert_block(B3),
    ?TEST_MODULE:compute_fork_result(B3, BH3, ?FORK_CFG),
    {error, not_last_block_before_fork} = ?TEST_MODULE:get_fork_result(B3, BH3, ?FORK_CFG),

    ok = insert_block(B4),
    ?TEST_MODULE:compute_fork_result(B4, BH4, ?FORK_CFG),
    {error, not_last_block_before_fork} = ?TEST_MODULE:get_fork_result(B4, BH4, ?FORK_CFG),

    ok = insert_block(B5),
    ?TEST_MODULE:compute_fork_result(B5, BH5, ?FORK_CFG),
    {error, not_last_block_before_fork} = ?TEST_MODULE:get_fork_result(B5, BH5, ?FORK_CFG),

    ok = insert_block(B6),
    ?TEST_MODULE:compute_fork_result(B6, BH6, ?FORK_CFG),
    {ok, ExpectedForkResult} = await_result(B6, BH6, ?FORK_CFG),

    ok.

make_info(X) when is_integer(X) ->
    <<X:?OPTIONAL_INFO_BYTES/unit:8>>.

await_result(Block, BlockHash, Fork) ->
    await_result(Block, BlockHash, Fork, 5).

await_result(Block, BlockHash, Fork, Retries) when Retries > 0 ->
    case ?TEST_MODULE:get_fork_result(Block, BlockHash, Fork) of
        {ok, pending} ->
            timer:sleep(500),
            await_result(Block, BlockHash, Fork, Retries - 1);
        {ok, Result} when is_boolean(Result) ->
            {ok, Result}
    end;
await_result(_Block, _BlockHash, _Fork, 0) ->
    {error, exhausted_retries}.

block_hash(Block) ->
    {ok, H} = aec_blocks:hash_internal_representation(Block),
    H.

insert_block(Block) ->
    insert_block_ret(aec_chain_state:insert_block(Block)).

insert_block_ret({ok,_}     ) -> ok;
insert_block_ret({pof,Pof,_}) -> {pof,Pof};
insert_block_ret(Other      ) -> Other.
