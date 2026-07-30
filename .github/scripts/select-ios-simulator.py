#!/usr/bin/env python3
"""Prints the UDID of the newest available iPhone simulator.

Used by CI to pick a real `xcodebuild test` destination. The runner's installed
simulators are not pinned by this repository, so the destination is discovered
at run time rather than hardcoded. Exits non-zero when no iPhone simulator is
available, so a misconfigured runner fails the job loudly instead of silently
degrading to a build-only run.

Reads `xcrun simctl list devices available --json` on stdin.
"""
import json
import sys


def ios_version(runtime_identifier):
    """Returns e.g. (26, 5) for an iOS runtime, or None for non-iOS runtimes."""
    tail = runtime_identifier.rsplit(".", 1)[-1]
    prefix = "iOS-"
    if not tail.startswith(prefix):
        return None
    try:
        return tuple(int(part) for part in tail[len(prefix):].split("-"))
    except ValueError:
        return None


def main():
    devices_by_runtime = json.load(sys.stdin)["devices"]

    candidates = []
    for runtime_identifier, devices in devices_by_runtime.items():
        version = ios_version(runtime_identifier)
        if version is None:
            continue
        for device in devices:
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                candidates.append((version, device["name"], device["udid"]))

    if not candidates:
        sys.exit("No available iPhone simulator on this runner.")

    version, name, udid = max(candidates)
    readable = ".".join(str(part) for part in version)
    print(f"Selected {name} (iOS {readable}) {udid}", file=sys.stderr)
    print(udid)


if __name__ == "__main__":
    main()
