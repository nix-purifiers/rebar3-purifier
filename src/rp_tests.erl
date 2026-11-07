%% SPDX-License-Identifier: MIT
%%
%% Unit tests of the parts of rebar3-purifier that need neither rebar3 nor
%% the network. The build of the command runs them.
-module(rp_tests).

-include_lib("eunit/include/eunit.hrl").

https_url_test_() ->
    [
        ?_assertEqual("https://github.com/o/r.git", rp_lock:https_url("git@github.com:o/r.git")),
        ?_assertEqual(
            "https://github.com/o/r.git", rp_lock:https_url("ssh://git@github.com/o/r.git")
        ),
        ?_assertEqual("https://example.com/o/r", rp_lock:https_url("ssh://example.com:2222/o/r")),
        ?_assertEqual("https://github.com/o/r", rp_lock:https_url("git://github.com/o/r")),
        ?_assertEqual("https://github.com/o/r", rp_lock:https_url("https://github.com/o/r"))
    ].

quote_test_() ->
    [
        ?_assertEqual("'plain'", lists:flatten(rp_wrapper:quote("plain"))),
        ?_assertEqual("'it'\\''s'", lists:flatten(rp_wrapper:quote("it's")))
    ].

repo_url_test_() ->
    {setup,
        fun() ->
            Saved = [{V, os:getenv(V)} || V <- ["HEX_CDN", "HEX_MIRROR"]],
            os:unsetenv("HEX_CDN"),
            os:unsetenv("HEX_MIRROR"),
            Saved
        end,
        fun(Saved) ->
            [
                case Value of
                    false -> os:unsetenv(V);
                    _ -> os:putenv(V, Value)
                end
             || {V, Value} <- Saved
            ]
        end,
        fun(_) ->
            Config = [
                {hex, [
                    {repos, [#{name => <<"internal">>, repo_url => <<"https://hex.example.com/">>}]}
                ]}
            ],
            [
                ?_assertEqual(<<"https://repo.hex.pm">>, rp_lock:repo_url("hexpm", [])),
                ?_assertEqual(
                    <<"https://repo.hex.pm/repos/acme">>, rp_lock:repo_url("hexpm:acme", [])
                ),
                ?_assertEqual(<<"https://hex.example.com">>, rp_lock:repo_url("internal", Config)),
                ?_test(begin
                    os:putenv("HEX_CDN", "https://mirror.example.com/"),
                    ?assertEqual(<<"https://mirror.example.com">>, rp_lock:repo_url("hexpm", [])),
                    os:unsetenv("HEX_CDN")
                end)
            ]
        end}.

%% The lockfile's JSON has sorted keys and fixed indentation, so a relock
%% that finds the same downloads writes the same bytes.
write_json_test() ->
    File = filename:join(os:getenv("TMPDIR", "/tmp"), "rp_tests.json"),
    rp_util:write_json(File, #{b => [1, #{d => true, c => <<"x">>}], a => #{}}),
    {ok, Bin} = file:read_file(File),
    ok = file:delete(File),
    ?assertEqual(
        <<"{\n  \"a\": {},\n  \"b\": [\n    1,\n    {\n      \"c\": \"x\",\n      \"d\": true\n    }\n  ]\n}\n">>,
        Bin
    ).

tmp_dir(Name) ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "rp_tests-" ++ Name),
    rp_util:rm_rf(Dir),
    rp_util:ensure_dir(Dir),
    Dir.

%% Native plugin pins live in the purifier lock, not in rebar.lock.
%% An unchanged relock must replay them, but changes and explicit updates
%% must reach the native resolver. Invalid existing locks are never a fallback.
capture_mode_test() ->
    Dir = tmp_dir("capture-mode"),
    Native = filename:join(Dir, "rebar.lock"),
    File = filename:join(Dir, "rebar3-purifier.lock.json"),
    Config = filename:join(Dir, "rebar.config"),
    ok = file:write_file(Config, <<"{deps, []}.\n">>),
    ok = file:write_file(Native, <<"{\"1.2.0\", []}.\n[].\n">>),
    Project = #{root => Dir, rebar_lock => Native, lock_file => File},
    Profiles = ["default", "prod", "test"],
    ?assertEqual(fresh, rp_lock:capture_mode(Project, Profiles, none)),
    Lock = #{
        version => rp_util:lock_version(),
        definitionHash => rp_util:definition_hash(Project, rp_util:definition_files(Dir, Native)),
        profiles => [list_to_binary(P) || P <- Profiles],
        hexTarballs => [],
        git => []
    },
    ok = rp_util:write_lock(File, Lock),
    {ok, Before} = file:read_file(File),
    ?assertEqual(replay, rp_lock:capture_mode(Project, Profiles, none)),
    ?assertEqual(fresh, rp_lock:capture_mode(Project, Profiles, all)),
    ?assertEqual(fresh, rp_lock:capture_mode(Project, Profiles, ["jsx"])),
    ?assertEqual(fresh, rp_lock:capture_mode(Project, Profiles ++ ["extra"], none)),
    ok = file:write_file(Config, <<"{deps, []}.\n% changed\n">>),
    ?assertEqual(fresh, rp_lock:capture_mode(Project, Profiles, none)),
    ok = file:write_file(Config, <<"{deps, []}.\n">>),
    ok = file:write_file(Native, <<"{\"1.2.0\", []}.\n[].\n% changed\n">>),
    ?assertEqual(fresh, rp_lock:capture_mode(Project, Profiles, none)),
    ok = file:write_file(Native, <<"{\"1.2.0\", []}.\n[].\n">>),
    ?assertEqual({ok, Before}, file:read_file(File)),
    ok = file:write_file(File, <<"not json">>),
    ?assertThrow({fail, _}, rp_lock:capture_mode(Project, Profiles, none)),
    ?assertThrow({fail, _}, rp_lock:capture_mode(Project, Profiles, all)),
    ok = rp_util:write_lock(File, Lock),
    {ok, Valid} = rp_util:read_lock(File),
    ok = rp_util:write_json(File, Valid#{<<"profiles">> => []}),
    ?assertThrow({fail, _}, rp_lock:capture_mode(Project, Profiles, none)),
    rp_util:rm_rf(Dir).

capture_environment_test() ->
    Saved = os:getenv("GIT_CONFIG_COUNT"),
    try
        os:putenv("GIT_CONFIG_COUNT", "2"),
        Env = rp_wrapper:environment("/locked/tree", "/owned/cache", [
            #{<<"url">> => <<"https://example.org/plugin.git">>, <<"path">> => <<"git/recorded">>}
        ]),
        ?assertEqual("/owned/cache", proplists:get_value("REBAR_CACHE_DIR", Env)),
        ?assertEqual("http://127.0.0.1:9", proplists:get_value("HEX_CDN", Env)),
        ?assertEqual("4", proplists:get_value("GIT_CONFIG_COUNT", Env)),
        ?assertEqual("safe.directory", proplists:get_value("GIT_CONFIG_KEY_2", Env)),
        ?assertEqual(
            "url./locked/tree/git/recorded.insteadOf", proplists:get_value("GIT_CONFIG_KEY_3", Env)
        ),
        ?assertEqual(
            "https://example.org/plugin.git", proplists:get_value("GIT_CONFIG_VALUE_3", Env)
        ),
        ?assertEqual("2", os:getenv("GIT_CONFIG_COUNT"))
    after
        case Saved of
            false -> os:unsetenv("GIT_CONFIG_COUNT");
            _ -> os:putenv("GIT_CONFIG_COUNT", Saved)
        end
    end.

%% A Hex tarball in the cache is a file entry at its cache path, at the
%% tarball URL of its repository, with its SHA-256.
hex_entries_test() ->
    Cache = tmp_dir("hex"),
    Packages = filename:join(Cache, "hex/hexpm/packages"),
    rp_util:ensure_dir(Packages),
    ok = file:write_file(filename:join(Packages, "jsx-3.1.0.tar"), <<"tarball">>),
    ok = file:write_file(filename:join(Packages, "jsx-3.1.0.etag"), <<"\"x\"">>),
    os:unsetenv("HEX_CDN"),
    ?assertEqual(
        [
            #{
                path => <<"hex/hexpm/packages/jsx-3.1.0.tar">>,
                url => <<"https://repo.hex.pm/tarballs/jsx-3.1.0.tar">>,
                mirrors => [],
                hash => rp_util:sri_sha256(<<"tarball">>)
            }
        ],
        rp_lock:hex_entries(Cache, [])
    ),
    rp_util:rm_rf(Cache).

%% rebar.lock dependencies without a download, Hex and git, are named. A
%% Hex package of rebar.lock without an outer checksum needs its tarball
%% in the lockfile.
missing_test() ->
    Dir = tmp_dir("missing"),
    ok = file:write_file(filename:join(Dir, "rebar.lock"), <<
        "{\"1.2.0\",\n"
        "[{<<\"jsx\">>,{pkg,<<\"jsx\">>,<<\"3.1.0\">>},0},\n"
        " {<<\"ranch\">>,{pkg,<<\"ranch\">>,<<\"1.8.0\">>},1},\n"
        " {<<\"meck\">>,{git,\"https://github.com/eproxus/meck.git\",{ref,\"abc\"}},0}]}.\n"
        "[].\n"
    >>),
    Lock = #{
        <<"hexTarballs">> => [#{<<"path">> => <<"hex/hexpm/packages/jsx-3.1.0.tar">>}],
        <<"git">> => []
    },
    ?assertEqual(
        ["meck (git abc)", "ranch 1.8.0"],
        rp_check:missing(filename:join(Dir, "rebar.lock"), Lock)
    ),
    rp_util:rm_rf(Dir).

%% The contentHash is the SHA-256 of the lockfile without it, in the JSON
%% that builtins.toJSON of Nix writes. The expected value is what
%% nix/lib/content-hash.nix gives for the same lockfile.
content_hash_test() ->
    Lock = #{
        <<"version">> => 2,
        <<"contentHash">> => <<"ignored">>,
        <<"b">> => [true, null, <<"a\"b\\c\nd">>],
        <<"a">> => #{}
    },
    ?assertEqual(
        <<"sha256-ZtGrCQMEubd0A+9GZXBrsM75DXxEg8gLiKxqFhjMcII=">>,
        rp_util:content_hash(Lock)
    ).

