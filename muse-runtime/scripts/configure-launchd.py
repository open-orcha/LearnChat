#!/usr/bin/env python3
"""Generate a host-local launchd plist without loading or restarting the service."""
import os
from pathlib import Path
import plistlib
import shutil
import sys

runtime_dir = Path(__file__).resolve().parents[1]
state_dir = runtime_dir / "state"
python = shutil.which(os.environ.get("MUSE_PYTHON", sys.executable))
if not python:
    raise SystemExit("MUSE_PYTHON must name an installed Python 3.9+ executable")
state_dir.mkdir(parents=True, exist_ok=True)
plist = {
    "Label": "local.muse-glimmer.runtime",
    "ProgramArguments": ["/bin/zsh", str(runtime_dir / "scripts/run.sh")],
    "WorkingDirectory": str(runtime_dir),
    "EnvironmentVariables": {
        "MUSE_PYTHON": python,
        "PATH": os.environ.get("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"),
    },
    "RunAtLoad": True,
    "KeepAlive": True,
    "ThrottleInterval": 10,
    "StandardOutPath": str(state_dir / "service.log"),
    "StandardErrorPath": str(state_dir / "service.log"),
}
path = state_dir / "local.muse-glimmer.runtime.plist"
with path.open("wb") as handle:
    plistlib.dump(plist, handle)
print(path)
