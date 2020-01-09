-module(ar_unbalanced_merkle).
-export([root/2, root/3]).
-export([block_index_to_merkle_root/1, wallet_list_to_merkle_root/1]).

-include("ar.hrl").
-include_lib("eunit/include/eunit.hrl").

%%% Module for building and manipulating generic and specific unbalanced merkle trees.

%% @doc Take a prior merkle root and add a new peice of data to it, optionally
%% providing a conversion function prior to hashing.
root(OldRoot, Data, Fun) -> root(OldRoot, Fun(Data)).
root(OldRoot, Data) ->
	crypto:hash(?MERKLE_HASH_ALG, << OldRoot/binary, Data/binary >>).

%% @doc Generate a new entire merkle tree from a BI.
block_index_to_merkle_root(BI) ->
	lists:foldl(
		fun({BH, _}, MR) -> root(MR, BH) end,
		<<>>,
		lists:reverse(BI)
	).

%% @doc Generate a new wallet list merkle root from a WL.
wallet_list_to_merkle_root(WL) ->
	lists:foldl(
		fun(Wallet, MR) ->
			root(
				MR,
				Wallet,
				fun wallet_to_binary/1
			)
		end,
		<<>>,
		lists:reverse(WL)
	).

%%% Helper functions

%% @doc Turn a wallet into a binary, for addition to a Merkle tree.
wallet_to_binary({Addr, Balance, LastTX}) ->
	<< Addr/binary, (integer_to_binary(Balance))/binary, LastTX/binary >>.

%%% TESTS

basic_hash_root_generation_test() ->
	BH0 = crypto:strong_rand_bytes(32),
	BH1 = crypto:strong_rand_bytes(32),
	BH2 = crypto:strong_rand_bytes(32),
	MR0 = test_hash(BH0),
	MR1 = test_hash(<<MR0/binary, BH1/binary>>),
	MR2 = test_hash(<<MR1/binary, BH2/binary>>),
	?assertEqual(MR2, block_index_to_merkle_root([{BH2, 0}, {BH1, 0}, {BH0, 0}])).

test_hash(Bin) -> crypto:hash(?MERKLE_HASH_ALG, Bin).

root_update_test() ->
	BH0 = crypto:strong_rand_bytes(32),
	BH1 = crypto:strong_rand_bytes(32),
	BH2 = crypto:strong_rand_bytes(32),
	BH3 = crypto:strong_rand_bytes(32),
	Root =
		root(
			root(
				block_index_to_merkle_root([{BH1, 0}, {BH0, 0}]),
				BH2
			),
			BH3
		),
	?assertEqual(
		block_index_to_merkle_root([{BH3, 0}, {BH2, 0}, {BH1, 0}, {BH0, 0}]),
		Root
	).
