# SPDX-License-Identifier: MIT
#
# The packages of the rebar3-purifier scope, `pkgs.rebar3-purifier`. The
# package overlay adds `purifier`, the shared purifier library, and
# `purifierSrc`, its source, to the scope.
{ callPackage, ... }:
let
  cli = callPackage ./cli { };
in
{
  # The rebar3-purifier command.
  inherit cli;
  # Erlang and rebar3 with `rebar3` running through rebar3-purifier, and
  # the rebar3-purifier command beside it.
  toolchain = callPackage ./toolchain { inherit cli; };
  # The sandboxed build of a rebar3 project (pkgs/build-rebar3-project/build-rebar3-project.nix).
  # A package written for callPackage takes the scope by name.
  buildRebar3Project = callPackage ./build-rebar3-project/build-rebar3-project.nix { };
}
