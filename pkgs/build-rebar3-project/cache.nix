# SPDX-License-Identifier: MIT
#
# The cache tree of a lock. Hex tarballs are under
# hex/<repository>/packages/, where rebar3 keeps them in its cache
# directory, as links into the store, with the package index and the etags
# beside them. Each git dependency is a bare repository under git/<commit>,
# made from the checkout with the .git directory the shared purifier
# library rebuilds, with the tags and branches rebar3 clones by. The
# rebar3-purifier command is the builder.
{
  lib,
  runCommand,
  fetchurl,
  fetchgit,
  unzip,
  zstd,
  python3,
  writeText,
  # The shared purifier library (`lib.purifier` of its flake).
  purifier,
  # Fetchers that replace the nixpkgs fetchers of the same names in the
  # fetchEntry of the purifier library.
  fetchers ? { },
  # The download entries of one system, from entriesFor of the purifier
  # library.
  entries,
  # The rebar3-purifier package.
  cli,
}:
let
  fetch = purifier.fetchEntry (
    {
      inherit
        runCommand
        fetchurl
        fetchgit
        unzip
        zstd
        python3
        writeText
        ;
    }
    // fetchers
  );
in
runCommand "rebar3-purifier-cache"
  {
    manifest = lib.concatMapStrings (e: "${e.path}\t${fetch e}\n") entries;
    entries = builtins.toJSON entries;
    passAsFile = [
      "manifest"
      "entries"
    ];
  }
  ''
    ${cli}/bin/rebar3-purifier build-cache
  ''
