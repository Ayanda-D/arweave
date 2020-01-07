-module(ar_cleanup).
-export([remove_invalid_blocks/1]).
-export([all/0, rewrite/0, rewrite/1]).

-include("ar.hrl").
-include_lib("eunit/include/eunit.hrl").

%%%
%%% @doc Functions to clean up blocks not on the list of valid blocks
%%% and invalid transactions that are no longer valid for some reason.
%%%

%% @doc Run all cleanup operations.
all() ->
	io:format("Rewriting all blocks (this may take a very long time...)~n"),	
	rewrite(),
	io:format("Removing all orphan/invalid blocks...~n"),
	remove_invalid_blocks(ar_node:get_block_index(whereis(http_entrypoint_node))),
	io:format("Done!~n").	


%% @doc Remove all blocks from blocks directory not in BI
remove_invalid_blocks(BI) ->
	DataDir = ar_meta_db:get(data_dir),
	BlockDir = filename:join(DataDir, ?BLOCK_DIR),
	{ok, RawFiles} = file:list_dir(BlockDir),
	Files =
		lists:filter(
			fun(X) ->
				not filelib:is_dir(filename:join(BlockDir, X))
			end,
			RawFiles -- [".gitignore"]
		),
	lists:foreach(
		fun(X) ->
			file:delete(filename:join(BlockDir, X))
		end,
		lists:filter(
			fun(Y) ->
				case lists:foldl(
					fun({Z, _}, Sum) -> Sum + string:str(Y, binary_to_list(ar_util:encode(Z))) end,
					0,
					BI
				) of
					0 -> true;
					_ -> false
				end
			end,
			Files
		)
	),
	EncryptedBlockDir = filename:join(DataDir, ?ENCRYPTED_BLOCK_DIR),
	case file:list_dir(EncryptedBlockDir) of
		{ok, FilesEnc} ->
			lists:foreach(
				fun(X) ->
					file:delete(filename:join(EncryptedBlockDir, X))
				end,
				FilesEnc
			);
		_ -> do_nothing
	end.

%% @doc Rewrite every block in the hash list using the latest format.
%% In the case of upgrading a node from 1.1 to 1.5, this dramatically reduces
%% the size of the weave on disk (and on the wire).
rewrite() ->
	rewrite(lists:reverse(ar_node:get_block_index(whereis(http_entrypoint_node)))).
rewrite(BI) -> rewrite(BI, BI).
rewrite([], _BI) -> [];
rewrite([{H,_}|Rest], BI) ->
	try ar_storage:read_block(H, BI) of
		B when ?IS_BLOCK(B) ->
			ar_storage:write_block(B),
			ar:report([{rewrote_block, ar_util:encode(H)}]);
		unavailable ->
			do_nothing
	catch _:_ ->
		ar:report([{error_rewriting_block, ar_util:encode(H)}])
	end,
	rewrite(Rest, BI).

%%%
%%% Tests.
%%%

%% @doc Remove all TXs from the TX directory that are "too cheap"
remove_block_keep_directory_test() ->
	ar_storage:clear(),
	B0 = ar_weave:init([]),
	ar_storage:write_block(B0),
	B1 = ar_weave:add(B0, []),
	ar_storage:write_block(hd(B1)),
	ListBlockFiles = fun() ->
		BlockDir = filename:join(ar_meta_db:get(data_dir), ?BLOCK_DIR),
		{ok, FilesAndDirs} = file:list_dir(BlockDir),
		FullFilesAndDirs = [filename:join(BlockDir, Name) || Name <- FilesAndDirs, Name /= ".gitignore"],
		lists:filter(fun(Filename) -> not filelib:is_dir(Filename) end, FullFilesAndDirs)
	end,
	?assert(length(ListBlockFiles()) > 0),
	remove_invalid_blocks([]),
	?assertEqual([], ListBlockFiles()).
