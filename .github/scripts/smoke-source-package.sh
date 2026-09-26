#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: smoke-source-package.sh ARCHIVE" >&2
  exit 2
fi

archive="$1"
if [[ ! -f "$archive" ]]; then
  echo "source package archive does not exist: $archive" >&2
  exit 1
fi
archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
user_home="$tmp/racket-user"
work="$tmp/work"
mkdir -p "$user_home" "$work"

# Install the exact archive into a fresh user package scope. The repository's
# linked development package lives in a different PLTUSERHOME, so successful
# commands below prove the archive itself is complete and installable.
PLTUSERHOME="$user_home" \
  raco pkg install --auto --no-docs --name rivet "$archive"

PLTUSERHOME="$user_home" \
  racket -e '(require rivet/backend rivet/protocol)'
PLTUSERHOME="$user_home" \
  raco rivet help >/dev/null

# Exercise packaged scaffold resources too. A source archive that omitted CLI
# templates or other package data can load its modules yet still fail here.
cd "$work"
PLTUSERHOME="$user_home" \
  raco rivet new ArchiveSmoke

test -f ArchiveSmoke/rivet.rktd
test -f ArchiveSmoke/app/backend.rkt
test -f ArchiveSmoke/windows/CMakeLists.txt
test -f ArchiveSmoke/macos-host/Package.swift

printf 'source package smoke test passed: %s\n' "$archive"
