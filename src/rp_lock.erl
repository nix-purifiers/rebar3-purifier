%% SPDX-License-Identifier: MIT
%%
%% The lock run of `rebar3-purifier lock` and `rebar3-purifier update`. It
%% copies the build to _build/rebar3-purifier/lock-run, runs rebar3 there
%% with an empty home, once per locked profile, and records the native
%% downloads and what the build
%% produces in rebar3-purifier.lock.json. `lock` keeps the resolution of
%% rebar.lock, to which rebar3 adds only what is missing. `update` first
%% runs `rebar3 upgrade` on every dependency, or on the named ones. First
%% captures and updates resolve online; unchanged normal relocks replay
%% the recorded native cache and index so plugin selections stay pinned.
-module(rp_lock).

-export([
    lock/1, update/1, repo_url/2, global_config_dir/0, https_url/1, hex_entries/2, capture_mode/3
]).

-define(DEFAULT_PROFILES, ["default", "test", "prod"]).

lock(Args) ->
    {Project, Rest} = rp_util:project(Args),
    {Profiles, []} = options(Rest, [], []),
    write_lock(Project, Profiles, none).

update(Args) ->
    {Project, Rest} = rp_util:project(Args),
    {Profiles, Packages} = options(Rest, [], []),
    write_lock(
        Project,
        Profiles,
        case Packages of
            [] -> all;
            _ -> Packages
        end
    ).

%% The profiles to lock besides the default ones, and the package names.
options(["--profile", P | Rest], Profiles, Packages) ->
    options(Rest, [P | Profiles], Packages);
options(["-" ++ _ = Option | _], _, _) ->
    rp_util:fail("unknown option ~ts", [Option]);
options([Package | Rest], Profiles, Packages) ->
    options(Rest, Profiles, [Package | Packages]);
options([], Profiles, Packages) ->
    {lists:usort(?DEFAULT_PROFILES ++ Profiles), lists:reverse(Packages)}.

write_lock(#{root := Root, lock_file := LockFile, rebar_lock := RebarLock} = P, Profiles, Upgrade) ->
    filelib:is_regular(filename:join(Root, "rebar.config")) orelse
        rp_util:fail("no rebar.config in ~ts", [Root]),
    Mode = capture_mode(P, Profiles, Upgrade),
    Work = filename:join([Root, "_build", "rebar3-purifier", "lock-run"]),
    Project = filename:join(Work, "project"),
    Cache = filename:join(Work, "cache"),
    rp_util:rm_rf(Work),
    rp_util:ensure_dir(Project),
    copy_project(Root, Project),
    case filelib:is_regular(RebarLock) of
        true -> {ok, _} = file:copy(RebarLock, filename:join(Project, "rebar.lock"));
        false -> ok
    end,
    CacheEnv =
        case Mode of
            fresh -> [{"REBAR_CACHE_DIR", Cache}];
            replay -> rp_wrapper:capture_env(P, Cache)
        end,
    Env =
        [
            {"HOME", filename:join(Work, "home")},
            %% The user's global rebar3 configuration stays in effect, for the
            %% Hex repositories and credentials it may hold.
            {"REBAR_GLOBAL_CONFIG_DIR", global_config_dir()}
        ] ++ CacheEnv,
    case Upgrade of
        none -> ok;
        all -> rebar3(["upgrade", "--all"], Project, Env);
        Packages -> rebar3(["upgrade", lists:join(",", Packages)], Project, Env)
    end,
    lists:foreach(
        fun
            ("default") -> rebar3(["compile"], Project, Env);
            (Profile) -> rebar3(["as", Profile, "compile"], Project, Env)
        end,
        Profiles
    ),
    update_rebar_lock(RebarLock, Project),
    Config = rp_util:consult(filename:join(Root, "rebar.config")),
    Tarballs = hex_entries(Cache, Config),
    {GitEntries, GitSources} = git_entries(Project),
    Files = rp_util:definition_files(Root, RebarLock),
    Lock = #{
        version => rp_util:lock_version(),
        rebar3Version => rebar3_version(Project),
        otpRelease => list_to_binary(erlang:system_info(otp_release)),
        profiles => [list_to_binary(Profile) || Profile <- Profiles],
        definitionFiles => [list_to_binary(F) || F <- Files],
        definitionHash => rp_util:definition_hash(P, Files),
        %% The Hex tarballs that rebar.lock does not supply: plugins,
        %% dependencies of profiles, and packages from other repositories.
        hexTarballs => sort_by(path, Tarballs -- rp_util:derived_hex(RebarLock)),
        git => sort_by(rev, [
            git_record(E, GitSources, rp_util:locked_git(RebarLock))
         || E <- GitEntries
        ]),
        outputs => outputs(Root, Project, Config)
    },
    add_private_tarballs(Cache, Tarballs),
    rp_util:ensure_dir(filename:dirname(LockFile)),
    rp_util:write_lock(LockFile, Lock),
    io:format("wrote ~ts~n", [LockFile]).

