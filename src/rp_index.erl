%% SPDX-License-Identifier: MIT
%%
%% The rebar3 cache of a lockfile. Hex tarballs sit where rebar3 keeps
%% them, under hex/<repository>/packages/. Beside each one this module
%% writes the `.etag` file rebar3 writes after a download, and it writes
%% the package index, hex/packages.idx, from the tarballs alone.
%%
%% rebar3 reads the index for every Hex dependency, even one rebar.lock
%% pins, before it looks at the cached tarball. The index holds each
%% package's checksums and requirements, which every Hex tarball carries,
%% so the index of exactly the locked versions follows from the locked
%% tarballs. It is written in the layout of rebar3's rebar_packages module
%% (index format 7, the `package` record of rebar.hrl), with rebar3's own
%% version parser. A rebar3 that changes the index format discards an
%% index of another format as out of date, and then fails to resolve
%% offline, which the fixture builds catch.
-module(rp_index).

-export([build_cache/0, index/1]).

%% ?PACKAGE_INDEX_VERSION in rebar3's rebar.hrl.
-define(INDEX_VERSION, 7).

%% The builder of the cache tree in Nix. The manifest lists one entry per
%% line, its path in the tree and its store path, separated by a tab. The
%% entries file holds the download entries that lib-overlays/default/read-lock.nix
%% reads from the lockfile and rebar.lock, where each git entry carries the
%% URLs rebar3 clones it from as `rebar3Sources`. A file
%% entry, and a git entry without `leaveDotGit`, is linked at its path. A
%% git entry with `leaveDotGit` is a checkout with the .git directory the
%% shared purifier library rebuilt, and its path gets a bare repository of
%% that .git directory, with the tags and branches of its git sources.
build_cache() ->
    Out = os:getenv("out"),
    {ok, Manifest} = file:read_file(os:getenv("manifestPath")),
    {ok, EntriesJson} = file:read_file(os:getenv("entriesPath")),
    Entries = json:decode(EntriesJson),
    GitSources = [
        S#{<<"path">> => P}
     || #{<<"path">> := P, <<"rebar3Sources">> := Ss} <- Entries,
        S <- Ss
    ],
    Artifacts = maps:from_list([{P, A} || A = #{<<"path">> := P} <- Entries]),
    Sources = maps:map(
        fun(_, Ss) ->
            #{
                <<"tags">> => lists:usort(lists:append([maps:get(<<"tags">>, S) || S <- Ss])),
                <<"branches">> => lists:usort(
                    lists:append([maps:get(<<"branches">>, S) || S <- Ss])
                )
            }
        end,
        maps:groups_from_list(fun(#{<<"path">> := P}) -> P end, GitSources)
    ),
    %% The interactive rebar3 points git at the repositories by these URLs.
    rp_util:ensure_dir(Out),
    rp_util:write_json(filename:join(Out, "git-sources.json"), GitSources),
    Lines = [L || L <- binary:split(Manifest, <<"\n">>, [global]), L =/= <<>>],
    lists:foreach(
        fun(Line) ->
            [Path, Store] = binary:split(Line, <<"\t">>),
            Target = filename:join(Out, Path),
            rp_util:ensure_dir(filename:dirname(Target)),
            case maps:get(Path, Artifacts) of
                #{<<"git">> := #{<<"leaveDotGit">> := true}} ->
                    rp_git:bare_repo(
                        filename:join(Store, ".git"), Target, maps:get(Path, Sources, #{})
                    );
                _ ->
                    ok = file:make_symlink(Store, Target)
            end
        end,
        Lines
    ),
    index(Out).

index(Dir) ->
    HexDir = filename:join(Dir, "hex"),
    rp_util:ensure_dir(HexDir),
    catch ets:delete(package_index),
    package_index = ets:new(package_index, [named_table, public, ordered_set, {keypos, 2}]),
    true = ets:insert(package_index, {?INDEX_VERSION, package_index_version}),
    Repos = [R || R <- list_dir(HexDir), filelib:is_dir(filename:join([HexDir, R, "packages"]))],
    lists:foreach(fun(Repo) -> index_repo(HexDir, Repo) end, Repos),
    ok = ets:tab2file(package_index, filename:join(HexDir, "packages.idx")),
    ok.

index_repo(HexDir, Repo) ->
    Packages = filename:join([HexDir, Repo, "packages"]),
    Tarballs = [F || F <- list_dir(Packages), filename:extension(F) =:= ".tar"],
    lists:foreach(fun(F) -> index_tarball(Packages, Repo, F) end, Tarballs).

index_tarball(Packages, Repo, File) ->
    {ok, Bin} = file:read_file(filename:join(Packages, File)),
    case r3_hex_tarball:unpack(Bin, memory) of
        {ok, #{inner_checksum := Inner, outer_checksum := Outer, metadata := Metadata}} ->
            Name = maps:get(<<"name">>, Metadata),
            Version = maps:get(<<"version">>, Metadata),
            {ok, Parsed} = rebar_semver:parse_version(Version),
            %% The dependencies as rebar_packages:parse_deps/1 makes them
            %% from a registry record: optional ones left out, each named
            %% by its application.
            Requirements = maps:get(<<"requirements">>, Metadata, #{}),
            Dependencies = [
                {
                    maps:get(<<"app">>, R, Dep),
                    {pkg, Dep, maps:get(<<"requirement">>, R), undefined, undefined}
                }
             || Dep := R <- Requirements,
                not maps:get(<<"optional">>, R, false)
            ],
            %% The `package` record of rebar3's rebar.hrl.
            true = ets:insert(package_index, {
                package,
                {Name, Parsed, unicode:characters_to_binary(Repo)},
                checksum(Inner),
                checksum(Outer),
                false,
                lists:sort(Dependencies)
            }),
            Etag = filename:join(Packages, filename:rootname(File) ++ ".etag"),
            ok = file:write_file(Etag, [$", rp_util:hex_md5(Bin), $"]);
        {error, Reason} ->
            rp_util:fail("~ts is not a valid Hex tarball: ~p", [File, Reason])
    end.

%% A checksum as the index holds it: upper-case hexadecimal.
checksum(<<_:256>> = Raw) -> binary:encode_hex(Raw).

list_dir(Dir) ->
    case file:list_dir_all(Dir) of
        {ok, Names} -> lists:sort(Names);
        {error, _} -> []
    end.
