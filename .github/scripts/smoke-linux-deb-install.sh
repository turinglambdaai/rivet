#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 7 ]]; then
  echo "usage: $0 <initial-deb> <upgrade-deb> <deb-package-name> <application-name> <binary-name> <initial-version> <upgrade-version>" >&2
  exit 64
fi

initial_deb="$1"
upgrade_deb="$2"
deb_package="$3"
application_name="$4"
binary_name="$5"
initial_version="$6"
upgrade_version="$7"
installed_binary="/opt/${application_name}/${binary_name}"
desktop_entry="/usr/share/applications/${application_name}.desktop"
resource_marker="/opt/${application_name}/app/assets/nested/product.txt"
log_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
diagnostics_dir="${log_root}/rivet-linux-deb-diagnostics"
application_log="${diagnostics_dir}/installed-app.log"
package_log="${diagnostics_dir}/package-transactions.log"
application_pid=""
installed=0

mkdir -p "$diagnostics_dir"
: >"$package_log"

record_package_state() {
  local label="$1"
  {
    echo "=== ${label} ==="
    date --iso-8601=seconds
    uname -a
    printf 'WAYLAND_DISPLAY=%s\n' "${WAYLAND_DISPLAY:-}"
    printf 'GDK_BACKEND=%s\n' "${GDK_BACKEND:-}"
    printf 'DISPLAY=%s\n' "${DISPLAY:-}"
    dpkg-query --show --showformat='${db:Status-Abbrev} ${Version}\n' \
      "$deb_package" 2>&1 || true
  } >>"$package_log"
}

assert_installed_version() {
  local expected="$1"
  dpkg-query --show --showformat='${db:Status-Abbrev}\n' "$deb_package" |
    grep -qx 'ii '
  test "$(dpkg-query --show --showformat='${Version}' "$deb_package")" = \
    "$expected"
}

launch_installed_application() {
  local expected_marker="$1"
  test "$(cat "$resource_marker")" = "$expected_marker"
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
  for _ in $(seq 1 100); do
    if ! kill -0 "$application_pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  if kill -0 "$application_pid" 2>/dev/null; then
    kill -KILL "$application_pid" 2>/dev/null || true
    wait "$application_pid" 2>/dev/null || true
    application_pid=""
    echo "installed application did not stop within five seconds of SIGTERM" >&2
    exit 1
  fi
  set +e
  wait "$application_pid"
  application_status=$?
  set -e
  application_pid=""
  if [[ "$application_status" -ne 0 && "$application_status" -ne 143 ]]; then
    echo "installed application exited with status ${application_status}" >&2
    exit 1
  fi
}

cleanup() {
  local status=$?
  trap - EXIT

  if [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null; then
    kill -TERM "$application_pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$application_pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -KILL "$application_pid" 2>/dev/null || true
    wait "$application_pid" 2>/dev/null || true
  fi

  if [[ "$installed" -eq 1 ]]; then
    sudo timeout 120s dpkg --remove "$deb_package" >/dev/null || true
  fi

  if [[ "$status" -ne 0 && -f "$application_log" ]]; then
    echo "--- installed application log ---" >&2
    cat "$application_log" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

test -f "$initial_deb"
test -f "$upgrade_deb"
test -n "${XDG_RUNTIME_DIR:-}"
test -n "${WAYLAND_DISPLAY:-}"
test "${GDK_BACKEND:-}" = wayland
test -z "${DISPLAY:-}"

sudo timeout 120s dpkg --install "$initial_deb" >>"$package_log" 2>&1
installed=1

assert_installed_version "$initial_version"
test -x "$installed_binary"
test -f "$desktop_entry"
desktop-file-validate "$desktop_entry"
grep -Fxq "Exec=${installed_binary}" "$desktop_entry"
grep -Fxq "TryExec=${installed_binary}" "$desktop_entry"
launch_installed_application packaged-resource
record_package_state initial-install

# A malformed higher-version package must fail before replacing the working
# installation. Keep the previous version launchable after the failed attempt.
corrupt_deb="${diagnostics_dir}/corrupt-upgrade.deb"
printf 'not a Debian package\n' >"$corrupt_deb"
set +e
sudo timeout 120s dpkg --install "$corrupt_deb" >>"$package_log" 2>&1
corrupt_status=$?
set -e
if [[ "$corrupt_status" -eq 0 ]]; then
  echo "malformed upgrade unexpectedly installed" >&2
  exit 1
fi
if [[ "$corrupt_status" -eq 124 ]]; then
  echo "malformed upgrade check timed out" >&2
  exit 1
fi
assert_installed_version "$initial_version"
launch_installed_application packaged-resource
record_package_state failed-upgrade-recovery

sudo timeout 120s dpkg --install "$upgrade_deb" >>"$package_log" 2>&1
assert_installed_version "$upgrade_version"
launch_installed_application upgraded-resource
record_package_state in-place-upgrade

# apt refuses an unattended downgrade unless --allow-downgrades is explicit.
# Verify the rejection leaves the upgraded payload and version untouched.
set +e
sudo timeout 120s apt-get install --yes "$initial_deb" >>"$package_log" 2>&1
downgrade_status=$?
set -e
if [[ "$downgrade_status" -eq 0 ]]; then
  echo "package manager unexpectedly accepted a downgrade" >&2
  exit 1
fi
if [[ "$downgrade_status" -eq 124 ]]; then
  echo "package manager downgrade check timed out" >&2
  exit 1
fi
assert_installed_version "$upgrade_version"
launch_installed_application upgraded-resource
record_package_state downgrade-rejected

sudo timeout 120s dpkg --remove "$deb_package"
installed=0
if dpkg-query --show --showformat='${db:Status-Abbrev}\n' "$deb_package" 2>/dev/null | grep -qx 'ii '; then
  echo "deb package remained installed after dpkg --remove" >&2
  exit 1
fi
test ! -e "$installed_binary"
test ! -e "$desktop_entry"
record_package_state uninstall

trap - EXIT
