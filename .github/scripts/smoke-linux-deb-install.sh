#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <deb> <deb-package-name> <application-name> <binary-name>" >&2
  exit 64
fi

deb="$1"
deb_package="$2"
application_name="$3"
binary_name="$4"
installed_binary="/opt/${application_name}/${binary_name}"
desktop_entry="/usr/share/applications/${application_name}.desktop"
log_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
application_log="${log_root}/rivet-deb-installed-app.log"
application_pid=""
installed=0

cleanup() {
  local status=$?
  trap - EXIT

  if [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null; then
    kill -TERM "$application_pid" 2>/dev/null || true
    wait "$application_pid" 2>/dev/null || true
  fi

  if [[ "$installed" -eq 1 ]]; then
    sudo dpkg --remove "$deb_package" >/dev/null || true
  fi

  if [[ "$status" -ne 0 && -f "$application_log" ]]; then
    echo "--- installed application log ---" >&2
    cat "$application_log" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

test -f "$deb"
test -n "${XDG_RUNTIME_DIR:-}"
test -n "${WAYLAND_DISPLAY:-}"
test "${GDK_BACKEND:-}" = wayland
test -z "${DISPLAY:-}"

sudo dpkg --install "$deb"
installed=1

dpkg-query --show --showformat='${db:Status-Abbrev}\n' "$deb_package" | grep -qx 'ii '
test -x "$installed_binary"
test -f "$desktop_entry"
desktop-file-validate "$desktop_entry"
grep -Fxq "Exec=${installed_binary}" "$desktop_entry"
grep -Fxq "TryExec=${installed_binary}" "$desktop_entry"

"$installed_binary" >"$application_log" 2>&1 &
application_pid=$!
for _ in $(seq 1 50); do
  if ! kill -0 "$application_pid" 2>/dev/null; then
    wait "$application_pid" || true
    echo "installed application exited before the five-second launch gate" >&2
    exit 1
  fi
  sleep 0.1
done

kill -TERM "$application_pid"
set +e
wait "$application_pid"
application_status=$?
set -e
application_pid=""
if [[ "$application_status" -ne 0 && "$application_status" -ne 143 ]]; then
  echo "installed application exited with status ${application_status}" >&2
  exit 1
fi

sudo dpkg --remove "$deb_package"
installed=0
if dpkg-query --show --showformat='${db:Status-Abbrev}\n' "$deb_package" 2>/dev/null | grep -qx 'ii '; then
  echo "deb package remained installed after dpkg --remove" >&2
  exit 1
fi
test ! -e "$installed_binary"
test ! -e "$desktop_entry"

trap - EXIT
