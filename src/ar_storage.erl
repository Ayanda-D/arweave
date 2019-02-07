-module(ar_storage).
-export([start/0]).
-export([write_block/1, write_full_block/1, read_block/2, clear/0]).
-export([write_encrypted_block/2, read_encrypted_block/1, invalidate_block/1]).
-export([delete_block/1, blocks_on_disk/0, block_exists/1]).
-export([write_tx/1, read_tx/1]).
-export([write_wallet_list/1, read_wallet_list/1]).
-export([write_block_hash_list/2, read_block_hash_list/1]).
-export([delete_tx/1, txs_on_disk/0, tx_exists/1]).
-export([enough_space/1, select_drive/2]).
-export([calculate_disk_space/0, calculate_used_space/0, update_directory_size/0]).
-export([lookup_block_filename/1,lookup_tx_filename/1]).
-export([do_read_block/2, do_read_tx/1]).
-export([ensure_directories/0]).
-include("ar.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%%% Reads and writes blocks from disk.


-define(DIRECTORY_SIZE_TIMER, 300000).

%% @doc Ready the system for block/tx reading and writing.
%% %% This function should block.
start() ->
	ensure_directories(),
	ar_block_index:start().

%% @doc Ensure that all of the relevant storage directories exist.
ensure_directories() ->
	filelib:ensure_dir(?TX_DIR),
	filelib:ensure_dir(?BLOCK_DIR),
	filelib:ensure_dir(?BLOCK_ENC_DIR),
	filelib:ensure_dir(?WALLET_LIST_DIR),
	filelib:ensure_dir(?HASH_LIST_DIR),
	filelib:ensure_dir(?LOG_DIR).

%% @doc Clear the cache of saved blocks.
clear() ->
	lists:map(fun file:delete/1, filelib:wildcard(?BLOCK_DIR ++ "/*.json")),
	ar_block_index:clear().

%% @doc Removes a saved block.
delete_block(Hash) ->
	ar_block_index:remove(Hash),
	file:delete(name_block(Hash)).

%% @doc Returns the number of blocks stored on disk.
blocks_on_disk() ->
	ar_block_index:count().

block_exists(Hash) ->
	case filelib:find_file(name_block(Hash)) of
		{ok, _} -> true;
		{error, _} -> false
	end.

%% @doc Move a block into the 'invalid' block directory.
invalidate_block(B) ->
	ar_block_index:remove(B#block.indep_hash),
	TargetFile =
		lists:flatten(
			io_lib:format(
				"~s/invalid/~w_~s.json",
				[?BLOCK_DIR, B#block.height, ar_util:encode(B#block.indep_hash)]
			)
		),
	filelib:ensure_dir(TargetFile),
	file:rename(
		lists:flatten(
			io_lib:format(
				"~s/~w_~s.json",
				[?BLOCK_DIR, B#block.height, ar_util:encode(B#block.indep_hash)]
			)
		),
		TargetFile
	).

%% @doc Write a block (with the hash.json as the filename) to disk.
%% When debug is set, does not consider disk space. This is currently
%% necessary because of test timings
-ifdef(DEBUG).
write_block(Bs) when is_list(Bs) -> lists:foreach(fun write_block/1, Bs);
write_block(RawB) ->
	case ar_meta_db:get(disk_logging) of
		true ->
			ar:report([{writing_block_to_disk, ar_util:encode(RawB#block.indep_hash)}]);
		_ ->
			do_nothing
	end,
	WalletID = write_wallet_list(RawB#block.wallet_list),
	B = RawB#block { wallet_list = WalletID },
	BlockToWrite = ar_serialize:jsonify(ar_serialize:block_to_json_struct(B)),
	file:write_file(
		Name = lists:flatten(
			io_lib:format(
				"~s/~w_~s.json",
				[?BLOCK_DIR, B#block.height, ar_util:encode(B#block.indep_hash)]
			)
		),
		BlockToWrite
	),
	ar_block_index:add(B, Name),
	Name.
-else.
write_block(Bs) when is_list(Bs) -> lists:foreach(fun write_block/1, Bs);
write_block(RawB) ->
	case ar_meta_db:get(disk_logging) of
		true ->
			ar:report([{writing_block_to_disk, ar_util:encode(RawB#block.indep_hash)}]);
		_ ->
			do_nothing
	end,
	WalletID = write_wallet_list(RawB#block.wallet_list),
	B = RawB#block { wallet_list = WalletID },
	BlockToWrite = ar_serialize:jsonify(ar_serialize:block_to_json_struct(B)),
	case enough_space(byte_size(BlockToWrite)) of
		true ->
			file:write_file(
				Name = lists:flatten(
					io_lib:format(
						"~s/~w_~s.json",
						[?BLOCK_DIR, B#block.height, ar_util:encode(B#block.indep_hash)]
					)
				),
				BlockToWrite
			),
			ar_block_index:add(B, Name),
			spawn(
				ar_meta_db,
				increase,
				[used_space, byte_size(BlockToWrite)]
			),
			Name;
		false ->
			ar:err(
				[
					{not_enough_space_to_write_block},
					{block_not_written}
				]
			),
			{error, not_enough_space}
	end.
-endif.

%% Write a full block to disk, including writing TXs and modifying the
%% TX list.
write_full_block(B) ->
	BShadow = B#block { txs = [T#tx.id || T <- B#block.txs] },
	ar_storage:write_tx(B#block.txs),
	ar_storage:write_block(BShadow).

%% @doc Write an encrypted	block (with the hash.json as the filename) to disk.
%% When debug is set, does not consider disk space. This is currently
%% necessary because of test timings
-ifdef(DEBUG).
write_encrypted_block(Hash, B) ->
	BlockToWrite = B,
	file:write_file(
		Name = lists:flatten(
			io_lib:format(
				"~s/~s_~s.json",
				[?BLOCK_ENC_DIR, "encrypted" , ar_util:encode(Hash)]
			)
		),
		BlockToWrite
	),
	Name.
-else.
write_encrypted_block(Hash, B) ->
	BlockToWrite = B,
	case enough_space(byte_size(BlockToWrite)) of
		true ->
			file:write_file(
				Name = lists:flatten(
					io_lib:format(
						"~s/~s_~s.json",
						[?BLOCK_ENC_DIR, "encrypted" , ar_util:encode(Hash)]
					)
				),
				BlockToWrite
			),
			spawn(
				ar_meta_db,
				increase,
				[used_space, byte_size(BlockToWrite)]
			),
			Name;
		false ->
			ar:report(
				[
					{not_enough_space_to_write_block},
					{block_not_written}
				]
			),
			{error, enospc}
	end.
-endif.



%% @doc Read a block from disk, given a hash.
read_block(unavailable, _BHL) -> unavailable;
read_block(B, _BHL) when is_record(B, block) -> B;
read_block(Bs, BHL) when is_list(Bs) ->
	lists:map(fun(B) -> read_block(B, BHL) end, Bs);
read_block(ID, BHL) ->
	case ar_block_index:get_block_filename(ID) of
		unavailable -> unavailable;
		Filename -> do_read_block(Filename, BHL)
	end.
do_read_block(Filename, BHL) ->
	{ok, Binary} = file:read_file(Filename),
	B = ar_serialize:json_struct_to_block(Binary),
	WL = B#block.wallet_list,
	FinalB =
		B#block {
			hash_list = ar_block:generate_hash_list_for_block(B, BHL),
			wallet_list =
				if is_binary(WL) ->
					case read_wallet_list(WL) of
						{error, Type} ->
							ar:report(
								[
									{
										error_reading_wallet_list_from_disk,
										ar_util:encode(B#block.indep_hash)
									},
									{type, Type}
								]
							),
							not_found;
						ReadWL -> ReadWL
					end;
				true -> WL
				end
		},
	case FinalB#block.wallet_list of
		not_found ->
			invalidate_block(B),
			unavailable;
		_ -> FinalB
	end.

%% @doc Read an encrypted block from disk, given a hash.
read_encrypted_block(unavailable) -> unavailable;
read_encrypted_block(ID) ->
	case filelib:wildcard(name_enc_block(ID)) of
		[] -> unavailable;
		[Filename] -> do_read_encrypted_block(Filename);
		Filenames ->
			do_read_encrypted_block(hd(
				lists:sort(
					fun(Filename, Filename2) ->
						{ok, Info} = file:read_file_info(Filename, [{time, posix}]),
						{ok, Info2} = file:read_file_info(Filename2, [{time, posix}]),
						Info#file_info.mtime >= Info2#file_info.mtime
					end,
					Filenames
				)
			))
	end.
do_read_encrypted_block(Filename) ->
	{ok, Binary} = file:read_file(Filename),
	Binary.

%% @doc Accurately recalculate the current cumulative size of the Arweave directory
update_directory_size() ->
	spawn(
		fun() ->
			ar_meta_db:put(used_space, calculate_used_space())
		end
	),
	timer:apply_after(?DIRECTORY_SIZE_TIMER, ar_storage, update_directory_size, []).

lookup_block_filename(ID) ->
	ar_block_index:get_block_filename(ID).

%% @doc Generate a wildcard search string for a block,
%% given a block, binary hash, or list.
name_block(Height) when is_integer(Height) ->
	?BLOCK_DIR ++ "/" ++ integer_to_list(Height) ++ "_*.json";
name_block(B) when is_record(B, block) ->
	?BLOCK_DIR
		++ "/"
		++ integer_to_list(B#block.height)
		++ "_"
		++ binary_to_list(ar_util:encode(B#block.indep_hash))
		++ ".json";
name_block(BinHash) when is_binary(BinHash) ->
	?BLOCK_DIR ++ "/*_" ++ binary_to_list(ar_util:encode(BinHash)) ++ ".json".

%% @doc Generate a wildcard search string for an encrypted block,
%% given a block, binary hash, or list.
name_enc_block(BinHash) when is_binary(BinHash) ->
	?BLOCK_ENC_DIR ++ "/*_" ++ binary_to_list(ar_util:encode(BinHash)) ++ ".json".

%% @doc Delete the tx with the given hash from disk.
delete_tx(Hash) ->
	file:delete(name_tx(Hash)).

%% @doc Returns the number of blocks stored on disk.
txs_on_disk() ->
	{ok, Files} = file:list_dir(?TX_DIR),
	length(Files).

%% @doc Returns whether the TX with the given hash is stored on disk.
tx_exists(Hash) ->
	case filelib:find_file(name_tx(Hash)) of
		{ok, _} -> true;
		{error, _} -> false
	end.

%% @doc Write a tx (with the txid.json as the filename) to disk.
%% When debug is set, does not consider disk space. This is currently
%% necessary because of test timings
-ifdef(DEBUG).
write_tx(Txs) when is_list(Txs) -> lists:foreach(fun write_tx/1, Txs);
write_tx(Tx) ->
	file:write_file(
		Name = lists:flatten(
			io_lib:format(
				"~s/~s.json",
				[?TX_DIR, ar_util:encode(Tx#tx.id)]
			)
		),
		ar_serialize:jsonify(ar_serialize:tx_to_json_struct(Tx))
	),
	Name.
-else.
write_tx(Txs) when is_list(Txs) -> lists:foreach(fun write_tx/1, Txs);
write_tx(Tx) ->
	TxToWrite = ar_serialize:jsonify(ar_serialize:tx_to_json_struct(Tx)),
	case enough_space(byte_size(TxToWrite)) of
		true ->
			file:write_file(
				Name = lists:flatten(
					io_lib:format(
						"~s/~s.json",
						[?TX_DIR, ar_util:encode(Tx#tx.id)]
					)
				),
				ar_serialize:jsonify(ar_serialize:tx_to_json_struct(Tx))
			),
			spawn(
				ar_meta_db,
				increase,
				[used_space, byte_size(TxToWrite)]
			),
			Name;
		false ->
			ar:report(
				[
					{not_enough_space_to_write_tx},
					{tx_not_written}
				]
			),
			{error, enospc}
	end.
-endif.

%% @doc Read a tx from disk, given a hash.
read_tx(unavailable) -> unavailable;
read_tx(Tx) when is_record(Tx, tx) -> Tx;
read_tx(Txs) when is_list(Txs) ->
	lists:map(fun read_tx/1, Txs);
read_tx(ID) ->
	Filename = name_tx(ID),
	case filelib:is_regular(Filename) of
		false ->
			unavailable;
		true ->
			do_read_tx(Filename)
	end.

do_read_tx(Filename) ->
	{ok, Binary} = file:read_file(Filename),
	ar_serialize:json_struct_to_tx(Binary).

%% Write a block hash list to disk for retreival later (in emergencies).
write_block_hash_list(BinID, BHL) ->
	ar:report([{writing_block_hash_list_to_disk, ID = ar_util:encode(BinID)}]),
	JSON = ar_serialize:jsonify(ar_serialize:hash_list_to_json_struct(BHL)),
	file:write_file(
		?HASH_LIST_DIR ++ "/" ++ binary_to_list(ar_util:encode(BinID)) ++ ".json",
		JSON
	),
	ID.

%% Write a block hash list to disk for retreival later (in emergencies).
write_wallet_list(WalletList) ->
	ID = ar_block:hash_wallet_list(WalletList),
	JSON = ar_serialize:jsonify(ar_serialize:wallet_list_to_json_struct(WalletList)),
	file:write_file(
		?WALLET_LIST_DIR ++ "/" ++ binary_to_list(ar_util:encode(ID)) ++ ".json",
		JSON
	),
	ID.

%% @doc Read a list of block hashes from the disk.
read_block_hash_list(BinID) ->
	FileName = ?HASH_LIST_DIR ++ "/" ++ binary_to_list(ar_util:encode(BinID)) ++ ".json",
	{ok, Binary} = file:read_file(FileName),
	ar_serialize:json_struct_to_hash_list(ar_serialize:dejsonify(Binary)).

%% @doc Read a given wallet list (by hash) from the disk.
read_wallet_list(ID) ->
	FileName = ?WALLET_LIST_DIR ++ "/" ++ binary_to_list(ar_util:encode(ID)) ++ ".json",
	case file:read_file(FileName) of
		{ok, Binary} ->
			ar_serialize:json_struct_to_wallet_list(ar_serialize:dejsonify(Binary));
		Err -> Err
	end.

lookup_tx_filename(ID) ->
	case filelib:wildcard(name_tx(ID)) of
		[] -> unavailable;
		[Filename] -> Filename;
		Filenames ->
			hd(lists:sort(
					fun(Filename, Filename2) ->
						{ok, Info} = file:read_file_info(Filename, [{time, posix}]),
						{ok, Info2} = file:read_file_info(Filename2, [{time, posix}]),
						Info#file_info.mtime >= Info2#file_info.mtime
					end,
					Filenames
				)
			)
	end.

%% @doc Returns the file name for a TX with the given hash
name_tx(Tx) when is_record(Tx, tx) ->
	?TX_DIR
		++ "/"
		++ binary_to_list(ar_util:encode(Tx#tx.id))
		++ ".json";
name_tx(BinHash) when is_binary(BinHash) ->
	?TX_DIR ++ "/" ++ binary_to_list(ar_util:encode(BinHash)) ++ ".json".

% @doc Check that there is enough space to write Bytes bytes of data
enough_space(Bytes) ->
	(ar_meta_db:get(disk_space)) >= (Bytes + ar_meta_db:get(used_space)).

%% @doc Calculate the amount of file space used by the Arweave client
calculate_used_space() ->
	{ok, CWD} = file:get_cwd(),
	(
		filelib:fold_files(
			CWD,
			"/*",
			true,
			fun(F, Acc) -> Acc + filelib:file_size(F) end,
			0
		)
	).

%% @doc Calculate the total amount of disk space available
calculate_disk_space() ->
	application:start(sasl),
	application:start(os_mon),
	{ok, CWD} = file:get_cwd(),
	[{_,Size,_}|_] = select_drive(disksup:get_disk_data(), CWD),
	Size*1024.

%% @doc Calculate the root drive in which the Arweave server resides
select_drive(Disks, []) ->
	CWD = "/",
	case
		Drives = lists:filter(
			fun({Name, _, _}) ->
				case Name == CWD of
					false -> false;
					true -> true
				end
			end,
			Disks
		)
	of
		[] -> false;
		Drives ->
			Drives
	end;
select_drive(Disks, CWD) ->
	try
		case
			Drives = lists:filter(
				fun({Name, _, _}) ->
					try
						case string:find(Name, CWD) of
							nomatch -> false;
							_ -> true
						end
					catch _:_ -> false
					end
				end,
				Disks
			)
		of
			[] -> select_drive(Disks, hd(string:split(CWD, "/", trailing)));
			Drives -> Drives
		end
	catch _:_ -> select_drive(Disks, [])
	end.

%% @doc Test block storage.
store_and_retrieve_block_test() ->
    ar_storage:clear(),
	?assertEqual(0, blocks_on_disk()),
    B0s = [B0] = ar_weave:init([]),
    ar_storage:write_block(B0),
	B0 = read_block(B0#block.indep_hash, B0#block.hash_list),
    B1s = [B1|_] = ar_weave:add(B0s, []),
    ar_storage:write_block(B1),
    [B2|_] = ar_weave:add(B1s, []),
    ar_storage:write_block(B2),
	write_block(B1),
	?assertEqual(3, blocks_on_disk()),
	B1 = read_block(B1#block.indep_hash, B2#block.hash_list),
	B1 = read_block(B1#block.height, B2#block.hash_list).

clear_blocks_test() ->
	ar_storage:clear(),
	?assertEqual(0, blocks_on_disk()).

store_and_retrieve_tx_test() ->
	Tx0 = ar_tx:new(<<"DATA1">>),
	write_tx(Tx0),
	Tx0 = read_tx(Tx0),
	Tx0 = read_tx(Tx0#tx.id),
	file:delete(name_tx(Tx0)).

% store_and_retrieve_encrypted_block_test() ->
%	  B0 = ar_weave:init([]),
%	  ar_storage:write_block(B0),
%	  B1 = ar_weave:add(B0, []),
%	  CipherText = ar_block:encrypt_block(hd(B0), hd(B1)),
%	  write_encrypted_block((hd(B0))#block.hash, CipherText),
%	read_encrypted_block((hd(B0))#block.hash),
%	Block0 = hd(B0),
%	Block0 = ar_block:decrypt_full_block(hd(B1), CipherText, Key).

% not_enough_space_test() ->
%	Disk = ar_meta_db:get(disk_space),
%	ar_meta_db:put(disk_space, 0),
%	[B0] = ar_weave:init(),
%	Tx0 = ar_tx:new(<<"DATA1">>),
%	{error, enospc} = write_block(B0),
%	{error, enospc} = write_tx(Tx0),
%	ar_meta_db:put(disk_space, Disk).

%% @doc Ensure blocks can be written to disk, then moved into the 'invalid'
%% block directory.
invalidate_block_test() ->
	[B] = ar_weave:init(),
	write_full_block(B),
	invalidate_block(B),
	timer:sleep(500),
	unavailable = read_block(B#block.indep_hash, B#block.hash_list),
	TargetFile =
		lists:flatten(
			io_lib:format(
				"~s/invalid/~w_~s.json",
				[?BLOCK_DIR, B#block.height, ar_util:encode(B#block.indep_hash)]
			)
		),
	?assert(B == do_read_block(TargetFile, B#block.hash_list)).

store_and_retrieve_block_hash_list_test() ->
	ID = crypto:strong_rand_bytes(32),
    B0s = ar_weave:init([]),
	write_block(hd(B0s)),
    B1s = ar_weave:add(B0s, []),
	write_block(hd(B1s)),
    [B2|_] = ar_weave:add(B1s, []),
	write_block_hash_list(ID, B2#block.hash_list),
	receive after 500 -> ok end,
	BHL = read_block_hash_list(ID),
	BHL = B2#block.hash_list.

store_and_retrieve_wallet_list_test() ->
    [B0] = ar_weave:init(),
	write_wallet_list(WL = B0#block.wallet_list),
	receive after 500 -> ok end,
	WL = read_wallet_list(ar_block:hash_wallet_list(WL)).
