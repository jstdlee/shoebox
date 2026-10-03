#!/usr/bin/env bash
# Print the UDID of an available iPhone simulator on the newest iOS runtime.
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, sys, re
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
for runtime in sorted(devices, key=version, reverse=True):
    if "iOS" not in runtime:
        continue
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone") and "Pro Max" not in d["name"]]
    phones.sort(key=lambda d: ("Pro" not in d["name"], d["name"]))
    if phones:
        print(phones[0]["udid"])
        break
else:
    sys.exit("no iPhone simulator found")
'
