# rebar3-purifier

rebar3-purifier keeps rebar3's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

It supports x86_64-linux and aarch64-linux.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/rebar3-purifier'
rebar3-purifier lock
rebar3 compile
rebar3 eunit
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

The shell provides the `rebar3` wrapper. Use it for the locked
development workflow. With no purifier lockfile, it warns on standard
error and runs the ordinary tool with impure resolution.

For persistent use, add these packages through your usual Nix configuration.


## Development loop

`nix shell 'github:nix-purifiers/rebar3-purifier'` gives a shell with
`rebar3`, the Erlang tools, `elp` and `rebar3-purifier`. Run rebar3 as
usual: `rebar3 compile`, `rebar3 eunit`, `rebar3 ct`, `rebar3 shell`,
`rebar3 release`. In a project with a lockfile, `rebar3` first builds the
cache tree of the lockfile through Nix, and runs with:

- `REBAR_CACHE_DIR` at `_build/rebar3-purifier/cache`, a writable copy of
  the tree: links to the locked tarballs, with the package index and etags
  rebar3 reads beside them;
- `HEX_CDN` at an address that refuses connections, so rebar3 takes every
  Hex tarball from the cache;
- git redirected, with `url.<repository>.insteadOf`, from each locked git
  URL to a repository in the store that holds the locked commit.

A dependency that is not in the lockfile fails to fetch, with the message
of rebar3. A project without a lockfile resolves the usual way.
`REBAR3_PURIFIER=0` turns interactive mode off.

The commands:

- `rebar3-purifier lock` runs rebar3 in a copy of the project on the
  `default`, `test` and `prod` profiles
  (`--profile <name>` adds one), and records what rebar3 downloaded and
  what the build produces. It keeps the resolution of `rebar.lock`. A
  relock of unchanged definitions and profiles replays the recorded cache and
  package index, including plugin versions, and writes the same bytes. A
  missing recorded download fails instead of resolving a newer version.
  A first capture, changed definitions, or additional profiles resolve afresh
  with empty caches and the network.
  An existing malformed or checksum-invalid lock is an error; restore a valid
  lockfile or move the invalid file aside before a fresh capture.
- `rebar3-purifier update [<package>...]` runs `rebar3 upgrade` on every
  dependency, or on the named ones, and then locks.
- `rebar3-purifier prefetch` is described under Working offline.
- `rebar3-purifier publish [--dry-run] [<application>...]` builds the
  `release` through Nix and uploads those tarballs to Hex with the Hex
  client of rebar3. `HEX_API_KEY` holds the key, `HEX_API_URL` replaces the
  default API (`https://hex.pm/api`), and `HEX_ORGANIZATION` publishes into
  an organization. `--dry-run` builds the tarballs and prints their paths.

rebar3 has a plugin mechanism, and rebar3-purifier is a separate command
that runs beside it. `lock` runs rebar3 itself in a copy of the project
with empty caches, and the `rebar3` of the toolchain sets the Hex and git
environment before rebar3 starts. A plugin runs inside rebar3, after it has
read its cache and configuration, so it cannot do either.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

The overlay of the flake adds one attribute to a package set, the scope
`rebar3-purifier`. The scope holds the builder `buildRebar3Project` beside
the command and the toolchain. A project whose authors want a flake can
package itself by calling the builder directly. The flake can live in the
repository of the project or in another one:

```nix
{
  inputs.rebar3-purifier.url =
    "github:nix-purifiers/rebar3-purifier";
  inputs.nixpkgs.follows = "rebar3-purifier/nixpkgs";

  outputs =
    { nixpkgs, rebar3-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rebar3-purifier.overlays.default ];
      };
      project =
        pkgs.rebar3-purifier.buildRebar3Project {
        src = ./.;
      };
    in
    {
      packages.${system}.default =
        project.packages.release-my_app;
      checks.${system}.tests = project.tests;
    };
}
```

`buildRebar3Project { src, lockFile ? ..., fetchers ? { }, ... }` returns:

- `packages.default`, one derivation with every output;
- `packages.app-<name>`, each application of the project, compiled, in
  `lib/<name>` (its `ebin`, `priv` and `include`);
- `packages.release-<name>`, each relx release, built with the `prod`
  profile, with its start script as `bin/<name>` and on its `PATH` the tools
  the script needs;
- `packages.escript-<name>`, the escript, when `rebar.config` sets
  `escript_main_app` or `escript_name`;
- `tests`, `rebar3 eunit` and, when the project has common test suites,
  `rebar3 ct`, run in the sandbox;
- `release`, the Hex package tarballs, which `rebar3-purifier publish`
  uploads;
