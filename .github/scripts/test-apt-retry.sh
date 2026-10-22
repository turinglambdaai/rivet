#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fake_apt="$work/fake-apt-get"
cat >"$fake_apt" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "$FAKE_APT_STATE" ]]; then
  count="$(cat "$FAKE_APT_STATE")"
fi
count="$(( count + 1 ))"
printf '%s' "$count" >"$FAKE_APT_STATE"
printf '%s\n' "$*" >"$FAKE_APT_ARGUMENTS"
case "$FAKE_APT_MODE" in
  retry)
    (( count >= 3 ))
    ;;
  timeout)
    sleep 5
    ;;
  success)
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
SH
chmod +x "$fake_apt"

export RIVET_APT_GET="$fake_apt"
export RIVET_APT_RETRY_DELAY_SECONDS=1
export FAKE_APT_STATE="$work/count"
export FAKE_APT_ARGUMENTS="$work/arguments"

export FAKE_APT_MODE=retry
export RIVET_APT_RETRY_ATTEMPTS=3
export RIVET_APT_TIMEOUT_SECONDS=5
bash "$script_dir/apt-retry.sh" install --yes example-package
[[ "$(cat "$FAKE_APT_STATE")" == 3 ]]
grep -Fq -- 'install --yes example-package' "$FAKE_APT_ARGUMENTS"
grep -Fq -- 'Acquire::Retries=3' "$FAKE_APT_ARGUMENTS"
grep -Fq -- 'DPkg::Lock::Timeout=60' "$FAKE_APT_ARGUMENTS"

export FAKE_APT_MODE=timeout
export RIVET_APT_RETRY_ATTEMPTS=1
export RIVET_APT_TIMEOUT_SECONDS=1
if bash "$script_dir/apt-retry.sh" update; then
  echo "apt-retry test expected the bounded command to fail" >&2
  exit 1
fi

# Distinguish large install budgets from update without ever disabling
# timeout enforcement. An explicit caller override still takes precedence.
fake_timeout="$work/fake-timeout"
cat >"$fake_timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_TIMEOUT_ARGS"
while (( $# > 0 )); do
  case "$1" in
    --foreground|--signal=*|--kill-after=*) shift ;;
    *s) shift; break ;;
    *) exit 64 ;;
  esac
done
"$@"
SH
chmod +x "$fake_timeout"
export RIVET_TIMEOUT_COMMAND="$fake_timeout"
export FAKE_TIMEOUT_ARGS="$work/timeout-arguments"
export FAKE_APT_MODE=success
export RIVET_APT_RETRY_ATTEMPTS=1
unset RIVET_APT_TIMEOUT_SECONDS
bash "$script_dir/apt-retry.sh" install --yes example-package
grep -Fq -- '480s' "$FAKE_TIMEOUT_ARGS"
: >"$FAKE_TIMEOUT_ARGS"
bash "$script_dir/apt-retry.sh" update
grep -Fq -- '180s' "$FAKE_TIMEOUT_ARGS"
: >"$FAKE_TIMEOUT_ARGS"
export RIVET_APT_TIMEOUT_SECONDS=9
bash "$script_dir/apt-retry.sh" install --yes example-package
grep -Fq -- '9s' "$FAKE_TIMEOUT_ARGS"