%% A native rebar.lock does not pin plugins. An unchanged normal relock
%% therefore needs the recorded index, tarballs and git sources as well.
%% Validate an existing lock even for update: corrupted pins never select
%% an online fallback. Only absent or legitimately changed inputs are fresh.
capture_mode(
    #{root := Root, lock_file := LockFile, rebar_lock := RebarLock} = P, Profiles, Upgrade
) ->
    case rp_util:read_lock(LockFile) of
        {error, enoent} ->
            fresh;
        {ok, Lock} ->
            Files = rp_util:definition_files(Root, RebarLock),
            Unchanged = maps:get(<<"definitionHash">>, Lock) =:= rp_util:definition_hash(P, Files),
            SameProfiles =
                maps:get(<<"profiles">>, Lock) =:= [list_to_binary(Profile) || Profile <- Profiles],
            case Upgrade =:= none andalso Unchanged andalso SameProfiles of
                true ->
                    rp_check:current(P),
                    replay;
                false ->
                    fresh
            end
    end.

rebar3(Args, Project, Env) ->
    Line = lists:flatten(lists:join(" ", Args)),
    io:format(standard_error, "rebar3-purifier: rebar3 ~ts~n", [Line]),
    case rp_util:run("rebar3", Args, Project, Env) of
        {0, _} -> ok;
        {Status, _} -> rp_util:fail("rebar3 ~ts failed with exit status ~b", [Line, Status])
    end.

copy_project(Root, Project) ->
    {ok, Names} = file:list_dir_all(Root),
    lists:foreach(
        fun(N) ->
            {0, _} = rp_util:run_quiet("cp", ["-a", filename:join(Root, N), Project], Root, [])
        end,
        [N || N <- Names, N =/= "_build"]
    ).

%% When the lock run resolved dependencies rebar.lock did not hold, the
%% build needs that resolution, so it goes to the rebar.lock the project
%% uses: the one in the tree, or the one that `--tool-lockfile` names.
update_rebar_lock(RebarLock, Project) ->
    New = filename:join(Project, "rebar.lock"),
    case {file:read_file(New), file:read_file(RebarLock)} of
        {{ok, Same}, {ok, Same}} ->
            ok;
        {{ok, Bin}, _} ->
            rp_util:ensure_dir(filename:dirname(RebarLock)),
            ok = file:write_file(RebarLock, Bin),
            io:format(
                standard_error,
                "rebar3-purifier: updated ~ts; commit it with the lockfile~n",
                [RebarLock]
            );
        {{error, enoent}, _} ->
            ok
    end.

%% The directory rebar3 reads the global configuration under, as it was
%% before the lock run replaced HOME.
global_config_dir() ->
    case os:getenv("REBAR_GLOBAL_CONFIG_DIR") of
        false ->
            case os:getenv("HOME") of
                false -> rp_util:fail("HOME is not set", []);
                Home -> Home
            end;
        Dir ->
            Dir
    end.

