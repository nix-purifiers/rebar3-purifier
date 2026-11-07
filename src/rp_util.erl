%% SPDX-License-Identifier: MIT
%%
%% What the commands share: running programs, the lockfile and its JSON,
%% hashes, and the files that define a build's dependencies.
-module(rp_util).

-include_lib("kernel/include/file.hrl").

-export([
    fail/2,
    run/4,
    run_quiet/4,
    find_executable/1,
    sri_sha256/1,
    hex_md5/1,
    lock_version/0,
    lock_file/1,
    project/1,
    read_lock/1,
    write_lock/2,
    content_hash/1,
    write_json/2,
    definition_files/2,
    definition_hash/2,
    consult/1,
    app_dirs/1,
    ensure_dir/1,
    rm_rf/1,
    walk/1,
    rebar_lock/1,
    hex_dep/1,
    derived_hex/1,
    locked_git/1,
    locked_git_dep/1,
    to_bin/1
]).

%% The lock format this command writes and nix/lib reads. nix/lib/
%% lock-version.nix holds the same number.
lock_version() -> 2.

lock_file(Root) -> filename:join(Root, "rebar3-purifier.lock.json").

%% The project a command works on, from its arguments: the current
%% directory, the lockfile that `--lockfile PATH` names, or else
%% REBAR3_PURIFIER_LOCKFILE, or else the one in the project, and the
%% rebar.lock that `--tool-lockfile PATH` names, or else
%% REBAR3_PURIFIER_TOOL_LOCKFILE, or else the one in the project. With
%% `--tool-lockfile`, `lock` and `update` write rebar.lock there and leave
%% the one in the project as it is, and `lock` starts from the one in the
%% project while the other does not exist. The garbage-collector roots of
%% `prefetch` and of the interactive rebar3 lie beside the lockfile.
%% Returns the project and the other arguments.
project(Args) ->
    {ok, Root} = file:get_cwd(),
    {LockFile, Rest1} = path_option(
        Args, "--lockfile", "REBAR3_PURIFIER_LOCKFILE", lock_file(Root)
    ),
    InTree = filename:join(Root, "rebar.lock"),
    {RebarLock, Rest} = path_option(
        Rest1, "--tool-lockfile", "REBAR3_PURIFIER_TOOL_LOCKFILE", InTree
    ),
    {
        #{
            root => Root,
            lock_file => LockFile,
            rebar_lock => RebarLock,
            tree_rebar_lock => InTree,
            gc_roots => filename:join(filename:dirname(LockFile), ".rebar3-purifier-gcroots")
        },
        Rest
    }.

%% The absolute path that the option Option names in Args, or else the
%% environment variable Var, or else Default, and the other arguments.
path_option(Args, Option, Var, Default) ->
    case lists:splitwith(fun(A) -> A =/= Option end, Args) of
        {Before, [Option, Path | After]} ->
            {filename:absname(Path), Before ++ After};
        {_, [Option]} ->
            fail("~ts needs a path", [Option]);
        {_, []} ->
            case os:getenv(Var) of
                Env when Env =:= false; Env =:= "" -> {Default, Args};
                Env -> {filename:absname(Env), Args}
            end
    end.

-spec fail(io:format(), [term()]) -> no_return().
fail(Format, Args) ->
    throw({fail, io_lib:format(Format, Args)}).

%% rebar3 itself. The toolchain's `rebar3` is the interactive wrapper, so
%% the toolchain names the real one in REBAR3_PURIFIER_REBAR3.
find_executable("rebar3") ->
    case os:getenv("REBAR3_PURIFIER_REBAR3") of
        false -> find_on_path("rebar3");
        Path -> Path
    end;
find_executable(Name) ->
    find_on_path(Name).

find_on_path(Name) ->
    case os:find_executable(Name) of
        false -> fail("~ts is not on the PATH", [Name]);
        Path -> Path
    end.

