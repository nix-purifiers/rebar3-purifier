# SPDX-License-Identifier: MIT
#
# Erlang and rebar3 of the package set, with `rebar3` replaced by a wrapper
# under that name. It runs the real rebar3 against the locked downloads of
# a build that has a current rebar3-purifier.lock.json, and the usual way
# otherwise. `rebar3-purifier` sits beside it, for `rebar3-purifier lock`
# `rebar3-purifier prefetch` and `rebar3-purifier publish`. `elp`, the
# Erlang Language Platform, is the language server for editors, and runs
# the wrapper too.
#
# Both take git, for git dependencies, and nix-prefetch-git, for locking
# them, from the end of PATH, so a git on the user's PATH comes first. The
# wrapper and `rebar3-purifier publish` build with the nixpkgs of this
# package set unless REBAR3_PURIFIER_NIXPKGS names another.
{
  lib,
  runCommand,
  makeWrapper,
  runtimeShell,
  beamPackages,
  git,
  nix-prefetch-git,
  erlang-language-platform,
  path,
  cli,
  # The source of the shared purifier library; the package overlay passes
  # the flake's `purifier` input.
  purifierSrc ? null,
}:
let
  runtimeSource = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../lib-overlays/default
      ../build-rebar3-project
    ];
  };
  inherit (beamPackages) erlang rebar3;
  wrapperArgs = lib.escapeShellArgs [
    "--set"
    "REBAR3_PURIFIER_PURIFIER_SRC"
    "${purifierSrc}"
    "--set"
    "REBAR3_PURIFIER_REBAR3"
    "${rebar3}/bin/rebar3"
    "--set"
    "REBAR3_PURIFIER_NIX_LIB"
    "${runtimeSource}/pkgs/build-rebar3-project"
    "--set-default"
    "REBAR3_PURIFIER_NIXPKGS"
    "${path}"
    "--suffix"
    "PATH"
    ":"
    (lib.makeBinPath [
      git
      nix-prefetch-git
    ])
  ];
in
runCommand "rebar3-purifier-toolchain-${rebar3.version}"
  {
    nativeBuildInputs = [ makeWrapper ];
    passthru = { inherit erlang rebar3 cli; };
    meta = {
      description = "rebar3 with its downloads from a rebar3-purifier lockfile";
      mainProgram = "rebar3-purifier";
    };
  }
  ''
    mkdir -p "$out/bin"
    for tool in ${erlang}/bin/*; do
      ln -s "$tool" "$out/bin/$(basename "$tool")"
    done
    ln -s ${erlang-language-platform}/bin/elp "$out/bin/elp"
    # `rebar3-purifier prefetch` keeps the toolchain alive with a GC root.
    makeWrapper ${lib.getExe cli} "$out/bin/rebar3-purifier" ${wrapperArgs} \
      --set REBAR3_PURIFIER_TOOLCHAIN "$out"
    cat > "$out/bin/rebar3" <<EOF
    #!${runtimeShell}
    env=\$("$out/bin/rebar3-purifier" env) || exit \$?
    eval "\$env"
    exec ${rebar3}/bin/rebar3 "\$@"
    EOF
    chmod +x "$out/bin/rebar3"
    # What the wrapper builds with, for scripts that build a project the
    # same way: the nixpkgs, the Nix library, the command and the shared
    # purifier library.
    mkdir -p "$out/share/rebar3-purifier/nix-lib"
    ln -s ${path} "$out/share/rebar3-purifier/nixpkgs"
    # Keep the installed entrypoints usable through this public alias. Nix
    # resolves relative imports from the alias's location, so each entrypoint
    # imports the canonical source path rather than exposing a directory link.
    cat > "$out/share/rebar3-purifier/nix-lib/read-lock.nix" <<EOF
    import ${runtimeSource}/lib-overlays/default/read-lock.nix
    EOF
    for entrypoint in build-rebar3-project realize; do
      cat > "$out/share/rebar3-purifier/nix-lib/$entrypoint.nix" <<EOF
    import ${runtimeSource}/pkgs/build-rebar3-project/$entrypoint.nix
    EOF
    done
    ln -s ${cli} "$out/share/rebar3-purifier/cli"
    ln -s ${purifierSrc} "$out/share/rebar3-purifier/purifier"
  ''