rebar3_version(Project) ->
    {0, Out} = rp_util:run_quiet("rebar3", ["version"], Project, []),
    case re:run(Out, "rebar ([^ \n]+)", [{capture, all_but_first, binary}]) of
        {match, [V]} -> V;
        nomatch -> <<"unknown">>
    end.

%% Hex tarballs

%% A file entry per tarball in the cache: the tarball at its path in the
%% rebar3 cache, at the tarball URL of its repository.
hex_entries(Cache, Config) ->
    HexDir = filename:join(Cache, "hex"),
    lists:append([
        [
            #{
                path => list_to_binary(filename:join(["hex", Repo, "packages", File])),
                url => <<
                    (repo_url(Repo, Config))/binary, "/tarballs/", (list_to_binary(File))/binary
                >>,
                mirrors => [],
                hash => rp_util:sri_sha256(
                    element(
                        2,
                        {ok, _} = file:read_file(
                            filename:join([HexDir, Repo, "packages", File])
                        )
                    )
                )
            }
         || File <- lists:sort(filelib:wildcard("*.tar", filename:join([HexDir, Repo, "packages"])))
        ]
     || Repo <- lists:sort(filelib:wildcard("*", HexDir)),
        filelib:is_dir(filename:join([HexDir, Repo, "packages"]))
    ]).

%% The URL of a Hex repository, as rebar3 would fetch from it: hexpm (or
%% HEX_CDN, a mirror of it), an organization of hexpm, or a repository the
%% project's or the user's rebar.config names under `hex`.
repo_url("hexpm", _) ->
    case os:getenv("HEX_CDN") of
        false ->
            case os:getenv("HEX_MIRROR") of
                false -> <<"https://repo.hex.pm">>;
                "" -> <<"https://repo.hex.pm">>;
                M -> trim_slash(M)
            end;
        "" ->
            <<"https://repo.hex.pm">>;
        Cdn ->
            trim_slash(Cdn)
    end;
repo_url("hexpm:" ++ Org, Config) ->
    <<(repo_url("hexpm", Config))/binary, "/repos/", (list_to_binary(Org))/binary>>;
