#!/bin/zsh
set -eu

runtime_dir="${0:A:h:h}"
state_dir="$runtime_dir/state"
launch_label="local.muse-glimmer.runtime"
launch_domain="gui/$(id -u)"
plist="$state_dir/$launch_label.plist"
replace_ollama=0
if [[ "${1:-}" == "--replace-ollama" ]]; then
  replace_ollama=1
fi

set -a
source "$runtime_dir/.env"
set +a
mkdir -p "$state_dir"
auth=()
if [[ -n "${MUSE_API_KEY:-}" ]]; then auth=(-H "Authorization: Bearer $MUSE_API_KEY"); fi

disable_ollama_autostart() {
  launchctl disable "$launch_domain/com.ollama.ollama" >/dev/null 2>&1 || true
  ollama_env_plist="$HOME/Library/LaunchAgents/com.ollama.setenv.plist"
  ollama_env_backup="$state_dir/com.ollama.setenv.plist.disabled"
  launchctl bootout "$launch_domain/com.ollama.setenv" >/dev/null 2>&1 || true
  launchctl unsetenv OLLAMA_HOST >/dev/null 2>&1 || true
  if [[ -f "$ollama_env_plist" && ! -e "$ollama_env_backup" ]]; then
    mv "$ollama_env_plist" "$ollama_env_backup"
  fi
}

if [[ "$replace_ollama" -eq 1 ]]; then
  disable_ollama_autostart
fi

if launchctl print "$launch_domain/$launch_label" >/dev/null 2>&1; then
  if curl -fsS "${auth[@]}" "http://127.0.0.1:$MUSE_PORT/api/status" 2>/dev/null | python3 -c 'import json,sys; assert json.load(sys.stdin).get("service") == "muse-glimmer-runtime"' 2>/dev/null; then
    print "Muse Glimmer runtime is already running."
    exit 0
  fi
  launchctl bootout "$launch_domain/$launch_label" >/dev/null 2>&1 || true
fi

if lsof -nP -iTCP:"$MUSE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  if [[ "$replace_ollama" -eq 1 ]] && lsof -nP -iTCP:"$MUSE_PORT" -sTCP:LISTEN 2>/dev/null | grep -qi ollama; then
    osascript -e 'tell application "Ollama" to quit' >/dev/null 2>&1 || true
    pkill -TERM -x Ollama 2>/dev/null || true
    pkill -TERM -f '/Ollama.app/Contents/Resources/ollama serve' 2>/dev/null || true
    for _ in {1..40}; do
      if ! lsof -nP -iTCP:"$MUSE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
      sleep 0.25
    done
  else
    print "Port $MUSE_PORT is already in use. Stop that service or rerun with --replace-ollama."
    exit 1
  fi
fi

python3 "$runtime_dir/scripts/configure-launchd.py" >/dev/null

bootstrapped=0
for _ in {1..20}; do
  if launchctl bootstrap "$launch_domain" "$plist" >/dev/null 2>&1; then
    bootstrapped=1
    break
  fi
  sleep 0.25
done
if [[ "$bootstrapped" -ne 1 ]]; then
  print "Could not register the Muse Glimmer launch job. Try the start command again."
  exit 1
fi

for _ in {1..360}; do
  if curl -fsS "${auth[@]}" "http://127.0.0.1:$MUSE_PORT/api/status" 2>/dev/null | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data.get("service") == "muse-glimmer-runtime" and data.get("ready") is True' 2>/dev/null; then
    print "Muse Glimmer runtime is ready at http://$MUSE_HOST:$MUSE_PORT."
    exit 0
  fi
  if ! launchctl print "$launch_domain/$launch_label" >/dev/null 2>&1; then
    print "Muse Glimmer runtime exited during startup. See $state_dir/service.log"
    exit 1
  fi
  sleep 0.5
done

launchctl bootout "$launch_domain/$launch_label" >/dev/null 2>&1 || true
print "Muse Glimmer runtime did not become ready in time. See $state_dir/service.log"
exit 1
