#!/bin/zsh
set -eu

runtime_dir="${0:A:h:h}"
set -a
source "$runtime_dir/.env"
set +a
cd "$runtime_dir"
exec "${MUSE_PYTHON:-python3}" -m muse_runtime.server
