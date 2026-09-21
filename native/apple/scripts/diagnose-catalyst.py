"""Temporary CI-only probe; never used to qualify or package a release."""
import os
from pathlib import Path
import signal
import subprocess
import sys

root = Path(os.environ["RUNNER_TEMP"]) / "catalyst-diagnostic"
root.mkdir()
args = ["xcodebuild", "-project", "native/apple/AssignmentApp2.xcodeproj",
        "-scheme", "AssignmentApp2", "-configuration", "Debug",
        "-destination", "platform=macOS,arch=arm64,variant=Mac Catalyst",
        "-derivedDataPath", str(root / "derived-data"),
        "-resultBundlePath", str(root / "unit.xcresult"),
        "CODE_SIGNING_ALLOWED=NO", "test", "-test-iterations", "10",
        "-test-repetition-relaunch-enabled", "YES"]
if os.environ["DIAGNOSTIC_SCOPE"] == "read-gate-only":
    args += ["-only-testing:AssignmentApp2Tests/TaskRefreshTests"]
print("CPU_COUNT=" + str(os.cpu_count()), flush=True)
print("DIAGNOSTIC_SCOPE=" + os.environ["DIAGNOSTIC_SCOPE"], flush=True)
print(" ".join(args), flush=True)
with (root / "unit.log").open("w") as output:
    process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT,
                               start_new_session=True)
    try:
        result = process.wait(timeout=300)
    except subprocess.TimeoutExpired:
        listing = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True)
        (root / "processes.txt").write_text(listing)
        for line in listing.splitlines():
            fields = line.strip().split(maxsplit=1)
            if len(fields) == 2 and "Assignment App.app/" in fields[1] and "Contents/MacOS/Assignment App" in fields[1]:
                pid = fields[0]
                subprocess.run(["sample", pid, "3", "-file", str(root / ("sample-" + pid + ".txt"))],
                               check=False, timeout=20)
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        print("DIAGNOSTIC_TIMEOUT: stacks retained after 300 seconds", flush=True)
        result = 124
log = (root / "unit.log").read_text(errors="replace")
print(log[-40000:])
# Avoid uploading build products: only logs, stack captures, and the xcresult.
import shutil
shutil.rmtree(root / "derived-data")
sys.exit(result)