repo_url(Repo, Config) ->
    Global = rp_util:consult(
        filename:join([global_config_dir(), ".config", "rebar3", "rebar.config"])
    ),
    Name = list_to_binary(Repo),
    Repos = [R || C <- [Config, Global], R <- hex_repos(C), maps:get(name, R, undefined) =:= Name],
    case Repos of
        [#{repo_url := Url} | _] -> trim_slash(Url);
        _ -> rp_util:fail("the Hex repository ~ts has no repo_url in rebar.config", [Repo])
    end.

hex_repos(Config) ->
    Hex = proplists:get_value(hex, Config, []),
    lists:append([Rs || {repos, Rs} <- Hex] ++ [Rs || {repos, replace, Rs} <- Hex]).

trim_slash(Url) ->
    string:trim(rp_util:to_bin(Url), trailing, "/").

%% Tarballs from repositories other than hexpm may need credentials, which
%% Nix's fetcher does not have. The lock run downloaded them with the
%% user's credentials, so it adds them to the store, where the build finds
%% them under the same fixed-output path.
add_private_tarballs(Cache, Tarballs) ->
    lists:foreach(
        fun(#{path := Path}) ->
            File = filename:join(Cache, Path),
            rp_util:run_quiet("nix-store", ["--add-fixed", "sha256", File], Cache, [])
        end,
        [T || T = #{path := P} <- Tarballs, not lists:prefix("hex/hexpm/", binary_to_list(P))]
    ).

%% Git dependencies

%% A git entry per repository rebar3 cloned, at the commit it checked out,
%% as a plain checkout. rebar3 does not check out submodules. An SSH URL is
%% recorded as the HTTPS URL of the same host, since the Nix sandbox has no
%% SSH keys, and gitSources maps the URL rebar3 uses to the entry.
git_entries(Project) ->
    Dirs = [
        D
     || Pattern <- ["_build/*/lib/*", "_build/*/plugins/*"],
        D <- filelib:wildcard(Pattern, Project),
        filelib:is_dir(filename:join([Project, D, ".git"]))
    ],
    %% A git_subdir dependency is copied out of its clone without .git, so
    %% rebar.lock is where its repository and commit are.
    Subdirs = [
        {Url, Rev, [], []}
     || {_, {git_subdir, Url, {ref, Rev}, _}, _} <- rebar_lock_deps(Project)
    ],
    Repos = lists:usort([git_repo(filename:join(Project, D)) || D <- Dirs] ++ Subdirs),
    %% The build rebuilds a repository from each plain checkout, with the
    %% raw commit object the entry records and the submodule entries of
    %% its tree; see rp_git.
    Commits = maps:from_list([
        {R, rp_git:commit_info(https_url(U), R)}
     || {U, R} <- lists:usort([{U, R} || {U, R, _, _} <- Repos])
    ]),
    Entries = [
        git_entry(Url, Rev, maps:get(Rev, Commits))
     || {Url, Rev} <- lists:usort([{https_url(U), R} || {U, R, _, _} <- Repos])
    ],
    %% rebar3 clones a branch or a tag with `git clone -b`, so the clone
    %% it fetches from needs the names it asks for. Each source records the
    %% tags at its commit and the branch rebar3 checked out.
    Grouped = maps:groups_from_list(
        fun({U, R, _, _}) -> {U, R} end,
        fun({_, _, Tags, Branches}) -> {Tags, Branches} end,
        Repos
    ),
    Sources = [
        #{
            url => list_to_binary(U),
            path => <<"git/", (list_to_binary(R))/binary>>,
            tags => lists:usort([list_to_binary(T) || {Ts, _} <- Refs, T <- Ts]),
            branches => lists:usort([list_to_binary(B) || {_, Bs} <- Refs, B <- Bs])
        }
     || {U, R} := Refs <- maps:iterator(Grouped, ordered)
    ],
    {Entries, Sources}.

rebar_lock_deps(Project) ->
    element(1, rp_util:rebar_lock(filename:join(Project, "rebar.lock"))).

git_repo(Dir) ->
    Url = git_line(Dir, ["config", "--get", "remote.origin.url"]),
    Rev = git_line(Dir, ["rev-parse", "HEAD"]),
    Tags = string:lexemes(git_out(Dir, ["tag", "--points-at", "HEAD"]), "\n"),
    Branches = [B || B <- [git_line(Dir, ["rev-parse", "--abbrev-ref", "HEAD"])], B =/= "HEAD"],
    {Url, Rev, Tags, Branches}.

git_line(Dir, Args) ->
    string:trim(git_out(Dir, Args)).

git_out(Dir, Args) ->
    {0, Out} = rp_util:run_quiet("git", Args, Dir, []),
    binary_to_list(Out).

%% A git entry of the shared library's shape. `hash` is of the plain
%% checkout, and `leaveDotGit` with `commitObject` asks for the .git
%% directory rebuilt from it: `object` is the raw commit object, base64,
%% and `gitlinks` the submodule entries of its tree.
git_entry(Url, Rev, {Object, Gitlinks}) ->
    io:format(standard_error, "rebar3-purifier: hashing ~ts at ~ts~n", [Url, Rev]),
    {ok, Cwd} = file:get_cwd(),
    case rp_util:run_quiet("nix-prefetch-git", ["--url", Url, "--rev", Rev, "--quiet"], Cwd, []) of
        {0, Out} ->
            #{<<"hash">> := Hash} = json:decode(Out),
            #{
                path => <<"git/", (list_to_binary(Rev))/binary>>,
                git => #{
                    url => list_to_binary(Url),
                    rev => list_to_binary(Rev),
                    submodules => false,
                    leaveDotGit => true,
                    commitObject => #{object => Object, gitlinks => Gitlinks}
                },
                hash => Hash
            };
        {Status, Out} ->
            rp_util:fail("nix-prefetch-git ~ts failed with exit status ~b:~n~ts", [Url, Status, Out])
    end.