- `fetches`, the entries of the shared
  [purifier](https://github.com/nix-purifiers/purifier) library that the
  build fetches, for SBOM, license and vulnerability tools;
- `cache`, the tree of the locked downloads.

Every attribute name is known at evaluation time, with no
import-from-derivation. `fetchers` replaces the fetchers of the library,
for a company mirror or for credentials: `fetchers.fetchurl` is a
`fetchurl` with them. `buildRebar3Project.override` replaces the packages the
builder takes, and `rebar3-purifier.overrideScope` replaces what the
packages of the scope share. `lib.rebar3-purifier.readLock { src,
lockFile ? ..., rebarLock ? ... }` reads the lockfiles into the lock in
memory that the nix-purifiers share.

The other arguments are `beamPackages` (the default is the one of the OTP
release the lock was made with, when nixpkgs has it), `cli`,
`releaseProfile`, `buildInputs`, `nativeBuildInputs` and `srcFilter`.
`pkgs/build-rebar3-project/build-rebar3-project.nix` documents them.

We recommend committing both `rebar3-purifier.lock.json` and `rebar.lock`
to the repository. The builder and the commands look for them there.

A build can instead keep the lockfiles outside the repository, for a
project whose committed lockfiles are missing or stale. The flake that
calls the builder passes `lockFile`, and `rebarLock` when it also keeps a
copy of `rebar.lock`, and the build uses them in place of the copies in
`src`. The commands take `--lockfile <path>` and `--tool-lockfile <path>`,
or the variables `REBAR3_PURIFIER_LOCKFILE` and
`REBAR3_PURIFIER_TOOL_LOCKFILE`. With either, `lock` and `update` write
the lockfile at that path and leave the copy in the tree as it is, and
`lock` starts from the copy of `rebar.lock` in the tree while the one
outside does not exist.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/rebar3-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.rebar3-purifier.buildRebar3Project { src = ./.; })
.packages.default'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

`rebar3-purifier prefetch` realizes in the Nix store everything the
lockfile lists for the current system: the Hex tarballs and the git
checkouts of every profile, and the toolchain, which holds Erlang, rebar3
and the Erlang Language Platform (`elp`). It keeps them alive with
garbage-collector roots in `.rebar3-purifier-gcroots` beside the
lockfile, which `.gitignore` should list. After a prefetch, `rebar3 compile`,
`rebar3 eunit`, `rebar3 release` and the editor work with the network cut
off.

## Editor

