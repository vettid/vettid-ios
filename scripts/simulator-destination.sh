#!/usr/bin/env bash
# Prints an xcodebuild destination for an available iPhone simulator on the
# newest installed iOS runtime, so local runs and CI do not depend on one
# device name. Override with VETTID_SIMULATOR="<device name>".
set -euo pipefail

if [[ -n "${VETTID_SIMULATOR:-}" ]]; then
  echo "platform=iOS Simulator,name=${VETTID_SIMULATOR}"
  exit 0
fi

xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    tail = runtime.rsplit(".", 1)[-1]          # e.g. "iOS-27-0"
    if not tail.startswith("iOS-"):
        return None
    return tuple(int(p) for p in tail[4:].split("-"))
best = None
for runtime, items in devices.items():
    v = version(runtime)
    if v is None:
        continue
    for d in items:
        if d["name"].startswith("iPhone") and (best is None or v > best[0]):
            best = (v, d["udid"])
if best is None:
    sys.exit("no available iPhone simulator")
print(f"platform=iOS Simulator,id={best[1]}")
'