%% What the lockfile records of a checkout: the commit, the hash of the
%% plain checkout and the commit object, none of which rebar.lock holds.
%% `url`, the HTTPS URL that Nix fetches from, is there when rebar.lock
%% does not name the commit at that URL. `sources` lists the URLs that
%% rebar3 clones the commit from, with the tags and branches it clones by,
%% except the URL rebar.lock names, from which rebar3 fetches the commit
%% itself.
git_record(
    #{git := #{url := Url, rev := Rev, commitObject := Object}, hash := Hash}, Sources, Locked
) ->
    LockedUrls = [U || {U, R} <- Locked, R =:= Rev],
    Path = <<"git/", Rev/binary>>,
    Record = #{
        rev => Rev,
        hash => Hash,
        commitObject => Object,
        sources => [
            maps:with([url, tags, branches], S)
         || S = #{path := P, url := U} <- Sources,
            P =:= Path,
            not lists:member(U, LockedUrls)
        ]
    },
    case lists:member(Url, LockedUrls) of
        true -> Record;
        false -> Record#{url => Url}
    end.

sort_by(Key, Maps) ->
    lists:sort(fun(A, B) -> maps:get(Key, A) =< maps:get(Key, B) end, Maps).

https_url("git@" ++ Rest) ->
    case string:split(Rest, ":") of
        [Host, Path] -> "https://" ++ Host ++ "/" ++ Path;
        _ -> "git@" ++ Rest
    end;
https_url("ssh://" ++ Rest) ->
    HostPath =
        case string:split(Rest, "@") of
            [_User, HP] -> HP;
            [HP] -> HP
        end,
    [Host | Path] = string:split(HostPath, "/"),
    HostNoPort = hd(string:split(Host, ":")),
    "https://" ++ HostNoPort ++ "/" ++ lists:flatten(Path);
https_url("git://" ++ Rest) ->
    "https://" ++ Rest;
https_url(Url) ->
    Url.

%% Outputs

outputs(Root, Project, Config) ->
    Apps = [app(Root, Project, Dir) || Dir <- rp_util:app_dirs(Root)],
    Plugins = [
        plugin_name(P)
     || Key <- [plugins, project_plugins],
        P <- proplists:get_value(Key, Config, [])
    ],
    #{
        apps => Apps,
        releases => releases(Config),
        escripts => escripts(Config),
        hexPackages =>
            case lists:member(rebar3_hex, Plugins) of
                true -> [maps:with([name, version], A) || A <- Apps];
                false -> []
            end
    }.

app(Root, Project, Dir) ->
    [Src] = filelib:wildcard("src/*.app.src", filename:join(Root, Dir)),
    Name = filename:basename(Src, ".app.src"),
    AppFile = filename:join([Project, "_build", "default", "lib", Name, "ebin", Name ++ ".app"]),
    Version =
        case file:consult(AppFile) of
            {ok, [{application, _, Props}]} -> rp_util:to_bin(proplists:get_value(vsn, Props, ""));
            _ -> rp_util:fail("rebar3 compile wrote no ~ts", [AppFile])
        end,
    #{name => list_to_binary(Name), version => Version, dir => list_to_binary(Dir)}.

plugin_name(P) when is_atom(P) -> P;
plugin_name(P) when is_tuple(P) -> element(1, P).

%% The names of the relx releases of the default and prod profiles.
releases(Config) ->
    Profiles = proplists:get_value(profiles, Config, []),
    Relx =
        proplists:get_value(relx, Config, []) ++
            proplists:get_value(relx, proplists:get_value(prod, Profiles, []), []),
    lists:usort([
        rp_util:to_bin(Name)
     || R <- Relx,
        element(1, R) =:= release,
        {Name, _} <- [element(2, R)]
    ]).

%% The escript, when rebar.config names it or its main application.
escripts(Config) ->
    case
        {proplists:get_value(escript_name, Config), proplists:get_value(escript_main_app, Config)}
    of
        {undefined, undefined} -> [];
        {undefined, Main} -> [rp_util:to_bin(Main)];
        {Name, _} -> [rp_util:to_bin(Name)]
    end.
