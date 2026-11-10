# SPDX-License-Identifier: MIT
#
# The flake's checks: builds of the fixtures from their lockfiles, each
# output run or inspected, the conformance checks of the purifier contract
# that run in the sandbox, and the behaviour of the Nix library on its
# own. The conformance checks that need the network or Nix itself
# (conformance-relock, conformance-rebuild and conformance-offline) are
# jobs of the same names in .github/workflows/check.yml.
{
  pkgs,
  overlay,
  # The source of the shared purifier library.
  purifierSrc,
}:
let
  extended = pkgs.extend overlay;
  inherit (extended) lib runCommand;
  inherit (extended.rebar3-purifier) cli buildRebar3Project;

  # One application with Hex dependencies and plugins, a git dependency in
  # its test profile, an escript, a release and a Hex package.
  hello = buildRebar3Project {
    src = ./fixtures/hello;
  };

  # Two applications under apps/, git dependencies at a tag and in a
  # subdirectory of a repository, a plugin from git, and a release of both.
  umbrella = buildRebar3Project {
    src = ./fixtures/umbrella;
  };
  projectedUmbrella = buildRebar3Project {
    src = ./fixtures/umbrella;
    otpApplications.umbrella = [ "greeter" ];
  };

  # The hello fixture as a build kept external: its tree holds rebar.lock
  # and no rebar3-purifier lockfile, which lies outside it. `without` is
  # the tree without the files named.
  without =
    names:
    builtins.path {
      path = ./fixtures/hello;
      name = "hello-without-${lib.concatStringsSep "-" names}";
      filter = path: _: !builtins.elem (baseNameOf path) names;
    };
  external = buildRebar3Project {
    src = without [ "rebar3-purifier.lock.json" ];
    lockFile = ./fixtures/hello/rebar3-purifier.lock.json;
  };

  # The same fixture with neither lockfile in its tree: both lie outside.
  externalBoth = buildRebar3Project {
    src = without [
      "rebar3-purifier.lock.json"
      "rebar.lock"
    ];
    lockFile = ./fixtures/hello/rebar3-purifier.lock.json;
    rebarLock = ./fixtures/hello/rebar.lock;
  };

  # Runs a command and compares what it prints.
  prints =
    name: command: expected:
    runCommand name { inherit expected; } ''
      ${command} > actual
      printf '%s\n' "$expected" > expected-file
      if ! diff -u expected-file actual; then
        exit 1
      fi
      touch $out
    '';

  helloLockFile = ./fixtures/hello/rebar3-purifier.lock.json;
  helloLock = builtins.fromJSON (builtins.readFile helloLockFile);
  umbrellaLock = builtins.fromJSON (builtins.readFile ./fixtures/umbrella/rebar3-purifier.lock.json);
  withContentHash = lock: lock // { contentHash = import ../nix/lib/content-hash.nix lock; };
  lockFileOf = lock: builtins.toFile "rebar3-purifier.lock.json" (builtins.toJSON lock);
  pathsOf = entries: map (e: e.path) entries;

  # A conformance check that a lockfile which does not fit a fixture fails
  # twice with an error that matches `pattern`: in `rebar3-purifier check`,
  # which the build runs before rebar3, and in the evaluation of the
  # builder, which runs here with Nix in the sandbox and a store that holds
  # nothing. `setup` changes the copy of the fixture in `project` after
  # `lockFile` replaced its lockfile.
  refused =
    name:
    {
      fixture ? ./fixtures/hello,
      lockFile ? helloLockFile,
      setup ? "",
      pattern ? "rebar3-purifier lock",
    }:
    let
      expr = extended.writeText "refused-expression.nix" ''
        let
          nixpkgs = import ${pkgs.path} { system = "${pkgs.stdenv.hostPlatform.system}"; };
          build = nixpkgs.callPackage ${../nix/lib}/build-rebar3-project.nix {
            purifier = import ${purifierSrc} { inherit (nixpkgs) lib; };
            cli = null;
          };
        in
        (build { src = /. + (builtins.getEnv "PWD" + "/project"); }).fetches
      '';
    in
    runCommand "conformance-${name}" { nativeBuildInputs = [ extended.nix ]; } ''
      cp -r ${fixture} project
      chmod -R u+w project
      cp ${lockFile} project/rebar3-purifier.lock.json
      chmod u+w project/rebar3-purifier.lock.json
      ${setup}
      if ${cli}/bin/rebar3-purifier check project project/rebar3-purifier.lock.json 2> command.log; then
        echo "rebar3-purifier check accepted the lockfile" >&2
        exit 1
      fi
      cat command.log
      grep -qF ${lib.escapeShellArg pattern} command.log
      export HOME="$TMPDIR" NIX_STATE_DIR="$TMPDIR/nix/var" NIX_LOG_DIR="$TMPDIR/nix/log"
      if nix-instantiate --eval --strict --store dummy:// ${expr} 2> eval.log; then
        echo "the evaluation of buildRebar3Project accepted the lockfile" >&2
        exit 1
      fi
      cat eval.log
      grep -qF ${lib.escapeShellArg pattern} eval.log
      touch $out
    '';

  readLock = import ../nix/lib/read-lock.nix { inherit lib; };
  readsVersion =
    version:
    !builtins.any (lib.hasInfix "lock format version")
      (readLock {
        src = ./fixtures/hello;
        lockFile = lockFileOf (withContentHash (helloLock // { inherit version; }));
      }).problems;
in
{
  fixture-otp-applications = projectedUmbrella.packages.otp-umbrella;
  fixture-otp-consumers = import ./otp-projections.nix { pkgs = extended; };
  fixture-hello-escript =
    prints "fixture-hello-escript" "${lib.getExe hello.packages.escript-hello} Nix"
      ''{"hello":"Nix"}'';

  # The release starts, with the ERTS it includes, prints and stops. The
  # start script prints the command it runs first. Each release check
  # registers its node with an epmd on a port of its own: darwin builds
  # share the host's network, and a release check that registers with the
  # epmd another build started fails when that build ends.
  fixture-hello-release = runCommand "fixture-hello-release" { } ''
    HOME=$TMPDIR HELLO_ONESHOT=1 ERL_EPMD_PORT=43691 ${lib.getExe hello.packages.release-hello} foreground > actual
    grep -qx '{"hello":"release"}' actual
    touch $out
  '';

  # The application's compiled modules, and the Hex package with its
  # metadata in the `release` that `rebar3-purifier publish` uploads.
  fixture-hello-outputs = runCommand "fixture-hello-outputs" { } ''
    test -f ${hello.packages.app-hello}/lib/hello/ebin/hello.beam
    test -f ${hello.packages.app-hello}/lib/hello/ebin/hello.app
    tar -xOf ${hello.release}/hello-0.1.0.tar metadata.config | grep -q '<<"jsx">>'
    touch $out
  '';

  # The eunit tests of the fixture, with meck from git.
  fixture-hello-tests = hello.tests;

  # The fetches are the download entries of the build: the Hex packages of
  # rebar.lock with the outer checksums it records, the plugin tarballs
  # the lockfile records, and the git checkout of the test profile.
  fixture-hello-fetches =
    let
      jsx = lib.findFirst (e: e.path == "hex/hexpm/packages/jsx-3.1.0.tar") null hello.fetches;
    in
    assert jsx.url == "https://repo.hex.pm/tarballs/jsx-3.1.0.tar";
    # The outer checksum 0C5CC8FD… of jsx 3.1.0 in rebar.lock.
    assert jsx.hash == "sha256-DFzI/cEbU8wlz2WsZwWtOeVOzFbRwi5K249aU/uUJ/M=";
    assert !builtins.elem jsx.path (pathsOf helloLock.hexTarballs);
    assert builtins.elem "hex/hexpm/packages/rebar3_hex-7.4.0.tar" (pathsOf hello.fetches);
    assert builtins.elem "git/29360b25b708b2dc9d68a4f46f6a1b8b55f72518" (pathsOf hello.fetches);
    runCommand "fixture-hello-fetches" { } "touch $out";

  # The cache tree holds every locked tarball with its etag, the package
  # index, and the repository rebuilt from the git checkout, whose tag
  # names the locked commit.
  fixture-hello-cache = runCommand "fixture-hello-cache" { } ''
    for p in cowboy-2.12.0 cowlib-2.13.0 jsx-3.1.0 ranch-1.8.0 erlfmt-1.8.0 rebar3_hex-7.4.0; do
      test -f ${hello.cache}/hex/hexpm/packages/$p.tar
      test -f ${hello.cache}/hex/hexpm/packages/$p.etag
    done
    test -f ${hello.cache}/hex/packages.idx
    repo=${hello.cache}/git/29360b25b708b2dc9d68a4f46f6a1b8b55f72518
    test "$(cat $repo/refs/tags/1.0.0)" = 29360b25b708b2dc9d68a4f46f6a1b8b55f72518
    ${extended.git}/bin/git -c safe.directory='*' -C $repo cat-file -e 29360b25b708b2dc9d68a4f46f6a1b8b55f72518^{tree}
    touch $out
  '';

  # Every output of each fixture, which the conformance-rebuild job builds
  # a second time.
  fixture-hello-build = hello.packages.default;
  fixture-umbrella-build = umbrella.packages.default;

  fixture-umbrella-release = runCommand "fixture-umbrella-release" { } ''
    HOME=$TMPDIR SERVER_ONESHOT=1 ERL_EPMD_PORT=43692 ${lib.getExe umbrella.packages.release-umbrella} foreground > actual
    grep -qx 'Hello, Nix (recon 2.5.6, opentelemetry_api 1.5.0)' actual
    touch $out
  '';

  # Each application of the umbrella is an output of its own.
  fixture-umbrella-apps = runCommand "fixture-umbrella-apps" { } ''
    test -f ${umbrella.packages.app-greeter}/lib/greeter/ebin/greeter.beam
    test -f ${umbrella.packages.app-server}/lib/server/ebin/server_app.beam
    touch $out
  '';

  # A lockfile older than a file that defines the dependencies.
  conformance-stale = refused "stale" {
    setup = "echo '%% a change' >> project/rebar.config";
  };

  # A lockfile whose recorded download has another hash than the lock
  # recorded.
  conformance-tampered = refused "tampered" {
    lockFile = lockFileOf (
      helloLock
      // {
        hexTarballs = map (
          t: t // { hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }
        ) helloLock.hexTarballs;
      }
    );
  };

  # A lockfile without the checkout of a git dependency in rebar.lock,
  # with a contentHash that matches it.
  conformance-missing = refused "missing" {
    fixture = ./fixtures/umbrella;
    lockFile = lockFileOf (
      withContentHash (
        umbrellaLock
        // {
          git = builtins.filter (g: g.rev != "c2a76855be3a226a3148c0dfc21ce000b6186ef8") umbrellaLock.git;
        }
      )
    );
  };

  # A lockfile that is not valid JSON.
  conformance-malformed = refused "malformed" {
    setup = "head -c 200 ${helloLockFile} > project/rebar3-purifier.lock.json";
  };

  # A build whose `src` holds no rebar3-purifier lockfile, from the
  # lockfile kept outside it.
  conformance-external = runCommand "conformance-external" { } ''
    test "$(${lib.getExe external.packages.escript-hello} Nix)" = '{"hello":"Nix"}'
    test "$(${lib.getExe externalBoth.packages.escript-hello} Nix)" = '{"hello":"Nix"}'
    touch $out
  '';

  # readLock gives the lock in the shape of the purifier contract, with the
  # outputs under the names of the packages.
  fixture-hello-read-lock =
    let
      lock = readLock { src = ./fixtures/hello; };
    in
    assert lock.purifier == "rebar3-purifier";
    assert lock.problems == [ ];
    assert
      builtins.attrNames lock.outputs == [
        "app-hello"
        "escript-hello"
        "hex-hello"
        "release-hello"
      ];
    runCommand "fixture-hello-read-lock" { } "touch $out";

  # The rebar3-purifier command, with its unit tests run in the build, and
  # the toolchain around it.
  inherit (extended.rebar3-purifier) cli toolchain;

  # readLock reads the version it supports and rejects any other.
  lock-version =
    assert readsVersion (import ../nix/lib/lock-version.nix);
    assert !(readsVersion 0);
    runCommand "lock-version" { } "touch $out";
}
