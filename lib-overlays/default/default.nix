# SPDX-License-Identifier: MIT
#
# The `rebar3-purifier` library namespace: `readLock`
# (lib-overlays/default/read-lock.nix), which reads the lockfiles of a project into the
# lock in memory of the purifier contract.
{ ... }:
{

  overlay = final: prev: {
    rebar3-purifier = {
      readLock = import ./read-lock.nix { lib = final; };
    };
  };

}
