# SPDX-License-Identifier: MIT
#
# readLock: the lockfiles of a rebar3 project, rebar.lock and the
# rebar3-purifier lockfile, read into the lock in memory that the purifier
# contract describes:
#
#   {
#     purifier = "rebar3-purifier";
#     entries  = [ <download entry of the purifier library> ];
#     outputs  = { <name> = { kind, name, ... }; };
#     problems = [ <why the lockfiles cannot be used> ];
#     otpRelease = "<the OTP release the lock was made with>";
#   }
#
# The flake publishes it as `lib.rebar3-purifier.readLock`.
#
# The entries are the Hex tarballs the lockfile records, an entry for each
# Hex package of rebar.lock with the outer checksum rebar.lock records,
# and a git entry for each checkout the lockfile records. A git entry
# carries `rebar3Sources`, the URLs rebar3 clones the checkout from, with
# the tags and branches it clones by.
#
# The outputs are named as the packages of buildRebar3Project are:
# `app-<name>` for an application of the project, `release-<name>` for a
# relx release, `escript-<name>` for the escript, and `hex-<name>` for the
# Hex package of an application.
#
# `problems` names the command that fixes each one: a missing lockfile,
# one of another format version, one changed after the lock wrote it, one
# older than a file that defines the dependencies, and one without a
# download for a dependency in rebar.lock. A lockfile that is not valid
# JSON fails evaluation instead, since Nix cannot catch that error; the
# error names the command too.
{ lib }:
{
  # The project directory, with rebar.config.
  src,
  # The lockfile. It may lie outside `src`, and then takes the place of any
  # lockfile in `src`.
  lockFile ? src + "/rebar3-purifier.lock.json",
  # The rebar.lock to read in place of the rebar.lock in `src`, for a build
  # that keeps its own copy outside the project.
  rebarLock ? null,
}:
let
  inherit (lib)
    any
    attrNames
    concatMap
    concatMapStrings
    concatStringsSep
    elem
    elemAt
    filter
    filterAttrs
    hasSuffix
    head
    isList
    listToAttrs
    nameValuePair
    optional
    ;

  name = toString lockFile;
  fix = "run `rebar3-purifier lock` and commit the lockfile";
  recover = "restore a valid lockfile or move this file aside before running `rebar3-purifier lock`";

  exists = builtins.pathExists lockFile;
  lock = builtins.addErrorContext "while reading the rebar3-purifier lockfile ${name}; if it is not valid JSON, ${recover}" (
    builtins.fromJSON (builtins.readFile lockFile)
  );
  supportedVersion = import ./lock-version.nix;

  sri =
    hex:
    builtins.convertHash {
      hash = hex;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  # The files that define the dependencies, as rp_util:definition_files/2
  # finds them: rebar.config and its script, rebar.lock, and the
  # rebar.config of each application under apps/ or lib/ that has a
  # src/*.app.src.
  rebarLockFile = if rebarLock != null then rebarLock else src + "/rebar.lock";
  has = f: builtins.pathExists (src + "/${f}");
  isDir = f: has f && builtins.readFileType (src + "/${f}") == "directory";
  isApp =
    d:
    isDir "${d}/src" && any (hasSuffix ".app.src") (attrNames (builtins.readDir (src + "/${d}/src")));
  appDirs =
    concatMap
      (
        base:
        if isDir base then
          filter isApp (
            map (n: "${base}/${n}") (
              attrNames (
                filterAttrs (_: t: t == "directory" || t == "symlink") (builtins.readDir (src + "/${base}"))
              )
            )
          )
        else
          [ ]
      )
      [
        "apps"
        "lib"
      ];
  definitionFiles = builtins.sort builtins.lessThan (
    filter has [
      "rebar.config"
      "rebar.config.script"
    ]
    ++ optional (builtins.pathExists rebarLockFile) "rebar.lock"
    ++ concatMap (
      d:
      filter has [
        "${d}/rebar.config"
        "${d}/rebar.config.script"
      ]
    ) appDirs
  );
  definitionPath = f: if f == "rebar.lock" then rebarLockFile else src + "/${f}";
  definitionHash = sri (
    builtins.hashString "sha256" (
      concatMapStrings (f: "${f}\t${builtins.hashFile "sha256" (definitionPath f)}\n") definitionFiles
    )
  );

  # rebar.lock is an Erlang term, which Nix cannot parse, so these regular
  # expressions read the shapes rebar3 writes: `{<<"name">>,{pkg,
  # <<"package">>,<<"version">>},level}` for a Hex dependency,
  # `{git,"url",{ref,"commit"}}` and `{git_subdir,"url",{ref,"commit"},
  # "dir"}` for a git dependency, and `{<<"name">>,<<"checksum">>}` in the
  # `pkg_hash_ext` list of outer checksums, the SHA-256 of each tarball.
  rebarLockText = if builtins.pathExists rebarLockFile then builtins.readFile rebarLockFile else "";
  matchesIn = text: re: filter isList (builtins.split re text);
  hexDeps =
    map
      (m: {
        name = elemAt m 0;
        file = "${elemAt m 1}-${elemAt m 2}.tar";
      })
      (
        matchesIn rebarLockText ''[{]<<"([^"]+)">>,[[:space:]]*[{]pkg,[[:space:]]*<<"([^"]+)">>,[[:space:]]*<<"([^"]+)">>''
      );
  outerChecksums = listToAttrs (
    map (m: nameValuePair (elemAt m 0) (elemAt m 1)) (
      matchesIn (lib.last (builtins.split "pkg_hash_ext" rebarLockText)) ''[{]<<"([^"]+)">>,[[:space:]]*<<"([0-9A-Fa-f]{64})">>[}]''
    )
  );
  lockedGit =
    map
      (m: {
        url = elemAt m 1;
        rev = elemAt m 2;
      })
      (
        matchesIn rebarLockText ''[{]git(_subdir)?,[[:space:]]*"([^"]+)",[[:space:]]*[{]ref,[[:space:]]*"([0-9a-f]{40})"[}]''
      );

  # The download entry of each Hex package of rebar.lock with an outer
  # checksum, from hexpm, unless the lockfile records the tarball, as it
  # does for a package from another repository. rp_util:derived_hex/1
  # derives the same entries.
  recordedTarballs = map (t: baseNameOf t.path) lock.hexTarballs;
  derivedHex = map (d: {
    path = "hex/hexpm/packages/${d.file}";
    url = "https://repo.hex.pm/tarballs/${d.file}";
    mirrors = [ ];
    hash = sri (lib.toLower outerChecksums.${d.name});
  }) (filter (d: outerChecksums ? ${d.name} && !elem d.file recordedTarballs) hexDeps);

  # The git entry of each checkout the lockfile records, fetched from its
  # `url`, or from the URL rebar.lock names for its commit. rebar3 clones
  # it from the URLs of its sources, and from the URL rebar.lock names.
  lockedUrls = rev: map (l: l.url) (filter (l: l.rev == rev) lockedGit);
  gitEntry =
    g:
    let
      urls = optional (g ? url) g.url ++ lockedUrls g.rev;
    in
    {
      path = "git/${g.rev}";
      git = {
        url =
          if urls != [ ] then
            head urls
          else
            throw "rebar3-purifier: ${name} records the git commit ${g.rev} without a URL, and rebar.lock does not name it; ${fix}";
        inherit (g) rev commitObject;
        submodules = false;
        leaveDotGit = true;
      };
      inherit (g) hash;
      rebar3Sources =
        g.sources
        ++ map (url: {
          inherit url;
          tags = [ ];
          branches = [ ];
        }) (lockedUrls g.rev);
    };

  # The dependencies in rebar.lock without a download: a Hex package
  # without its outer checksum and without a recorded tarball, or a git
  # dependency without its checkout.
  revs = map (g: g.rev) lock.git;
  missing =
    map (d: d.file) (filter (d: !(outerChecksums ? ${d.name}) && !elem d.file recordedTarballs) hexDeps)
    ++ map (l: "${l.url} at ${l.rev}") (filter (l: !elem l.rev revs) lockedGit);

  readable =
    if !exists then
      "rebar3-purifier: ${name} does not exist; run `rebar3-purifier lock`"
    else if !(builtins.isAttrs lock && lock ? version) then
      "rebar3-purifier: ${name} is not a rebar3-purifier lockfile; ${recover}"
    else if lock.version != supportedVersion then
      "rebar3-purifier: ${name} has lock format version ${builtins.toJSON lock.version}, and this library reads version ${toString supportedVersion}; ${recover}"
    else if lock.contentHash or null != import ./content-hash.nix lock then
      "rebar3-purifier: ${name} does not match its contentHash, so it was changed after `rebar3-purifier lock` wrote it; ${recover}"
    else
      null;

  problems =
    if readable != null then
      [ readable ]
    else
      optional (lock.definitionHash != definitionHash)
        "rebar3-purifier: ${name} is out of date, because one of ${concatStringsSep ", " definitionFiles} changed since it was written; ${fix}"
      ++
        optional (missing != [ ])
          "rebar3-purifier: rebar.lock names dependencies that ${name} has no download for: ${concatStringsSep ", " missing}; ${fix}";

  named =
    kind: prefix: list:
    map (x: nameValuePair "${prefix}-${x.name}" (x // { inherit kind; })) list;
in
{
  purifier = "rebar3-purifier";
  inherit problems;
  entries = if readable != null then [ ] else lock.hexTarballs ++ derivedHex ++ map gitEntry lock.git;
  outputs =
    if readable != null then
      { }
    else
      listToAttrs (
        named "app" "app" lock.outputs.apps
        ++ named "release" "release" (map (name: { inherit name; }) lock.outputs.releases)
        ++ named "escript" "escript" (map (name: { inherit name; }) lock.outputs.escripts)
        ++ named "hexPackage" "hex" lock.outputs.hexPackages
      );
  otpRelease = if readable != null then null else lock.otpRelease;
}