%% rp_git makes a bare repository of a .git directory, which git clones by
%% a recorded tag or branch at the commit HEAD names.
git_roundtrip_test() ->
    Tmp = tmp_dir("git"),
    Src = filename:join(Tmp, "src"),
    rp_util:ensure_dir(filename:join(Src, "sub/dir")),
    rp_util:ensure_dir(filename:join(Src, "empty")),
    ok = file:write_file(filename:join(Src, "a.txt"), <<"a\n">>),
    ok = file:write_file(filename:join(Src, "run"), <<"#!/bin/sh\n">>),
    ok = file:change_mode(filename:join(Src, "run"), 8#755),
    ok = file:write_file(filename:join(Src, "sub/dir/c.txt"), <<"c\n">>),
    ok = file:make_symlink("a.txt", filename:join(Src, "link")),
    Env = [
        {"GIT_AUTHOR_NAME", "t"},
        {"GIT_AUTHOR_EMAIL", "t@example.com"},
        {"GIT_COMMITTER_NAME", "t"},
        {"GIT_COMMITTER_EMAIL", "t@example.com"},
        {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
        {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"},
        {"HOME", Tmp}
    ],
    Git = fun(Dir, Args) ->
        {0, Out} = rp_util:run_quiet("git", ["-c", "safe.directory=*" | Args], Dir, Env),
        string:trim(binary_to_list(Out))
    end,
    Git(Src, ["init", "-q"]),
    Git(Src, ["add", "-A"]),
    Git(Src, ["commit", "-q", "-m", "test"]),
    Git(Src, ["branch", "-M", "main"]),
    Rev = Git(Src, ["rev-parse", "HEAD"]),
    Repo = filename:join(Tmp, "repo"),
    ok = rp_git:bare_repo(
        filename:join(Src, ".git"),
        Repo,
        #{<<"tags">> => [<<"v1">>], <<"branches">> => [<<"stable">>]}
    ),
    Git(Tmp, ["clone", "-q", "-b", "v1", "--single-branch", Repo, filename:join(Tmp, "by-tag")]),
    ?assertEqual(Rev, Git(filename:join(Tmp, "by-tag"), ["rev-parse", "HEAD"])),
    Git(Tmp, [
        "clone", "-q", "-b", "stable", "--single-branch", Repo, filename:join(Tmp, "by-branch")
    ]),
    ?assertEqual(Rev, Git(filename:join(Tmp, "by-branch"), ["rev-parse", "HEAD"])),
    ?assertEqual("true", Git(Repo, ["rev-parse", "--is-bare-repository"])),
    rp_util:rm_rf(Tmp).

%% An application whose version comes from git gets the version the lock
%% run recorded; one with a version of its own keeps it.
pin_versions_test() ->
    Dir = tmp_dir("versions"),
    rp_util:ensure_dir(filename:join(Dir, "apps/a/src")),
    rp_util:ensure_dir(filename:join(Dir, "apps/b/src")),
    ok = file:write_file(
        filename:join(Dir, "apps/a/src/a.app.src"),
        <<"{application, a, [{vsn, git}, {applications, [kernel]}]}.\n">>
    ),
    ok = file:write_file(
        filename:join(Dir, "apps/b/src/b.app.src"),
        <<"{application, b, [{vsn, \"2.0.0\"}]}.\n">>
    ),
    LockFile = filename:join(Dir, "lock.json"),
    rp_util:write_lock(LockFile, #{
        version => rp_util:lock_version(),
        outputs => #{
            apps => [
                #{name => <<"a">>, version => <<"1.2.3">>, dir => <<"apps/a">>},
                #{name => <<"b">>, version => <<"9.9.9">>, dir => <<"apps/b">>}
            ]
        }
    }),
    rp_versions:pin(Dir, LockFile),
    {ok, [{application, a, A}]} = file:consult(filename:join(Dir, "apps/a/src/a.app.src")),
    {ok, [{application, b, B}]} = file:consult(filename:join(Dir, "apps/b/src/b.app.src")),
    ?assertEqual("1.2.3", proplists:get_value(vsn, A)),
    ?assertEqual([kernel], proplists:get_value(applications, A)),
    ?assertEqual("2.0.0", proplists:get_value(vsn, B)),
    rp_util:rm_rf(Dir).

sri_test() ->
    ?assertEqual(
        <<"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=">>, rp_util:sri_sha256(<<>>)
    ).
