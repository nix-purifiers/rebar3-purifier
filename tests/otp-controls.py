import json
import os
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parent.parent
receipts = {}
for case, diagnostic in [
    ("wrongSdk", "sdk_erts_mismatch"),
    ("sdkCollision", "sdk_module_collision"),
    ("duplicateModule", "duplicate_compiled_module_owners"),
    ("nativePayload", "native_application_payload_needs_runtime_proof"),
]:
    command = ["nix", "build", "--impure", "--no-link", "--file", str(repo / "tests/otp-control-build.nix"),
               "--argstr", "projectRoot", str(repo), "--argstr", "case", case]
    result = subprocess.run(command, text=True, capture_output=True, timeout=600)
    receipts[case] = {"command": command, "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    assert result.returncode and diagnostic in result.stderr, receipts[case]
if os.environ.get("OTP_CONTROL_REPORT"):
    Path(os.environ["OTP_CONTROL_REPORT"]).write_text(json.dumps(receipts, indent=2) + "\n")
print("Four actual SDK/compiled-producer ownership/runtime controls rejected")
