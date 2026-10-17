#!/bin/zsh
set -eu

runtime_dir="${0:A:h:h}"
launch_label="local.muse-glimmer.runtime"
launch_domain="gui/$(id -u)"
if ! launchctl print "$launch_domain/$launch_label" >/dev/null 2>&1; then
  print "Muse Glimmer runtime is not running."
  exit 0
fi

launchctl bootout "$launch_domain/$launch_label"
print "Muse Glimmer runtime stopped."
