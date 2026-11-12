{ pkgs }:
let
  built = pkgs.rebar3-purifier.buildRebar3Project { src = ./fixtures/umbrella; };
  runtime = built.packages.default.nativeBuildInputs;
  erlang = builtins.head runtime;
  roots = [ "greeter" ];
  selection =
    producer: runtime:
    pkgs.rebar3-purifier.callPackage ../pkgs/build-rebar3-project/otp-projections.nix { } {
      inherit producer roots;
      release = "umbrella";
      ownApplications = [
        "greeter"
        "server"
      ];
      erlang = runtime;
      otpRelease = "28";
    };
  # These are explicit adversarial copies of a real relx producer, using real
  # compiled SDK/project bytes. They are not claimed as fresh native captures.
  mutated =
    name: command:
    pkgs.runCommand "otp-controlled-${name}" { } ''
      mkdir -p "$out/releases/umbrella"
      cp -rL ${built.packages.default}/releases/umbrella/lib "$out/releases/umbrella/"
      cp -rL ${built.packages.default}/releases/umbrella/releases "$out/releases/umbrella/"
      chmod -R u+w "$out"
      ${command}
    '';
in
{
  wrongSdk = (selection built.packages.default pkgs.beam.packages.erlang_27.erlang).producer;
  sdkCollision =
    (selection (mutated "sdk-module" ''
      cp ${erlang}/lib/erlang/lib/stdlib-*/ebin/sets.beam "$out/releases/umbrella/lib/greeter-1.0.0/ebin/"
    '') erlang).producer;
  duplicateModule =
    (selection (mutated "duplicate-module" ''
      cp "$out/releases/umbrella/lib/greeter-1.0.0/ebin/greeter.beam" "$out/releases/umbrella/lib/server-1.0.0/ebin/"
    '') erlang).producer;
  nativePayload =
    (selection (mutated "actual-native-payload" ''
      mkdir -p "$out/releases/umbrella/lib/greeter-1.0.0/priv"
      cp ${erlang}/lib/erlang/erts-*/bin/erl_child_setup "$out/releases/umbrella/lib/greeter-1.0.0/priv/helper"
    '') erlang).producer;
}
