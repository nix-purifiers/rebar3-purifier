{
  projectRoot,
  src1 ? null,
  src2 ? null,
}:
let
  f = builtins.getFlake projectRoot;
  pkgs = import f.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ f.overlays.default ];
  };
in
import ./otp-projections.nix (
  {
    inherit pkgs;
  }
  // pkgs.lib.optionalAttrs (src1 != null) { src1 = /. + src1; }
  // pkgs.lib.optionalAttrs (src2 != null) { src2 = /. + src2; }
)
