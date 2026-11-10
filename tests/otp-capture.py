"""Select the compiled applications from a fresh native Rebar capture."""
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
sdk = Path(subprocess.check_output(["nix", "build", str(repo) + "#toolchain", "--no-link", "--print-out-paths"], text=True).strip())
with tempfile.TemporaryDirectory(prefix="compiled OTP native capture ") as temporary:
    root = Path(temporary) / "umbrella"
    shutil.copytree(repo / "tests/fixtures/umbrella", root, ignore=shutil.ignore_patterns("_build", ".rebar3-purifier-gcroots"))
    (root / "rebar3-purifier.lock.json").unlink()
    subprocess.run([sdk / "bin/rebar3-purifier", "lock"], cwd=root, check=True, timeout=600)
    second = Path(temporary) / "umbrella-hola"
    shutil.copytree(root, second, ignore=shutil.ignore_patterns("_build", ".rebar3-purifier-gcroots"))
    module = second / "apps/greeter/src/greeter.erl"
    original = module.read_text()
    assert "Hello, ~s" in original
    module.write_text(original.replace("Hello, ~s", "Hola, ~s"))
    output = subprocess.check_output(["nix", "build", "--impure", "--no-link", "--print-out-paths", "--file",
        str(repo / "tests/otp-consumer-build.nix"), "--argstr", "projectRoot", str(repo), "--argstr", "src1", str(root), "--argstr", "src2", str(second)], text=True).strip()
    assert (Path(output) / "0-native-erlang.json").exists()
print("Fresh native Rebar capture replayed through both languages and all resource carriers")
