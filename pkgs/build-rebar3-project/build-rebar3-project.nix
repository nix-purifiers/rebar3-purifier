# SPDX-License-Identifier: MIT
#
# buildRebar3Project: the sandboxed build of a rebar3 project from the
# lockfile that `rebar3-purifier lock` writes.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the package set and the rebar3-purifier scope, and the result
# is the builder. The overlay of the flake (`overlays.default`) adds the
# scope to the package set as `rebar3-purifier`, so a package written for
# callPackage takes the scope by name:
#
#   { rebar3-purifier }:
#   (rebar3-purifier.buildRebar3Project { src = ./.; }).packages.release-hello
#
# and `buildRebar3Project.override` replaces what the builder takes.
# The lockfile lists the outputs of the build, so every attribute of the
# result is known at evaluation time. The result has
#
#   packages.default            one derivation with every output:
#                               lib/<app>, releases/<release>,
#                               bin/<escript> and hex/<package>.tar
#   packages.app-<name>         each application of the project, compiled:
#                               its ebin, priv and include directories in
#                               lib/<name>
#   packages.release-<name>     each relx release, built with the release
#                               profile, with its start script as bin/<name>
#   packages.escript-<name>     the escript, when rebar.config configures one
#   tests                       `rebar3 eunit`, and `rebar3 ct` when the
#                               project has common test suites
#   release                     the Hex package tarballs, which
#                               `rebar3-purifier publish` uploads
#   fetches                     the entries of the purifier library that
#                               the build fetches
#   cache                       the cache tree of the locked downloads
{
  lib,
  stdenv,
  runCommand,
  fetchurl,
  fetchgit,
  unzip,
  zstd,
  python3,
  writeText,
  git,
  beam,
  makeWrapper,
  coreutils,
  gawk,
  gnugrep,
  gnused,
  hostname,
  # The rebar3-purifier command, from the rebar3-purifier scope.
  cli,
  callPackage,
  # The shared purifier library (`lib.purifier` of its flake).
  purifier,
}:
let
  defaultCli = cli;
