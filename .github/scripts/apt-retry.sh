#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: apt-retry.sh [--sudo] <apt-get arguments...>" >&2
  exit 2
}

use_sudo=false
if [[ "${1:-}" == "--sudo" ]]; then
  use_sudo=true
  shift
fi
(( $# > 0 )) || usage

# A complete GTK4/libsecret install can fetch 100+ packages on cold hosted
# runners. A 180-second attempt interrupts healthy downloads mid-flight, and
# two attempts cannot outlast a slow mirror. Update remains short; install
# gets a larger window and one more bounded, cache-resuming attempt.
operation="$1"
case "$operation" in
  install) default_timeout_seconds=480 ; default_attempts=3 ;;
  *) default_timeout_seconds=180 ; default_attempts=2 ;;
esac
attempts="${RIVET_APT_RETRY_ATTEMPTS:-$default_attempts}"
timeout_seconds="${RIVET_APT_TIMEOUT_SECONDS:-$default_timeout_seconds}"
delay_seconds="${RIVET_APT_RETRY_DELAY_SECONDS:-10}"
apt_get="${RIVET_APT_GET:-apt-get}"
timeout_command="${RIVET_TIMEOUT_COMMAND:-timeout}"
if [[ -x /usr/bin/timeout && -z "${RIVET_TIMEOUT_COMMAND:-}" ]]; then
  timeout_command=/usr/bin/timeout
fi

for value_name in attempts timeout_seconds delay_seconds; do
  value="${!value_name}"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    echo "apt-retry: $value_name must be a positive integer" >&2
    exit 2
  fi
done

apt_command=(
  env DEBIAN_FRONTEND=noninteractive
  "$apt_get"
  -o Acquire::Retries=3
  -o DPkg::Lock::Timeout=60
  "$@"
)
if [[ "$use_sudo" == true ]]; then
  apt_command=(sudo -n "${apt_command[@]}")
fi

for (( attempt = 1; attempt <= attempts; attempt++ )); do
  echo "apt-retry: $operation attempt $attempt/$attempts (timeout ${timeout_seconds}s)"
  if "$timeout_command" --foreground --signal=TERM --kill-after=30s \
      "${timeout_seconds}s" "${apt_command[@]}"; then
    exit 0
  else
    status=$?
  fi
  if (( attempt == attempts )); then
    echo "apt-retry: $operation failed after $attempts attempts" >&2
    exit "$status"
  fi
  sleep "$(( delay_seconds * attempt ))"
done
