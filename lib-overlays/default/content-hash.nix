# SPDX-License-Identifier: MIT
#
# The contentHash of a lockfile: the SHA-256, as an SRI hash, of the
# lockfile without its contentHash, as builtins.toJSON writes it.
# rp_util:content_hash/1 computes the same hash when it writes a lockfile.
lock:
builtins.convertHash {
  hash = builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "contentHash" ]));
  hashAlgo = "sha256";
  toHashFormat = "sri";
}