The toolchain has `elp`, the
[Erlang Language Platform](https://whatsapp.github.io/erlang-language-platform/),
which loads the project by running rebar3. Run your editor inside
`nix shell`, or put the toolchain on its `PATH`, and `elp` finds the
rebar3 of the toolchain, which reads the locked downloads. After a
prefetch the editor needs no network.

## Troubleshooting

Every lockfile problem stops the build and the commands with a message that
names the command that fixes it, and the same messages appear at Nix
evaluation.

| Problem | Message names |
| --- | --- |
| The lockfile does not exist | `rebar3-purifier lock` |
| The lockfile is not valid JSON, or not a rebar3-purifier lockfile | restore a valid lockfile, or move the invalid file aside before `rebar3-purifier lock` |
| The lockfile has another format version | restore a valid lockfile, or move the invalid file aside before `rebar3-purifier lock` |
| The lockfile was changed after `lock` wrote it (its `contentHash` differs) | restore a valid lockfile, or move the invalid file aside before `rebar3-purifier lock` |
| `rebar.config`, `rebar.lock` or the `rebar.config` of an application changed since the lock | `rebar3-purifier lock` |
| `rebar.lock` names a dependency that has no download | `rebar3-purifier lock` |
| A download has another hash than the lockfile records | the build fails in the fetcher, which names the hash |

To move dependencies to newer releases, run `rebar3-purifier update`.

## Supported language repositories

The purifier fetches Hex packages from `https://repo.hex.pm`, from
`HEX_CDN` or `HEX_MIRROR`, from `hexpm:<organization>`, and from a
repository that `rebar.config` or your global rebar3 configuration names
under `hex`. The checksum of a Hex package of `rebar.lock` is its outer
checksum, the SHA-256 of the tarball, and the build checks the download
against it.

It fetches git dependencies and `git_subdir` dependencies by commit, tag or
branch, and git plugins. The lockfile records the hash of the checkout and
the raw commit object, and the build rebuilds the repository from them. An
SSH URL is recorded as the HTTPS URL of the same host, since the Nix
sandbox has no SSH keys. Git submodules are not checked out, as rebar3 does
not check them out.

Plugins, the dependencies of the `test` and `prod` profiles, and the
dependencies of extra profiles added with `--profile` are locked in the same
way.

A few limits apply. A plugin or a build hook that downloads files itself
fails in the sandbox, and C libraries for NIFs and port drivers come from
`buildInputs`. The lock run downloads tarballs from a Hex repository that
needs credentials with your credentials and adds them to the Nix store,
where the build finds them, so another machine needs a `fetchurl` with
credentials in `fetchers`. Your global rebar3 configuration is in effect
during the lock run but not in the sandbox, so the lock run downloads a
plugin that only the global configuration names and the build does not load
it.

`rebar.lock` cannot record everything the build downloads, so the purifier
writes `rebar3-purifier.lock.json` for the rest. `rebar.lock` is the
resolution of the default profile, and it holds the outer checksum of every
Hex package in it, so the lockfile does not repeat them. The lockfile holds
the Hex tarballs that `rebar.lock` does not list (plugins and the other
profiles), the hash and commit object of each git checkout, the outputs of
the build, and the hash of the files that define the dependencies.
`rebar.lock` is an Erlang term, which Nix cannot parse, so Nix reads the
shapes rebar3 writes with regular expressions, and the command reads it
with `file:consult`.

Three more decisions:

- **The package index is generated.** rebar3 reads the Hex registry for
  every Hex dependency before it takes the cached tarball. Registry records
  change with every release, so they cannot be locked by hash. Each Hex
  tarball carries the checksums and requirements the registry holds for its
  version, so the build writes the index rebar3 reads (`hex/packages.idx`,
  format 7) from the locked tarballs, and the etag file beside each.
- **Versions from git are pinned.** An application whose `.app.src` takes
  its version from git (`{vsn, git}`) cannot compute it in the sandbox. The
  lock run records the version, and the build writes it into its copy of the
  `.app.src`.
- **Erlang and rebar3 come from nixpkgs.** The lockfile records the OTP
  release and the rebar3 version of the lock for reference.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### erlang_ls

[erlang_ls](https://github.com/erlang-ls/erlang_ls) is a language server
for Erlang, built as an escript. To build it with Nix, clone it, lock it,
and build it from the checkout:

```zsh
nix shell 'github:nix-purifiers/rebar3-purifier'
git clone https://github.com/erlang-ls/erlang_ls
cd erlang_ls
rebar3-purifier lock
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/rebar3-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.rebar3-purifier.buildRebar3Project { src = ./.; })
.packages.escript-erlang_ls'
./result/bin/erlang_ls --version
```

### elvis

[elvis](https://github.com/inaka/elvis) is a style checker for Erlang, also
an escript, with Hex plugins. The steps are the same. Clone it, run the
`lock` command in the checkout, and build it with
`packages.escript-elvis` in place of `packages.escript-erlang_ls`. The
result is `result/bin/elvis`.

### Your own project

The same steps apply to a project of your own. The package to build is
`packages.release-<name>` for a relx release, `packages.escript-<name>` for
an escript, or `packages.app-<name>` for an application, and the `tests`
attribute of the builder is the test run that goes into the `checks` of a
flake.

## Compiled OTP applications across consumers

Select project application roots from an existing locked relx release:

```nix
project = pkgs.rebar3-purifier.buildRebar3Project {
  src = ./.;
  otpApplications.umbrella = [ "greeter" ];
};
```

`project.packages.otp-umbrella` contains compiled non-SDK applications and
`catalog.json`. `project.projections.umbrella` exposes `otp`, `resources`,
`web`, and `java-resources`. The `otp` value provides `applicationRoot`
(for `ERL_LIBS`), `runtime` (the matching Erlang SDK), and `catalog`.
The web tree and Java resource JAR carry the same application files;
extract them before running them with Erlang or Elixir.

The native release descriptor determines the application closure. Application
versions, module ownership, dependency declarations, and compiled bytes are
checked against that release. SDK applications stay in the original runtime.
Native relx stripping may remove debug chunks, so SDK validation compares
native code MD5 and all nondebug BEAM chunks, recording both original and
release byte hashes. It does not assert raw SDK BEAM byte equality.

This projection requires native Linux, OTP 27 or later, and matching OTP and
ERTS versions. Duplicate module owners, SDK module shadows, and non-SDK native
binaries or NIF payloads are rejected. Such payloads need separate runtime
proof before they can be supported. Existing packages and defaults remain
available without selecting `otpApplications`.

Checks start applications and call their dependencies in fresh Erlang and
Elixir VMs, verify every selected module's loaded bytes and origin, and read
Java resources through an isolated class loader. Two genuinely compiled
producer revisions exercise native, HTTP-served, and JAR-carried files.
Missing dependencies, replacement modules, incompatible SDKs, duplicate
owners, and actual native payloads have separate negative controls.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

Released under the MIT license; see [LICENSE](LICENSE).
