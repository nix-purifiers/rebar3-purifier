{
  pkgs,
  src1 ? ./fixtures/umbrella,
  src2 ? null,
}:
let
  build =
    src:
    pkgs.rebar3-purifier.buildRebar3Project {
      inherit src;
      otpApplications.umbrella = [ "greeter" ];
    };
  secondSource =
    if src2 != null then
      src2
    else
      pkgs.runCommand "umbrella-genuine-hola-source" { } ''
        cp -r ${src1} "$out"
        chmod -R u+w "$out"
        substituteInPlace "$out/apps/greeter/src/greeter.erl" --replace-fail 'Hello, ~s' 'Hola, ~s'
      '';
  first = build src1;
  second = build secondSource;
  erlang = first.projections.umbrella.otp.runtime;
  elixir = pkgs.beam.packages.erlang_28.elixir;
  version = built: marker: {
    inherit marker;
    catalog = built.projections.umbrella.otp.catalog;
    library = built.projections.umbrella.otp.applicationRoot;
    web = built.projections.umbrella.web.documentRoot;
    jar = built.projections.umbrella.java-resources.classPath;
  };
  spec = pkgs.writeText "otp-consumer-spec.json" (
    builtins.toJSON {
      erlang = toString erlang;
      elixir = toString elixir;
      versions = [
        (version first "Hello")
        (version second "Hola")
      ];
    }
  );
in
assert import ./otp-eval.nix { inherit pkgs; };
pkgs.runCommand "compiled-otp-cross-language-consumers"
  {
    nativeBuildInputs = [
      pkgs.python3
      erlang
      elixir
      pkgs.jdk25
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    cp ${./otp/consumer.erl} otp_consumer.erl
    cp ${./otp/Resources.java} Resources.java
    python3 ${./otp/consumers.py} ${spec} "$out"
  ''
