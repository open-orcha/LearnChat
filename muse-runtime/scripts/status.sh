#!/bin/zsh
set -eu

runtime_dir="${0:A:h:h}"
set -a
source "$runtime_dir/.env"
set +a
auth=()
if [[ -n "${MUSE_API_KEY:-}" ]]; then auth=(-H "Authorization: Bearer $MUSE_API_KEY"); fi
curl -fsS "${auth[@]}" "http://127.0.0.1:$MUSE_PORT/api/status" | python3 -m json.tool
