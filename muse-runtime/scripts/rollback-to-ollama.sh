#!/bin/zsh
set -eu

runtime_dir="${0:A:h:h}"
state_dir="$runtime_dir/state"
launch_domain="gui/$(id -u)"
"$runtime_dir/scripts/stop.sh"
launchctl enable "$launch_domain/com.ollama.ollama" >/dev/null 2>&1 || true
ollama_env_plist="$HOME/Library/LaunchAgents/com.ollama.setenv.plist"
ollama_env_backup="$state_dir/com.ollama.setenv.plist.disabled"
if [[ -f "$ollama_env_backup" && ! -e "$ollama_env_plist" ]]; then
  mv "$ollama_env_backup" "$ollama_env_plist"
  launchctl bootstrap "$launch_domain" "$ollama_env_plist" >/dev/null 2>&1 || true
fi
open -a Ollama
for _ in {1..120}; do
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    print "Rollback complete: Ollama is serving on port 11434."
    exit 0
  fi
  sleep 0.5
done
print "Ollama did not become ready within one minute. Open the Ollama app to inspect it."
exit 1
