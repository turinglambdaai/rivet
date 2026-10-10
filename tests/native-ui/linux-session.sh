#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <packaged-executable> <output-directory>" >&2
  exit 64
fi

executable="$(realpath "$1")"
output="$(realpath -m "$2")"
mkdir -p "$output"

export XDG_RUNTIME_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rivet-native-ui-runtime"
export WAYLAND_DISPLAY=wayland-rivet-native-ui
export GDK_BACKEND=wayland
export NO_AT_BRIDGE=0
unset DISPLAY
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

weston --backend=headless-backend.so --socket="$WAYLAND_DISPLAY" --idle-time=0 \
  --debug --log="$output/weston.log" &
weston_pid=$!
application_pid=""
atspi_bus_pid=""

capture_screen() {
  if command -v weston-screenshooter >/dev/null 2>&1; then
    (
      cd "$output"
      weston-screenshooter >/dev/null 2>&1 || true
      if [[ -f wayland-screenshot.png ]]; then
        mv -f wayland-screenshot.png screen.png
      fi
    )
  fi
}

stop_bounded() {
  local pid="$1"
  local label="$2"
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 200); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  echo "$label did not stop within ten seconds of SIGTERM" >&2
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT
  capture_screen
  if [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null; then
    stop_bounded "$application_pid" application || status=1
    wait "$application_pid" 2>/dev/null || true
  fi
  if [[ -n "$atspi_bus_pid" ]] && kill -0 "$atspi_bus_pid" 2>/dev/null; then
    kill -TERM "$atspi_bus_pid" 2>/dev/null || true
    wait "$atspi_bus_pid" 2>/dev/null || true
  fi
  kill -TERM "$weston_pid" 2>/dev/null || true
  wait "$weston_pid" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] && break
  kill -0 "$weston_pid" 2>/dev/null || {
    cat "$output/weston.log" >&2
    exit 1
  }
  sleep 0.05
done
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]

# Headless sessions do not have a desktop autostart agent to own org.a11y.Bus.
# Start the real AT-SPI bus explicitly so both GTK and the external client join
# the same accessibility registry instead of racing an absent cache service.
atspi_launcher="$(command -v at-spi-bus-launcher || true)"
if [[ -z "$atspi_launcher" && -x /usr/libexec/at-spi-bus-launcher ]]; then
  atspi_launcher=/usr/libexec/at-spi-bus-launcher
fi
[[ -n "$atspi_launcher" ]]
"$atspi_launcher" --launch-immediately \
  >"$output/at-spi-bus.log" 2>&1 &
atspi_bus_pid=$!
for _ in $(seq 1 100); do
  gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.a11y.Bus.GetAddress >/dev/null 2>&1 && break
  kill -0 "$atspi_bus_pid" 2>/dev/null || {
    cat "$output/at-spi-bus.log" >&2
    exit 1
  }
  sleep 0.05
done
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
  --method org.a11y.Bus.GetAddress >/dev/null

"$executable" >"$output/application.log" 2>&1 &
application_pid=$!
/usr/bin/python3 "$(dirname "$0")/linux-atspi.py" \
  --application "Rivet Taskboard" --output "$output"
capture_screen

stop_bounded "$application_pid" application
set +e
wait "$application_pid"
application_status=$?
set -e
application_pid=""
if [[ "$application_status" -ne 0 && "$application_status" -ne 143 ]]; then
  echo "Taskboard exited with status $application_status" >&2
  exit 1
fi

trap - EXIT
kill -TERM "$weston_pid" 2>/dev/null || true
wait "$weston_pid" 2>/dev/null || true
kill -TERM "$atspi_bus_pid" 2>/dev/null || true
wait "$atspi_bus_pid" 2>/dev/null || true
