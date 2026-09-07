#!/usr/bin/env python3
"""Own a disposable iPad simulator for local and CI Apple acceptance.

Run with an explicit DEVELOPER_DIR. The state file is an ownership receipt;
cleanup refuses to delete a simulator whose identity no longer matches it.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import uuid


def simctl(*arguments, capture=False):
    command = ["xcrun", "simctl", *arguments]
    print("+ " + " ".join(command), flush=True)
    result = subprocess.run(command, check=True, text=True, capture_output=capture)
    return result.stdout.strip() if capture else None


def devices():
    data = json.loads(simctl("list", "devices", "available", "-j", capture=True))
    return [(runtime, device) for runtime, entries in data["devices"].items() for device in entries]


def create(state_path):
    if state_path.exists():
        raise SystemExit(f"Refusing to overwrite simulator ownership receipt: {state_path}")
    candidates = [
        (runtime, device)
        for runtime, device in devices()
        if runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        and device.get("isAvailable")
        and device["name"].startswith("iPad")
    ]
    if not candidates:
        raise SystemExit("No available iPad simulator runtime and device type")
    runtime, device = max(
        candidates,
        key=lambda item: (
            tuple(int(value) for value in re.findall(r"\d+", item[0])),
            "11-inch" in item[1]["name"],
            "Pro" in item[1]["name"],
            item[1]["deviceTypeIdentifier"],
        ),
    )
    name = f"AssignmentApp-RC-{uuid.uuid4()}"
    state_path.parent.mkdir(parents=True, exist_ok=True)
    device_id = simctl("create", name, device["deviceTypeIdentifier"], runtime, capture=True)
    receipt = {
        "device_id": device_id,
        "name": name,
        "device_type": device["deviceTypeIdentifier"],
        "runtime": runtime,
    }
    # Record ownership before boot, so a boot failure can still be cleaned up.
    state_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"device_id={device_id}\n")
    print(json.dumps(receipt), flush=True)
    simctl("bootstatus", device_id, "-b")


def owned_device(state_path):
    receipt = json.loads(state_path.read_text(encoding="utf-8"))
    matches = [(runtime, device) for runtime, device in devices() if device["udid"] == receipt["device_id"]]
    if len(matches) != 1:
        raise SystemExit("Owned simulator is missing or unavailable; inspect the saved receipt")
    runtime, device = matches[0]
    if (
        not receipt["name"].startswith("AssignmentApp-RC-")
        or device["name"] != receipt["name"]
        or runtime != receipt["runtime"]
        or device["deviceTypeIdentifier"] != receipt["device_type"]
    ):
        raise SystemExit("Simulator identity differs from ownership receipt; refusing mutation")
    return device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["create", "ready", "delete"])
    parser.add_argument("--state", required=True, type=Path)
    args = parser.parse_args()
    if args.action == "delete" and not args.state.exists():
        print("No simulator ownership receipt was created; nothing to delete")
        return
    developer_dir = os.environ.get("DEVELOPER_DIR")
    if not developer_dir or not (Path(developer_dir) / "usr/bin/xcodebuild").is_file():
        parser.error("Set DEVELOPER_DIR to a real Xcode.app/Contents/Developer directory")
    if args.action == "create":
        create(args.state)
        return
    device = owned_device(args.state)
    if args.action == "ready":
        simctl("bootstatus", device["udid"], "-b")
        return
    if device["state"] != "Shutdown":
        simctl("shutdown", device["udid"])
    # shutdown is synchronous; deleting only after it succeeds releases app files.
    simctl("delete", device["udid"])
    receipt = json.loads(args.state.read_text(encoding="utf-8"))
    receipt["deleted"] = True
    args.state.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
