#!/usr/bin/env escript
%%! +S 2:2 +A 1
%% Native relx/application/BEAM metadata, not a second dependency resolver.
-mode(compile).

main([Producer, SpecFile, Output]) ->
    try
        {ok, SpecBytes} = file:read_file(SpecFile),
        Spec = json:decode(SpecBytes),
        Release = binary_to_list(maps:get(<<"release">>, Spec)),
        Directory = filename:join([Producer, "releases", Release]),
        [Rel] = filelib:wildcard(filename:join([Directory, "releases", "*", Release ++ ".rel"])),
        {ok, [{release, {Release, Version}, {erts, Erts}, Applications}]} = file:consult(Rel),
        case Erts =:= erlang:system_info(version) of
            true -> ok;
            false -> error(sdk_erts_mismatch)
        end,
        case binary_to_list(maps:get(<<"otpRelease">>, Spec)) =:= erlang:system_info(otp_release) of
            true -> ok;
            false -> error(sdk_otp_mismatch)
        end,
        Rows = [application(Directory, element(1, A), element(2, A)) || A <- Applications],
        Names = [maps:get(name, A) || A <- Rows],
        true = length(Names) =:= length(lists:usort(Names)),
        Roots = maps:get(<<"roots">>, Spec),
        true = lists:all(fun(R) -> lists:member(R, Names) end, Roots),
        lists:foreach(
            fun(A) ->
                Required = maps:get(required, A) -- maps:get(optional, A),
                true = lists:all(
                    fun(D) -> lists:member(D, Names) end, Required ++ maps:get(included, A)
                )
            end,
            Rows
        ),
        Selected = [A || A <- Rows, not maps:get(sdk, A)],
        true = lists:all(
            fun(R) -> lists:any(fun(A) -> maps:get(name, A) =:= R end, Selected) end, Roots
        ),
        Modules = lists:append([maps:get(modules, A) || A <- Selected]),
        ModuleNames = [maps:get(name, M) || M <- Modules],
        case length(ModuleNames) =:= length(lists:usort(ModuleNames)) of
            true -> ok;
            false -> error(duplicate_compiled_module_owners)
        end,
        Model = #{
            kind => <<"compiled-native-relx-application-set">>,
            selection => Spec,
            producer => unicode:characters_to_binary(Producer),
            release => unicode:characters_to_binary(Rel),
            releaseSHA256 => hash_file(Rel),
            releaseVersion => unicode:characters_to_binary(Version),
            otp => unicode:characters_to_binary(erlang:system_info(otp_release)),
            erts => unicode:characters_to_binary(Erts),
            architecture => unicode:characters_to_binary(erlang:system_info(system_architecture)),
            runtimeRoot => unicode:characters_to_binary(code:root_dir()),
            applications => Rows
        },
        ok = file:write_file(Output, json:encode(Model))
    catch
        Class:Reason:Stack ->
            io:format(
                standard_error,
                "Native OTP stack: ~0p~nrebar3-purifier: compiled OTP selection: ~0p:~0p~n",
                [Stack, Class, Reason]
            ),
            halt(1)
    end.

application(Root, App, Version) ->
    Dir = filename:join([Root, "lib", atom_to_list(App) ++ "-" ++ Version]),
    AppFile = filename:join([Dir, "ebin", atom_to_list(App) ++ ".app"]),
    {ok, [{application, App, Props}]} = file:consult(AppFile),
    Version = proplists:get_value(vsn, Props),
    SdkDir =
        case code:lib_dir(App) of
            {error, bad_name} ->
                false;
            Path ->
                case lists:prefix(code:root_dir() ++ "/", Path) of
                    true -> Path;
                    false -> false
                end
        end,
    Beams = filelib:wildcard(filename:join([Dir, "ebin", "*.beam"])),
    Modules = [module(B, SdkDir) || B <- lists:sort(Beams)],
    Actual = [binary_to_atom(maps:get(name, M)) || M <- Modules],
    true = lists:all(
        fun(M) -> lists:member(M, Actual) end, proplists:get_value(modules, Props, [])
    ),
    Files = lists:sort(filelib:fold_files(Dir, ".*", true, fun(F, Acc) -> [F | Acc] end, [])),
    Evidence = [file(F, Dir, SdkDir) || F <- Files],
    #{
        name => atom_to_binary(App),
        version => unicode:characters_to_binary(Version),
        directory => unicode:characters_to_binary(Dir),
        sdk => SdkDir =/= false,
        required => [atom_to_binary(A) || A <- proplists:get_value(applications, Props, [])],
        included => [
            atom_to_binary(A)
         || A <- proplists:get_value(included_applications, Props, [])
        ],
        optional => [
            atom_to_binary(A)
         || A <- proplists:get_value(optional_applications, Props, [])
        ],
        modules => Modules,
        files => Evidence
    }.

module(File, Sdk) ->
    {ok, Mod, Chunks} = beam_lib:all_chunks(File),
    true = atom_to_list(Mod) =:= filename:basename(File, ".beam"),
    {ok, {Mod, MD5}} = beam_lib:md5(File),
    Base = #{
        name => atom_to_binary(Mod), sha256 => hash_file(File), codeMD5 => binary:encode_hex(MD5)
    },
    case Sdk of
        false ->
            case code:which(Mod) of
                preloaded ->
                    error({sdk_module_collision, Mod});
                P when is_list(P) ->
                    case lists:prefix(code:root_dir() ++ "/", P) of
                        true -> error({sdk_module_collision, Mod});
                        false -> Base
                    end;
                _ ->
                    Base
            end;
        _ ->
            Original = filename:join([Sdk, "ebin", filename:basename(File)]),
            {ok, Mod, SdkChunks} = beam_lib:all_chunks(Original),
            %% Native relx prod stripping removes compiler/debug/local-function
            %% information. Every remaining chunk and native code MD5 agrees.
            Strip = ["LocT", "CInf", "Dbgi", "Docs", "Abst"],
            Semantic = fun(C) ->
                lists:sort([{K, V} || {K, V} <- C, not lists:member(K, Strip)])
            end,
            case Semantic(Chunks) =:= Semantic(SdkChunks) of
                true -> ok;
                false -> error({altered_sdk_beam, Mod})
            end,
            {ok, {Mod, MD5}} = beam_lib:md5(Original),
            Base#{
                sdkFile => unicode:characters_to_binary(Original),
                sdkSHA256 => hash_file(Original),
                comparison => <<"native-code-MD5-and-all-nondebug-chunks">>
            }
    end.

file(File, Root, Sdk) ->
    Relative = string:prefix(File, Root ++ "/"),
    true = is_list(Relative),
    {ok, Bytes} = file:read_file(File),
    case Sdk of
        false ->
            Extension = filename:extension(File),
            NativeMagic =
                case Bytes of
                    <<127, "ELF", _/binary>> -> true;
                    <<"MZ", _/binary>> -> true;
                    _ -> false
                end,
            case
                NativeMagic orelse
                    lists:member(Extension, [".so", ".dylib", ".dll", ".nif", ".a", ".o"])
            of
                true -> error({native_application_payload_needs_runtime_proof, Relative});
                false -> ok
            end;
        _ ->
            case filename:extension(File) of
                ".beam" -> ok;
                _ -> {ok, Bytes} = file:read_file(filename:join(Sdk, Relative))
            end
    end,
    #{path => unicode:characters_to_binary(Relative), sha256 => hash(Bytes)}.
hash_file(File) ->
    {ok, Bytes} = file:read_file(File),
    hash(Bytes).
hash(Bytes) -> string:lowercase(binary:encode_hex(crypto:hash(sha256, Bytes))).
