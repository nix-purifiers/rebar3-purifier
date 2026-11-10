{ pkgs }:
let
  build = pkgs.rebar3-purifier.buildRebar3Project;
  src = ./fixtures/umbrella;
  bad = [
    { nonexistent = [ "greeter" ]; }
    { umbrella = [ ]; }
    {
      umbrella = [
        "greeter"
        "greeter"
      ];
    }
    { umbrella = [ "recon" ]; }
    { umbrella = [ "../greeter" ]; }
  ];
  refused =
    otpApplications:
    !(builtins.tryEval (build { inherit src otpApplications; }).packages.default.drvPath).success;
  cross =
    if pkgs.stdenv.buildPlatform.isAarch64 then
      pkgs.pkgsCross.gnu64
    else
      pkgs.pkgsCross.aarch64-multiplatform;
  crossBuild = build.override { stdenv = cross.stdenv; };
in
assert builtins.all refused bad;
assert (build { inherit src; }).projections == { };
assert cross.stdenv.buildPlatform != cross.stdenv.hostPlatform;
assert
  !(builtins.tryEval
    (crossBuild {
      inherit src;
      otpApplications.umbrella = [ "greeter" ];
    }).packages.default.drvPath
  ).success;
true