in
{
  # The project directory, with rebar.config.
  src,
  # Fetchers in place of nixpkgs' own, such as a fetchurl for a company
  # mirror or with credentials. The purifier library's fetchEntry takes
  # them, with the arguments of the nixpkgs fetchers of the same names.
  fetchers ? { },
  # The lockfile. It may lie outside `src`, for a build that keeps it
  # outside the repository.
  lockFile ? src + "/rebar3-purifier.lock.json",
  # The rebar.lock to build with in place of the rebar.lock in `src`, for a
  # build that keeps its own copy outside the repository.
  rebarLock ? src + "/rebar.lock",
  # The BEAM package set to build with. The default is the one of the OTP
  # release the lock was made with, when nixpkgs has it.
  beamPackages ? null,
  # The rebar3-purifier command.
  cli ? defaultCli,
  # The profile releases are built with.
  releaseProfile ? "prod",
  buildInputs ? [ ],
  nativeBuildInputs ? [ ],
  # Filters src before it is copied into the store, as the `filter` of
  # builtins.path. The default leaves out _build, VCS and editor state, and
  # result links.
  srcFilter ? null,
  otpApplications ? { },
}:
let
  readLock = import ../../lib-overlays/default/read-lock.nix { inherit lib; };
  # The lock in memory, which checkLock of the purifier library stops at
  # its problems, each naming the command that fixes it.
  lock = purifier.checkLock (readLock {
    inherit src lockFile rebarLock;
  });
  entries = purifier.entriesFor stdenv.hostPlatform.system lock;

  ofKind = kind: builtins.filter (o: o.kind == kind) (builtins.attrValues lock.outputs);
  outputs = {
    apps = ofKind "app";
    releases = map (o: o.name) (ofKind "release");
    escripts = map (o: o.name) (ofKind "escript");
    hexPackages = ofKind "hexPackage";
  };

  beamSet =
    if beamPackages != null then
      beamPackages
    else
      beam.packages."erlang_${lock.otpRelease}" or beam.packages.erlang;
  inherit (beamSet) erlang rebar3;

  cache = import ./cache.nix {
    inherit
      lib
      runCommand
      fetchurl
      fetchgit
      unzip
      zstd
      python3
      writeText
      purifier
      fetchers
      entries
      cli
      ;
  };

  # git fetches each locked repository from its rebuilt repository in the
  # cache tree. The repositories belong to another user, so git has to
  # trust them.
  gitConfig = [
    {
      key = "safe.directory";
      value = "*";
    }
  ]
  ++ lib.concatMap (
    e:
    map (s: {
      key = "url.${cache}/${e.path}.insteadOf";
      value = s.url;
    }) (e.rebar3Sources or [ ])
  ) entries;

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !(
      name == "_build"
      || name == ".git"
      || name == ".idea"
      || name == ".rebar3-purifier-gcroots"
      || lib.hasPrefix "result" name
    );

  filteredSrc = builtins.path {
    path = src;
    name = "rebar3-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  # The application at the root of the project, or the first one under
  # apps/ or lib/, names the build.
  firstApp = lib.findFirst (a: a.dir == ".") (builtins.head outputs.apps) outputs.apps;

  # What the build and the test run share: the source, the tools, and
  # rebar3 set up with the locked downloads as its cache, a home and
  # global configuration of its own, and Hex's default repository at an
  # address that refuses connections, so it takes every tarball from the
  # cache. The cache is a writable copy, since rebar3 writes into it.
  common = {
    inherit (firstApp) version;
    src = filteredSrc;
    nativeBuildInputs = [
      erlang
      rebar3
      git
      makeWrapper
    ]
    ++ nativeBuildInputs;
    # Escripts and release scripts find escript and erl through these.
    buildInputs = [ erlang ] ++ buildInputs;

    configurePhase = ''
      runHook preConfigure
      ${lib.optionalString (builtins.pathExists rebarLock) ''
        cp ${rebarLock} rebar.lock
        chmod u+w rebar.lock
      ''}
      ${cli}/bin/rebar3-purifier check . ${lockFile}
      ${cli}/bin/rebar3-purifier pin-versions . ${lockFile}
      export HOME="$TMPDIR/home"
      export REBAR_GLOBAL_CONFIG_DIR="$TMPDIR/rebar3-global"
      export REBAR_CACHE_DIR="$TMPDIR/rebar3-cache"
      export HEX_CDN=http://127.0.0.1:9
      mkdir -p "$HOME" "$REBAR_GLOBAL_CONFIG_DIR" "$REBAR_CACHE_DIR"
      if [ -d ${cache}/hex ]; then
        cp -rL --no-preserve=mode ${cache}/hex "$REBAR_CACHE_DIR/hex"
      fi
      export GIT_CONFIG_COUNT=${toString (builtins.length gitConfig)}
      ${lib.concatImapStrings (i: c: ''
        export GIT_CONFIG_KEY_${toString (i - 1)}=${lib.escapeShellArg c.key}
        export GIT_CONFIG_VALUE_${toString (i - 1)}=${lib.escapeShellArg c.value}
      '') gitConfig}
      runHook postConfigure
    '';
  };

  all = stdenv.mkDerivation (
    common
    // {
      pname = firstApp.name;

      # The .beam files leave out the build directory's paths, which are
      # not a fixed /build on every platform, so a rebuild matches. As
      # nixpkgs' buildRebar3 does.
      ERL_COMPILER_OPTIONS = "[deterministic]";

      buildPhase = ''
        runHook preBuild
        rebar3 compile
        ${lib.concatMapStrings (r: ''
          rebar3 as ${lib.escapeShellArg releaseProfile} release -n ${lib.escapeShellArg r}
        '') outputs.releases}
        ${lib.optionalString (outputs.escripts != [ ]) "rebar3 escriptize\n"}
        # Each Hex package tarball, without its documentation, which the
        # project's doc provider would build.
        ${lib.concatMapStrings (p: ''
          rebar3 hex build package --app ${lib.escapeShellArg p.name}
        '') outputs.hexPackages}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        ${lib.concatMapStrings (a: ''
          mkdir -p "$out/lib/${a.name}"
          for d in ebin priv include; do
            if [ -e "_build/default/lib/${a.name}/$d" ]; then
              cp -rL "_build/default/lib/${a.name}/$d" "$out/lib/${a.name}/"
            fi
          done
        '') outputs.apps}
        ${lib.concatMapStrings (r: ''
          mkdir -p "$out/releases"
          cp -rL ${lib.escapeShellArg "_build/${releaseProfile}/rel/${r}"} "$out/releases/"
          # The relx start script runs these tools from the PATH.
          wrapProgram "$out/releases/${r}/bin/${r}" --prefix PATH : ${
            lib.makeBinPath [
              coreutils
              gawk
              gnugrep
              gnused
              hostname
            ]
          }
        '') outputs.releases}
        ${lib.concatMapStrings (e: ''
          install -Dm755 "_build/default/bin/${e}" "$out/bin/${e}"
        '') outputs.escripts}
        ${lib.concatMapStrings (p: ''
          install -Dm644 "_build/default/lib/${p.name}/hex/${p.name}-${p.version}.tar" \
            "$out/hex/${p.name}-${p.version}.tar"
        '') outputs.hexPackages}
        runHook postInstall
      '';

      passthru = { inherit lock cache; };
      meta.description = "${firstApp.name}, built by rebar3-purifier";
    }
  );

  tests = stdenv.mkDerivation (
    common
    // {
      pname = "${firstApp.name}-tests";
      dontBuild = true;
      doCheck = true;
      checkPhase = ''
        runHook preCheck
        rebar3 eunit
        if [ -n "$(find . -path ./_build -prune -o -name '*_SUITE.erl' -print)" ]; then
          rebar3 ct
        fi
        runHook postCheck
      '';
      installPhase = ''
        touch $out
      '';
      meta.description = "the tests of ${firstApp.name}, run by rebar3-purifier";
    }
  );

  # One output of the build, as links into `all`, so that every output
  # comes from one build. `links` maps a path in the output to a path in
  # `all`.
  link =
    name: links: extra:
    runCommand name ({ passthru = { inherit all lock cache; }; } // extra) ''
      ${lib.concatStrings (
        lib.mapAttrsToList (to: from: ''
          mkdir -p "$out/$(dirname ${lib.escapeShellArg to})"
          ln -s ${all}/${lib.escapeShellArg from} "$out/"${lib.escapeShellArg to}
        '') links
      )}
    '';

  byName =
    prefix: list: f:
    lib.listToAttrs (map (x: lib.nameValuePair "${prefix}-${x.name or x}" (f x)) list);
  otp = lib.mapAttrs (
    release: roots:
    callPackage ./otp-projections.nix
      {
        inherit
          lib
          stdenv
          runCommand
          python3
          writeText
          purifier
          ;
      }
      {
        producer = all;
        inherit release roots erlang;
        ownApplications = map (app: app.name) outputs.apps;
        otpRelease = lock.otpRelease;
      }
  ) otpApplications;
in
assert lib.assertMsg (
  builtins.isAttrs otpApplications
  && builtins.all (name: builtins.elem name outputs.releases) (builtins.attrNames otpApplications)
) "rebar3-purifier: otpApplications must name locked relx releases";
assert builtins.all (value: value.validated) (builtins.attrValues otp);
{
  inherit tests cache;

  packages = {
    default = all;
  }
  // byName "app" outputs.apps (
    a: link "${a.name}-${a.version}" { "lib/${a.name}" = "lib/${a.name}"; } { }
  )
  // byName "release" outputs.releases (
    r:
    link r {
      "releases/${r}" = "releases/${r}";
      "bin/${r}" = "releases/${r}/bin/${r}";
    } { meta.mainProgram = r; }
  )
  // byName "escript" outputs.escripts (
    e: link e { "bin/${e}" = "bin/${e}"; } { meta.mainProgram = e; }
  )
  // lib.mapAttrs' (name: value: lib.nameValuePair "otp-${name}" value.package) otp;
  projections = lib.mapAttrs (_: value: value.projections) otp;

  release =
    if outputs.hexPackages == [ ] then
      throw "rebar3-purifier: ${firstApp.name} builds no Hex package; add rebar3_hex to project_plugins in rebar.config and run `rebar3-purifier lock`"
    else
      link "${firstApp.name}-hex-packages" (lib.listToAttrs (
        map (
          p: lib.nameValuePair "${p.name}-${p.version}.tar" "hex/${p.name}-${p.version}.tar"
        ) outputs.hexPackages
      )) { };

  fetches = lock.entries;
}
