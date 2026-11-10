"""Rebuild the compiled native producers, OTP views and actual consumers."""
import json
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parent.parent
system = subprocess.check_output(["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"], text=True).strip()
outputs = subprocess.check_output(["nix", "build", "--no-link", "--print-out-paths",
    str(repo) + "#checks." + system + ".fixture-otp-applications",
    str(repo) + "#checks." + system + ".fixture-otp-consumers"], text=True).splitlines()
consumer = next(Path(p) for p in outputs if (Path(p) / "0-native-erlang.json").exists())
roots = set(outputs)
for version in json.loads((consumer / "producers.json").read_text()):
    for field in ("library", "web", "jar"):
        roots.add("/".join(version[field].split("/")[:4]))
for index in range(2):
    native = json.loads((consumer / (str(index) + "-native-erlang.json")).read_text())
    for origin in native["origins"]:
        roots.add("/".join(origin["path"].split("/")[:4]))
for root in list(roots):
    catalog = Path(root) / "catalog.json"
    if catalog.exists():
        model = json.loads(catalog.read_text())
        if model.get("kind") == "compiled-native-relx-application-set":
            roots.add(model["producer"])
derivations = sorted({subprocess.check_output(["nix-store", "-q", "--deriver", root], text=True).strip() for root in roots})
assert all(d.endswith(".drv") for d in derivations)
for derivation in derivations:
    print("Direct compiled OTP rebuild", derivation, flush=True)
    subprocess.run(["nix", "build", "--no-link", "--rebuild", "-L", derivation + "^*"], check=True)
print("Actual compiled OTP producer/projection/consumer rebuilds passed")
