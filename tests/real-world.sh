#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Works through rebar3-purifier on a real open-source project, pinned to a
# commit, the way a developer would: clone it, lock it, build its escript
# with buildRebar3Project in the Nix sandbox and run it, compile it with
# the offline rebar3, and relock to check that the lockfile is reproduced
# byte for byte. It runs the project's build, which needs the network and
# Nix, so it runs in CI rather than in the Nix sandbox.
#
# Usage: tests/real-world.sh TOOLCHAIN PROJECT
# where TOOLCHAIN is the output of `nix build .#toolchain` and PROJECT is
# one of the projects below.
set -euo pipefail
if [ -n "${TRACE:-}" ]; then set -x; fi

toolchain=$(cd "${1:?usage: real-world.sh TOOLCHAIN PROJECT}" && pwd)
project=${2:?usage: real-world.sh TOOLCHAIN PROJECT}
share="$toolchain/share/rebar3-purifier"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME"
export PATH="$toolchain/bin:$PATH"

# Each project: its repository, the pinned commit, its escript, and the
# arguments the escript is run with.
case "$project" in
  erlang_ls)
    # The Erlang language server: two applications, Hex dependencies (one
    # renamed), git dependencies by commit and by tag, Hex plugins and a
    # git plugin by branch, and an escript.
    url=https://github.com/erlang-ls/erlang_ls.git
    rev=3a791859ef6a9216f96b8a1f19b38be6d8ba51d3
    escript=erlang_ls
    args=(--version)
    ;;
  elvis)
    # The Erlang style checker: Hex dependencies, Hex plugins including
    # rebar3_hex with an ex_doc documentation provider, and an escript.
    url=https://github.com/inaka/elvis.git
    rev=c4ca8fa918c9096c6e4d5d995ed03d86c6a3f0bb
    escript=elvis
    args=(--version)
    ;;
  *)
    echo "unknown project $project" >&2
    exit 2
    ;;
esac

# The physical path: builtins.readFileType refuses a path through a
# symlink, such as macOS's /var.
src="$(cd "$work" && pwd -P)/$project"
git clone -q "$url" "$src"
cd "$src"
git checkout -q "$rev"

start=$SECONDS
rebar3-purifier lock
echo "$project: lock took $((SECONDS - start)) s"

cli=$(readlink -f "$share/cli")
purifier=$(readlink -f "$share/purifier")
expr="let pkgs = import $share/nixpkgs { }; build = pkgs.callPackage $share/nix-lib/build-rebar3-project.nix { purifier = import (builtins.storePath \"$purifier\" + \"/nix/lib\") { inherit (pkgs) lib; }; cli = builtins.storePath \"$cli\"; }; in (build { src = $src; }).packages.escript-$escript"
built=$(nix-build --no-out-link -E "$expr")
"$built/bin/$escript" "${args[@]}"
echo "$project: sandboxed build: ok"

http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
  HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 rebar3 compile
echo "$project: offline compile: ok"

cp rebar3-purifier.lock.json "$work/first.lock.json"
start=$SECONDS
rebar3-purifier lock
echo "$project: relock took $((SECONDS - start)) s"
cmp rebar3-purifier.lock.json "$work/first.lock.json"
echo "$project: relock reproduced the lockfile: ok"
