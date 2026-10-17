#!/usr/bin/env python3
"""Start/stop only the localhost dashboard; never restart the inference runtime."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("action", choices=["start", "stop", "status"])
parser.add_argument("--state-dir", type=Path, help="same MUSE_STATE_DIR used by the runtime")
args = parser.parse_args()
runtime_dir = Path(__file__).resolve().parents[1]
state_dir = (args.state_dir or Path(os.environ.get("MUSE_STATE_DIR", str(runtime_dir / "state")))).expanduser().resolve()
label = "local.muse-glimmer.dashboard"
domain = "gui/%d" % os.getuid()
service = domain + "/" + label
url = "http://127.0.0.1:11436/"

def registered():
    return subprocess.run(["launchctl", "print", service], capture_output=True).returncode == 0

if args.action == "stop":
    if registered():
        subprocess.run(["launchctl", "bootout", service], check=True)
        # bootout returns before launchd finishes removing a terminating job.
        for _ in range(50):
            if not registered():
                break
            time.sleep(0.1)
        else:
            raise SystemExit("Dashboard is still stopping; wait before running start.")
    print("Dashboard stopped. Chat service is unchanged.")
elif args.action == "status":
    if not registered():
        raise SystemExit("Dashboard is not registered. Run the start command.")
    try:
        with urllib.request.urlopen(url + "api/monitor", timeout=3) as response:
            data = json.load(response)
        print("Dashboard: %s — runtime telemetry %s" % (url, data["connection"]))
    except Exception:
        raise SystemExit("Dashboard is registered but not responding yet.")
else:
    try:
        import psutil
    except ImportError:
        raise SystemExit("Install resource measurement support first: python3 -m pip install -r muse-runtime/requirements-monitor.txt")
    if registered():
        print("Dashboard already registered: " + url)
        raise SystemExit(0)
    # Reserve only loopback and fail clearly if an unrelated service owns the port.
    import socket
    with socket.socket() as probe:
        # Match DashboardServer: prior connections may remain in TIME_WAIT after stop.
        # An active listening service still makes bind fail.
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", 11436))
    state_dir.mkdir(parents=True, exist_ok=True)
    path = state_dir / (label + ".plist")
    plist = {"Label": label,
             "ProgramArguments": [sys.executable, "-m", "muse_runtime.dashboard", "--state-dir", str(state_dir)],
             "WorkingDirectory": str(runtime_dir), "RunAtLoad": True, "KeepAlive": True,
             "ThrottleInterval": 10,
             # No access logs or unbounded log storage; use the status command for health.
             "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"}
    with path.open("wb") as handle:
        plistlib.dump(plist, handle)
    subprocess.run(["launchctl", "bootstrap", domain, str(path)], check=True)
    for _ in range(30):
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                if response.status == 200:
                    print("Dashboard ready: " + url)
                    print("It stays running after this command exits. Run start again after login/reboot.")
                    break
        except OSError:
            time.sleep(0.2)
    else:
        raise SystemExit("Dashboard registered but not ready; run status or stop before retrying.")
