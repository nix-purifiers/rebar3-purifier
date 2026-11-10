{
  lib,
  stdenv,
  runCommand,
  python3,
  writeText,
  purifier,
}:
{
  producer,
  release,
  roots,
  ownApplications,
  erlang,
  otpRelease,
}:
let
  name = s: builtins.isString s && builtins.match "[a-z][A-Za-z0-9_@]*" s != null;
  spec = writeText "otp-application-selection.json" (
    builtins.toJSON {
      inherit
        release
        roots
        ownApplications
        otpRelease
        ;
      runtime = toString erlang;
      system = stdenv.hostPlatform.system;
    }
  );
  selected =
    runCommand "${release}-compiled-otp-applications"
      {
        nativeBuildInputs = [
          erlang
          python3
        ];
      }
      ''
        export ERL_LIBS="" ERL_FLAGS="" ERL_AFLAGS=""
        ${erlang}/bin/escript ${./otp-release.escript} ${producer} ${spec} plan.json
        python3 ${./otp-copy.py} ${producer} plan.json "$out"
      '';
  otp = selected // {
    applicationRoot = "${selected}/lib";
    catalog = "${selected}/catalog.json";
    runtime = erlang;
    system = stdenv.hostPlatform.system;
  };
  resources = purifier.resourceProjections {
    producer = selected;
    roots."." = "lib";
    inherit runCommand python3;
  };
in
assert lib.assertMsg
  (
    builtins.isList roots
    && roots != [ ]
    && lib.unique roots == roots
    && builtins.all (root: name root && builtins.elem root ownApplications) roots
  )
  "rebar3-purifier: otpApplications selects distinct project applications from a locked native release";
assert lib.assertMsg (
  lib.versionAtLeast erlang.version "27"
  && stdenv.hostPlatform.isLinux
  && stdenv.buildPlatform == stdenv.hostPlatform
) "rebar3-purifier: compiled OTP projections currently require a native Linux OTP27+ SDK";
{
  validated = true;
  producer = selected;
  projections = resources // {
    inherit otp;
  };
  package = selected // {
    projections = resources // {
      inherit otp;
    };
  };
}
