echo "Install rtkit so PipeWire gets realtime priority"

# PipeWire requests realtime scheduling via RealtimeKit at startup, but rtkit
# is not a dependency of Arch's pipewire packages and the rlimits fallback is
# not configured either (see https://github.com/omacom/omarchy/issues/9390).
# Without it, audio threads run at SCHED_OTHER nice 0 and produce xruns under
# sustained load.
#
# Processes started while rtkit was missing can carry a hard RLIMIT_RTTIME of
# 0, which rtkit accepts as soon as D-Bus can activate it, and the kernel kills
# a realtime thread under that limit. So raise those limits to rtkit's default
# budget of 200 ms before installing it, then to its live budget once the
# portals report it. omarchy-realtime-repair fails, and keeps this migration
# pending, while anything is left that it could not repair or inspect.
if omarchy-pkg-missing rtkit; then
  # omarchy-pkg-add would prompt for sudo; without it cached, wait for the update.
  sudo -n true 2>/dev/null || {
    echo "Installing rtkit needs sudo without a prompt; the next omarchy update finishes it." >&2
    exit 1
  }
  omarchy-realtime-repair 200000
  omarchy-pkg-add rtkit
fi

omarchy-realtime-repair

# rtkit only takes effect when PipeWire re-requests priority at startup, so
# restart the audio units while the server's threads are not realtime yet.
# The server is pipewire.service's main process: a filter-chain host, such as
# the speaker tuning, is also named pipewire and may already be realtime.
pipewire=$(systemctl --user show -p MainPID --value pipewire.service)
if [[ $pipewire =~ ^[1-9][0-9]*$ && ! $(ps -L -o cls= -p "$pipewire") =~ RR|FF ]]; then
  systemctl --user try-restart pipewire.service pipewire-pulse.service wireplumber.service
fi
