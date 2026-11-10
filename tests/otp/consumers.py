import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import urllib.request
import zipfile

spec_file, output = map(Path, sys.argv[1:]); output.mkdir()
spec = json.loads(spec_file.read_text())
(output / "producers.json").write_text(json.dumps(spec["versions"], sort_keys=True) + "\n")
subprocess.run([spec["erlang"] + "/bin/erlc", "-o", ".", "otp_consumer.erl"], check=True)
subprocess.run(["javac", "Resources.java"], check=True)

def run(args, label, env):
    result = subprocess.run([str(a) for a in args], env=env, capture_output=True, text=True, timeout=60)
    (output / (label + ".stdout")).write_text(result.stdout)
    (output / (label + ".stderr")).write_text(result.stderr)
    assert result.returncode == 0 and not result.stderr, (label, result)

import os
for index, version in enumerate(spec["versions"]):
    catalog = Path(version["catalog"]); model = json.loads(catalog.read_text())
    expected = {a["name"] + "-" + a["version"] + "/" + f["path"]: f["sha256"]
                for a in model["applications"] if not a["sdk"] for f in a["files"]}
    listing = Path("files" + str(index) + ".txt")
    listing.write_text("\n".join(name + "\t" + digest for name, digest in sorted(expected.items())) + "\n")
    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *_): pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=version["web"]))
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    web = Path("web" + str(index)); web.mkdir()
    try:
        for name, digest in sorted(expected.items()):
            with urllib.request.urlopen("http://127.0.0.1:" + str(server.server_port) + "/" + name) as response:
                data = response.read()
            assert hashlib.sha256(data).hexdigest() == digest
            path = web / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
    finally:
        server.shutdown(); thread.join(); server.server_close()
    extracted = Path("jar" + str(index)); extracted.mkdir()
    with zipfile.ZipFile(version["jar"]) as archive:
        files = {name for name in archive.namelist() if not name.endswith("/")}
        assert files == set(expected)
        for name, digest in expected.items():
            data = archive.read(name); assert hashlib.sha256(data).hexdigest() == digest
            path = extracted / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
    run(["java", "Resources", version["jar"], listing], str(index) + "-java-resources", dict(os.environ))
    for carrier, root in [("native", Path(version["library"])), ("web", web), ("jar", extracted)]:
        root = root.resolve()
        env = dict(os.environ, ERL_LIBS=str(root), ERL_FLAGS="", ERL_AFLAGS="")
        for language in ("erlang", "elixir"):
            receipt = output / (str(index) + "-" + carrier + "-" + language + ".json")
            args = [catalog, root, version["marker"], receipt]
            if language == "erlang":
                command = [spec["erlang"] + "/bin/erl", "+S", "2:2", "-pa", ".", "-noshell", "-eval", "otp_consumer:main(init:get_plain_arguments()),halt().", "-extra", *args]
            else:
                code = '{:ok,_}=Application.ensure_all_started(:greeter); true=is_list(:recon.proc_count(:reductions,1)); _=:otel_tracer.current_span_ctx(); :otp_consumer.main(Enum.map(System.argv(), &String.to_charlist/1))'
                command = [spec["elixir"] + "/bin/elixir", "--erl", "+S 2:2 -pa .", "-e", code, "--", *args]
            run(command, receipt.stem, env)
            actual = json.loads(receipt.read_text())
            assert len(actual["origins"]) == 27 and actual["otp"] == "28"
            # Keep origin paths but no nondeterministic PID/port/timing values.
    missing = Path("missing" + str(index)); shutil.copytree(extracted, missing)
    shutil.rmtree(missing / "opentelemetry_api-1.5.0")
    env = dict(os.environ, ERL_LIBS=str(missing.resolve()), ERL_FLAGS="", ERL_AFLAGS="")
    result = subprocess.run([spec["erlang"] + "/bin/erl", "+S", "2:2", "-noshell", "-eval", 'R=application:ensure_all_started(greeter),{error,{opentelemetry_api,_}}=R,ok=file:write_file(hd(init:get_plain_arguments()),io_lib:format("~p~n",[R])),halt().', '-extra', str(output / (str(index) + '-missing-dependency.result'))],env=env,capture_output=True,text=True)
    assert result.returncode == 0, result
    # Preserve native diagnostics in the build log; the native result is the
    # reproducible artifact, since application shutdown reports contain time.
    print(result.stdout, end="", flush=True)
    print(result.stderr, end="", file=sys.stderr, flush=True)
    assert not result.stderr, result

# A genuinely compiled second producer must not satisfy the first producer's
# behavior or byte identity, even when its module name and app version match.
replacement = Path("replacement"); shutil.copytree("jar0", replacement)
shutil.copyfile("jar1/greeter-1.0.0/ebin/greeter.beam", replacement / "greeter-1.0.0/ebin/greeter.beam")
env = dict(os.environ, ERL_LIBS=str(replacement.resolve()), ERL_FLAGS="", ERL_AFLAGS="")
result = subprocess.run([spec["erlang"] + "/bin/erl", "+S", "2:2", "-pa", ".", "-noshell", "-eval",
    "otp_consumer:main(init:get_plain_arguments()),halt().", "-extra", spec["versions"][0]["catalog"],
    str(replacement.resolve()), "Hello", str(output / "must-not-exist.json")],env=env,capture_output=True,text=True)
assert result.returncode and "genuine_compiled_behavior_mismatch" in result.stdout + result.stderr
(output / "genuine-replacement.stdout").write_text(result.stdout)
(output / "genuine-replacement.stderr").write_text(result.stderr)
assert not (output / "must-not-exist.json").exists()
