# SPDX-License-Identifier: MIT
#
# The cache tree the rebar3 wrapper and `rebar3-purifier prefetch` build,
# from the nixpkgs and the shared purifier library the toolchain names.
# `nix-build` of this file fetches every entry, and its out link is the GC
# root that keeps them alive.
{
  # The project directory, as an absolute path.
  src,
  # The lockfile, as an absolute path.
  lockFile,
  # The rebar.lock to read in place of the one in `src`, as an absolute
  # path.
  rebarLock ? null,
  # The rebar3-purifier command, as an absolute path into the store.
  cli,
  # The nixpkgs to fetch with.
  nixpkgs,
  # The source of the shared purifier library.
  purifierSrc,
}:
let
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;
  purifier = import (builtins.storePath purifierSrc + "/nix/lib") { inherit lib; };
  readLock = import ../../lib-overlays/default/read-lock.nix { inherit lib; };
  match = builtins.match "(${builtins.storeDir}/[^/]+)/bin/rebar3-purifier" cli;
in
assert match != null || throw "rebar3-purifier: the command ${cli} is not in the Nix store";
import ./cache.nix {
  inherit lib purifier;
  inherit (pkgs)
    runCommand
    fetchurl
    fetchgit
    unzip
    zstd
    python3
    writeText
    ;
  entries = purifier.entriesFor pkgs.stdenv.hostPlatform.system (readLock {
    inherit src lockFile rebarLock;
  });
  cli = builtins.storePath (builtins.head match);
}
