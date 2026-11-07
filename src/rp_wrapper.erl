%% SPDX-License-Identifier: MIT
%%
%% Interactive mode and `rebar3-purifier prefetch`.
%%
%% The flake's rebar3 runs `rebar3-purifier env` and evaluates what it
%% prints before it runs the real rebar3. In a project with a lockfile,
%% that is the environment of the locked downloads: rebar3's cache is a
%% tree of links into the store that holds every locked Hex tarball and
%% the package index of exactly those versions, Hex's default repository
%% points at an address that refuses connections, and git fetches each
%% locked repository from its copy in the store. A lockfile that does not
%% fit the project stops rebar3 with the error of rp_check. In a project
%% without a lockfile it prints nothing, and rebar3 resolves the usual
%% way. REBAR3_PURIFIER_LOCKFILE names a lockfile outside the project.
%%
%% `prefetch` builds the same tree, and keeps it and the toolchain alive
%% with garbage-collector roots in .rebar3-purifier-gcroots beside the
%% lockfile, so that the interactive rebar3 and the editor work afterwards
%% without the network. The interactive rebar3 keeps the tree alive with
%% the same root.
-module(rp_wrapper).

-export([env/0, prefetch/1, quote/1, capture_env/2, environment/3]).

env() ->
    case os:getenv("REBAR3_PURIFIER") of
        "0" ->
            ok;
        _ ->
            {#{lock_file := LockFile} = Project, []} = rp_util:project([]),
            case filelib:is_regular(LockFile) of
                false ->
                    io:format(
                        standard_error,
                        "rebar3-purifier: warning: no rebar3-purifier.lock.json found; running rebar3 impurely. Run `rebar3-purifier lock` to use Nix-resolved dependencies.~n",
                        []
                    );
                true ->
                    rp_check:current(Project),
                    {Tree, Cache} = prepare(Project),
                    {ok, Sources} = file:read_file(filename:join(Tree, "git-sources.json")),
                    print(Tree, Cache, json:decode(Sources))
            end
    end.

prefetch(Args) ->
    {#{root := Root, gc_roots := Roots} = Project, Rest} = rp_util:project(Args),
    Rest =:= [] orelse rp_util:fail("unexpected arguments: ~ts", [lists:join(" ", Rest)]),
    rp_check:current(Project),
    {Tree, _} = prepare(Project),
    Toolchain = env_var("REBAR3_PURIFIER_TOOLCHAIN"),
    Link = filename:join(Roots, "toolchain"),
    case rp_util:run_quiet("nix-store", ["--realise", Toolchain, "--add-root", Link], Root, []) of
        {0, _} ->
            ok;
        {Status, Out} ->
            rp_util:fail("keeping the toolchain alive failed with exit status ~b:~n~ts", [
                Status, Out
            ])
    end,
    io:format(
        "prefetched the locked downloads into ~ts, and the toolchain ~ts; "
        "the garbage-collector roots are in ~ts~n",
        [Tree, Toolchain, Roots]
    ).

%% Builds the cache tree and its writable copy under _build.
prepare(#{root := Root} = Project) ->
    Tree = realize(Project),
    Cache = filename:join([Root, "_build", "rebar3-purifier", "cache"]),
    mirror(Tree, Cache),
    {Tree, Cache}.

%% Capture still runs native rebar3 in a clean project and writable cache.
%% Reuse exactly the same recorded index and git mapping as offline replay.
%% A materialization failure propagates; it must not resolve newer downloads.
capture_env(Project, Cache) ->
    Tree = realize(Project),
    mirror(Tree, Cache),
    {ok, Sources} = file:read_file(filename:join(Tree, "git-sources.json")),
    environment(Tree, Cache, json:decode(Sources)).

%% Builds the cache tree of the lockfile through Nix, with one GC root
%% under _build/rebar3-purifier, and returns its store path.
realize(#{
    root := Root,
    lock_file := LockFile,
    rebar_lock := RebarLock,
    tree_rebar_lock := InTree,
    gc_roots := Roots
}) ->
    Link = filename:join(Roots, "cache"),
    rp_util:ensure_dir(Roots),
    RebarLockArgs =
        case RebarLock =:= InTree of
            true -> [];
            false -> ["--arg", "rebarLock", RebarLock]
        end,
    Args =
        RebarLockArgs ++
            [
                filename:join(env_var("REBAR3_PURIFIER_NIX_LIB"), "realize.nix"),
                "--arg",
                "src",
                Root,
                "--arg",
                "lockFile",
                LockFile,
                "--argstr",
                "cli",
                env_var("REBAR3_PURIFIER_CLI"),
                "--arg",
                "nixpkgs",
                env_var("REBAR3_PURIFIER_NIXPKGS"),
                "--argstr",
                "purifierSrc",
                env_var("REBAR3_PURIFIER_PURIFIER_SRC"),
                "--out-link",
                Link
            ],
    case rp_util:run_quiet("nix-build", Args, Root, []) of
        {0, _} ->
            {ok, Tree} = file:read_link_all(Link),
            Tree;
        {Status, Out} ->
            rp_util:fail("building the locked downloads failed with exit status ~b:~n~ts", [
                Status, Out
            ])
    end.

env_var(Name) ->
    case os:getenv(Name) of
        false ->
            rp_util:fail("~ts is not set; run rebar3 through the rebar3-purifier toolchain", [Name]);
        Value ->
            Value
    end.

%% rebar3 writes into its cache, so the cache is a writable tree with the
%% same layout: links to the tarballs, and copies of the index and etags,
%% which rebar3 may rewrite. git fetches from the repositories in the store
%% tree. A marker records the store path the tree mirrors.
mirror(Tree, Cache) ->
    Marker = filename:join(Cache, ".rebar3-purifier-tree"),
    TreeBin = list_to_binary(Tree),
    case file:read_file(Marker) of
        {ok, TreeBin} ->
            ok;
        _ ->
            rp_util:rm_rf(Cache),
            rp_util:ensure_dir(Cache),
            HexTree = filename:join(Tree, "hex"),
            lists:foreach(
                fun(Rel) ->
                    From = filename:join(HexTree, Rel),
                    To = filename:join([Cache, "hex", Rel]),
                    rp_util:ensure_dir(filename:dirname(To)),
                    case filename:extension(Rel) of
                        ".tar" ->
                            {ok, Target} = file:read_link_all(From),
                            ok = file:make_symlink(Target, To);
                        _ ->
                            {ok, _} = file:copy(From, To),
                            ok = file:change_mode(To, 8#644)
                    end
                end,
                rp_util:walk(HexTree)
            ),
            ok = file:write_file(Marker, Tree)
    end.

print(Tree, Cache, GitSources) ->
    io:put_chars([export(Name, Value) || {Name, Value} <- environment(Tree, Cache, GitSources)]),
    ok.

environment(Tree, Cache, GitSources) ->
    Count =
        case os:getenv("GIT_CONFIG_COUNT") of
            false -> 0;
            N -> list_to_integer(N)
        end,
    GitConfig =
        [{"safe.directory", "*"}] ++
            [
                {
                    "url." ++ filename:join(Tree, binary_to_list(P)) ++ ".insteadOf",
                    binary_to_list(U)
                }
             || #{<<"url">> := U, <<"path">> := P} <- GitSources
            ],
    [
        {"REBAR_CACHE_DIR", Cache},
        %% Port 9 (discard) refuses connections, so Hex's default
        %% repository fails at once and rebar3 takes the cached tarball.
        {"HEX_CDN", "http://127.0.0.1:9"},
        {"GIT_CONFIG_COUNT", integer_to_list(Count + length(GitConfig))}
    ] ++
        lists:append([
            [
                {"GIT_CONFIG_KEY_" ++ integer_to_list(Count + I - 1), K},
                {"GIT_CONFIG_VALUE_" ++ integer_to_list(Count + I - 1), V}
            ]
         || {I, {K, V}} <- lists:enumerate(GitConfig)
        ]).

export(Name, Value) ->
    ["export ", Name, "=", quote(Value), "\n"].

%% A shell word that stands for Value.
quote(Value) ->
    [$', string:replace(Value, "'", "'\\''", all), $'].
