"""Retain unchanged compiled application bytes selected by native OTP metadata."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

producer, plan, out = map(Path, sys.argv[1:])
model = json.loads(plan.read_text())
for app in model["applications"]:
    if app["sdk"]:
        continue
    source = Path(app["directory"]).resolve(strict=True)
    if not source.is_relative_to(producer.resolve()):
        raise SystemExit("compiled OTP application escapes its native producer")
    target = out / "lib" / (app["name"] + "-" + app["version"])
    for file in app["files"]:
        relative = Path(file["path"])
        original = (source / relative).resolve(strict=True)
        if relative.is_absolute() or ".." in relative.parts or not original.is_relative_to(source):
            raise SystemExit("compiled OTP file escapes its native application")
        if hashlib.sha256(original.read_bytes()).hexdigest() != file["sha256"]:
            raise SystemExit("native OTP application bytes changed after inspection")
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, destination)
(out / "catalog.json").write_text(json.dumps(model, sort_keys=True, indent=2) + "\n")