%% Runs Program with Args in Dir, with Env added to the environment, and
%% copies its output to standard error as it comes. Returns the exit
%% status and the output.
run(Program, Args, Dir, Env) -> run(Program, Args, Dir, Env, true).

%% The same, without copying the output.
run_quiet(Program, Args, Dir, Env) -> run(Program, Args, Dir, Env, false).

run(Program, Args, Dir, Env, Echo) ->
    Port = open_port(
        {spawn_executable, find_executable(Program)},
        [
            {args, Args},
            {cd, Dir},
            {env, [{K, V} || {K, V} <- Env]},
            exit_status,
            stderr_to_stdout,
            binary,
            stream
        ]
    ),
    collect(Port, Echo, []).

collect(Port, Echo, Acc) ->
    receive
        {Port, {data, Data}} ->
            Echo andalso io:put_chars(standard_error, Data),
            collect(Port, Echo, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    end.

sri_sha256(Bin) ->
    <<"sha256-", (base64:encode(crypto:hash(sha256, Bin)))/binary>>.

hex_md5(Bin) ->
    string:lowercase(binary:encode_hex(crypto:hash(md5, Bin))).

read_lock(File) ->
    case file:read_file(File) of
        {ok, Bin} ->
            Current = lock_version(),
            Lock =
                try
                    json:decode(Bin)
                catch
                    error:_ ->
                        fail(
                            "~ts is not valid JSON; restore a valid lockfile or move this "
                            "file aside before running `rebar3-purifier lock`",
                            [File]
                        )
                end,
            case Lock of
                #{<<"version">> := Current} ->
                    maps:get(<<"contentHash">>, Lock, none) =:= content_hash(Lock) orelse
                        fail(
                            "~ts does not match its contentHash, so it was changed after "
                            "`rebar3-purifier lock` wrote it; restore a valid lockfile or move "
                            "this file aside before running `rebar3-purifier lock`",
                            [File]
                        ),
                    {ok, Lock};
                #{<<"version">> := Other} ->
                    fail(
                        "~ts has lock format version ~p, and this rebar3-purifier reads "
                        "version ~b; restore a valid lockfile or move this file aside "
                        "before running `rebar3-purifier lock`",
                        [File, Other, Current]
                    );
                _ ->
                    fail(
                        "~ts is not a rebar3-purifier lockfile; restore a valid lockfile "
                        "or move this file aside before running `rebar3-purifier lock`",
                        [
                            File
                        ]
                    )
            end;
        {error, enoent} ->
            {error, enoent}
    end.

%% Writes Lock with its contentHash.
write_lock(File, Lock) ->
    write_json(File, Lock#{contentHash => content_hash(Lock)}).

%% The hash of a lockfile's content: the SHA-256 of the lockfile without
%% its contentHash, as Nix's builtins.toJSON writes it, with sorted keys
%% and no whitespace. nix/lib/lock.nix computes the same hash.
content_hash(Lock) ->
    sri_sha256(iolist_to_binary(nix_json(maps:without([contentHash, <<"contentHash">>], Lock)))).

nix_json(Map) when is_map(Map) ->
    Pairs = lists:sort([{to_bin(K), V} || K := V <- Map]),
    ["{", lists:join(",", [[nix_string(K), ":", nix_json(V)] || {K, V} <- Pairs]), "}"];
nix_json(List) when is_list(List) ->
    ["[", lists:join(",", [nix_json(V) || V <- List]), "]"];
nix_json(true) ->
    "true";
nix_json(false) ->
    "false";
nix_json(null) ->
    "null";
nix_json(Int) when is_integer(Int) ->
    integer_to_list(Int);
nix_json(Bin) when is_binary(Bin) ->
    nix_string(Bin);
nix_json(Atom) when is_atom(Atom) ->
    nix_string(atom_to_binary(Atom)).

%% A JSON string with the escapes Nix's builtins.toJSON writes.
nix_string(Bin) ->
    [$", [escape(C) || <<C>> <= Bin], $"].

escape($") -> "\\\"";
escape($\\) -> "\\\\";
escape($\b) -> "\\b";
escape($\f) -> "\\f";
escape($\n) -> "\\n";
escape($\r) -> "\\r";
escape($\t) -> "\\t";
escape(C) when C < 16#20 -> io_lib:format("\\u~4.16.0b", [C]);
escape(C) -> C.

%% Writes Term as JSON, with object keys sorted, two-space indentation and
%% a final newline, so a relock that finds the same downloads writes the
%% same bytes.
write_json(File, Term) ->
    ok = file:write_file(File, [encode(Term, 0), $\n]).

encode(Map, _) when is_map(Map), map_size(Map) =:= 0 -> "{}";
encode(Map, Indent) when is_map(Map) ->
    Pad = pad(Indent + 1),
    Keys = lists:sort([to_bin(K) || K <- maps:keys(Map)]),
    Lookup = maps:from_list([{to_bin(K), V} || K := V <- Map]),
    Items = [
        [Pad, json:encode(K), ": ", encode(maps:get(K, Lookup), Indent + 1)]
     || K <- Keys
    ],
    ["{\n", lists:join(",\n", Items), "\n", pad(Indent), "}"];
encode([], _) ->
    "[]";
encode(List, Indent) when is_list(List) ->
    Pad = pad(Indent + 1),
    Items = [[Pad, encode(V, Indent + 1)] || V <- List],
    ["[\n", lists:join(",\n", Items), "\n", pad(Indent), "]"];
encode(Value, _) ->
    json:encode(Value).

pad(N) -> lists:duplicate(2 * N, $\s).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I).

%% The files that define the build's dependencies: rebar.config, its
%% script, rebar.lock, and the rebar.config of every application, as paths
%% relative to Root, sorted. RebarLock is the path of rebar.lock in Root.
definition_files(Root, RebarLock) ->
    Top = [
        F
     || F <- ["rebar.config", "rebar.config.script"],
        filelib:is_regular(filename:join(Root, F))
    ],
    Lock = ["rebar.lock" || filelib:is_regular(RebarLock)],
    Apps = [
        F
     || Dir <- app_dirs(Root),
        Dir =/= ".",
        Name <- ["rebar.config", "rebar.config.script"],
        F <- [filename:join(Dir, Name)],
        filelib:is_regular(filename:join(Root, F))
    ],
    lists:usort(Top ++ Lock ++ Apps).

%% The hash of the definition files of the project: the SHA-256 of one
%% line per file, its path, a tab and the hexadecimal SHA-256 of its
%% content. nix/lib/lock.nix computes the same hash.
definition_hash(#{root := Root, rebar_lock := RebarLock}, Files) ->
    Lines = [
        [F, $\t, sha256_hex(definition_path(Root, RebarLock, F)), $\n]
     || F <- Files
    ],
    sri_sha256(iolist_to_binary(Lines)).

definition_path(_, RebarLock, "rebar.lock") -> RebarLock;
definition_path(Root, _, F) -> filename:join(Root, F).

sha256_hex(File) ->
    {ok, Bin} = file:read_file(File),
    string:lowercase(binary:encode_hex(crypto:hash(sha256, Bin))).

consult(File) ->
    case file:consult(File) of
        {ok, Terms} -> Terms;
        {error, enoent} -> [];
        {error, Reason} -> fail("cannot read ~ts: ~p", [File, Reason])
    end.

%% The directories of the project's own applications, relative to Root:
%% "." for an application at the root, and each directory under apps/ or
%% lib/ that holds a src/*.app.src, as rebar3's default lib_dirs find them.
app_dirs(Root) ->
    Root1 = ["." || filelib:wildcard("src/*.app.src", Root) =/= []],
    Nested = lists:usort(
        [
            filename:dirname(filename:dirname(F))
         || Pattern <- ["apps/*/src/*.app.src", "lib/*/src/*.app.src"],
            F <- filelib:wildcard(Pattern, Root)
        ]
    ),
    Root1 ++ Nested.

ensure_dir(Dir) ->
    ok = filelib:ensure_path(Dir).

rm_rf(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            ok = make_writable(Path),
            {ok, Names} = file:list_dir_all(Path),
            [rm_rf(filename:join(Path, N)) || N <- Names],
            ok = file:del_dir(Path);
        {ok, _} ->
            ok = file:delete(Path);
        {error, enoent} ->
            ok
    end.

make_writable(Dir) ->
    {ok, #file_info{mode = Mode}} = file:read_file_info(Dir),
    file:change_mode(Dir, Mode bor 8#700).

%% Every regular file and symbolic link under Dir, relative to it, sorted.
walk(Dir) ->
    lists:sort(walk(Dir, "")).

walk(Base, Rel) ->
    Path = filename:join(Base, Rel),
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            {ok, Names} = file:list_dir_all(Path),
            lists:append([walk(Base, join(Rel, N)) || N <- Names]);
        {ok, _} ->
            [Rel];
        {error, _} ->
            []
    end.

join("", N) -> N;
join(R, N) -> filename:join(R, N).

%% The dependencies in a rebar.lock and the outer checksums of its Hex
%% packages, by dependency name. The outer checksum is the SHA-256 of the
%% package tarball. rebar.lock has two formats: a list of dependencies,
%% and since rebar3 3.5 a version with the list, followed by the
%% checksums.
rebar_lock(File) ->
    case consult(File) of
        [{_Version, Deps} | Rest] when is_list(Deps) ->
            Ext =
                case Rest of
                    [Attrs | _] when is_list(Attrs) ->
                        maps:from_list(proplists:get_value(pkg_hash_ext, Attrs, []));
                    _ ->
                        #{}
                end,
            {Deps, Ext};
        [Deps] when is_list(Deps) ->
            {Deps, #{}};
        _ ->
            {[], #{}}
    end.

%% A Hex dependency of rebar.lock as {Name, Package, Version}, or none for
%% a dependency from git. Package differs from Name for a dependency that
%% rebar.config renames.
hex_dep({Name, {pkg, Pkg, Vsn}, _}) -> {Name, Pkg, Vsn};
hex_dep({Name, {pkg, Pkg, Vsn, _}, _}) -> {Name, Pkg, Vsn};
hex_dep({Name, {pkg, Pkg, Vsn, _, _}, _}) -> {Name, Pkg, Vsn};
hex_dep(_) -> none.

%% The download entry of each Hex package of rebar.lock that has an outer
%% checksum, from hexpm. nix/lib/lock.nix derives the same entries.
derived_hex(RebarLock) ->
    {Deps, Ext} = rebar_lock(RebarLock),
    [
        #{
            path => <<"hex/hexpm/packages/", File/binary>>,
            url => <<"https://repo.hex.pm/tarballs/", File/binary>>,
            mirrors => [],
            hash => <<"sha256-", (base64:encode(binary:decode_hex(maps:get(Name, Ext))))/binary>>
        }
     || D <- Deps,
        {Name, Pkg, Vsn} <- [hex_dep(D)],
        maps:is_key(Name, Ext),
        File <- [<<Pkg/binary, "-", Vsn/binary, ".tar">>]
    ].

%% The repository URL and commit of each git dependency of rebar.lock.
locked_git(RebarLock) ->
    {Deps, _} = rebar_lock(RebarLock),
    lists:append([locked_git_dep(D) || D <- Deps]).

%% The repository URL and commit of a git dependency of rebar.lock, as a
%% list of one, or an empty list for a Hex dependency.
locked_git_dep({_, {git, Url, {ref, Rev}}, _}) ->
    [{list_to_binary(Url), list_to_binary(Rev)}];
locked_git_dep({_, {git_subdir, Url, {ref, Rev}, _}, _}) ->
    [{list_to_binary(Url), list_to_binary(Rev)}];
locked_git_dep(_) ->
    [].
