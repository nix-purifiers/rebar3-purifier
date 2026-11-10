{
  projectRoot,
  src ? null,
}:
let
  f = builtins.getFlake projectRoot;
  pkgs = import f.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ f.overlays.default ];
  };
in
pkgs.rebar3-purifier.buildRebar3Project {
  src = if src == null then ./fixtures/umbrella else /. + src;
  otpApplications.umbrella = [ "greeter" ];
}
