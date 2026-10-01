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

# Mobile protocol foundations are library sources rather than generated desktop
# scaffolds. Verify them directly in the source archive so a release cannot omit
# a platform that its package metadata and documentation advertise.
unzip -Z1 "$archive" | grep -Eq '(^|/)platform/android/build.gradle.kts$'
unzip -Z1 "$archive" | grep -Eq '(^|/)platform/android/gradle/wrapper/gradle-wrapper.jar$'
unzip -Z1 "$archive" | grep -Eq '(^|/)platform/android/src/main/kotlin/dev/rivet/runtime/Protocol.kt$'
unzip -Z1 "$archive" | grep -Eq '(^|/)platform/android/src/main/kotlin/dev/rivet/runtime/Client.kt$'
unzip -Z1 "$archive" | grep -Eq '(^|/)platform/android/src/main/kotlin/dev/rivet/runtime/State.kt$'

# The canonical learning project and both walkthrough languages are public
# package content, not files that happen to exist only in the Git checkout.
unzip -Z1 "$archive" | grep -Eq '(^|/)examples/taskboard/app/backend.rkt$'
unzip -Z1 "$archive" | grep -Eq '(^|/)examples/taskboard/rivet-schema.json$'
unzip -Z1 "$archive" | grep -Eq '(^|/)examples/taskboard/README.md$'
unzip -Z1 "$archive" | grep -Eq '(^|/)examples/taskboard/README.zh-CN.md$'
unzip -Z1 "$archive" | grep -Eq '(^|/)examples/taskboard/PERFORMANCE.md$'
unzip -Z1 "$archive" | grep -Eq '(^|/)examples/taskboard/windows/MainWindow.xaml$'
unzip -Z1 "$archive" | grep -Eq '(^|/)examples/taskboard/macos-host/Sources/RivetHost/ContentView.swift$'
unzip -Z1 "$archive" | grep -Eq '(^|/)examples/taskboard/linux/src/main.cpp$'

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
  racket -e '(require rivet/backend rivet/protocol rivet/resources)'
PLTUSERHOME="$user_home" \
  raco rivet help >/dev/null

installed_root="$(PLTUSERHOME="$user_home" racket -e \
  '(require pkg/lib) (display (path->string (pkg-directory "rivet")))')"
test -f "$installed_root/examples/taskboard/app/backend.rkt"
test -f "$installed_root/examples/taskboard/README.md"
test -f "$installed_root/examples/taskboard/README.zh-CN.md"
test -f "$installed_root/examples/taskboard/PERFORMANCE.md"

# Exercise packaged scaffold resources too. A source archive that omitted CLI
# templates or other package data can load its modules yet still fail here.
cd "$work"
PLTUSERHOME="$user_home" \
  raco rivet new ArchiveSmoke

test -f ArchiveSmoke/README.md
test -f ArchiveSmoke/AGENTS.md
test -f ArchiveSmoke/rivet.rktd
test -f ArchiveSmoke/app/backend.rkt
test -f ArchiveSmoke/windows/RivetHost.vcxproj
test -f ArchiveSmoke/macos-host/Package.swift
test -f ArchiveSmoke/linux/CMakeLists.txt
test -f ArchiveSmoke/linux/src/main.cpp
grep -Fq '(resources . ())' ArchiveSmoke/rivet.rktd
grep -Fq 'RIVET_WINDOWS_ICON_RC' ArchiveSmoke/windows/RivetHost.vcxproj

# The starter should remain self-guiding: installing a release archive and
# running `new` must leave a developer with the normal diagnosis/run path and a
# route to both walkthroughs, without requiring the Rivet checkout nearby.
grep -Fq 'raco rivet doctor' ArchiveSmoke/README.md
grep -Fq 'raco rivet inspect --json' ArchiveSmoke/AGENTS.md
grep -Fq 'raco rivet dev' ArchiveSmoke/README.md
grep -Fq 'docs/getting-started.md' ArchiveSmoke/README.md
grep -Fq 'docs/getting-started.zh-CN.md' ArchiveSmoke/README.md

cd ArchiveSmoke
PLTUSERHOME="$user_home" \
  raco rivet inspect --json > inspect.json
python3 - <<'PY'
import json
with open("inspect.json", encoding="utf-8") as handle:
    report = json.load(handle)
assert report["contract-version"] == 1
assert report["project"]["name"] == "ArchiveSmoke"
assert report["backend"]["source"]["exists"] is True
assert report["edit-points"]["windows-ui"][0]["exists"] is True
assert report["generated-clients"]["kotlin"]["path"] == \
    ".rivet/generated/kotlin/dev/rivet/generated/GeneratedBackend.kt"
PY

# The published archive must still generate every typed client, including the
# Kotlin client that Android applications consume from the shared tree.
PLTUSERHOME="$user_home" \
  raco rivet generate
test -s .rivet/generated/kotlin/dev/rivet/generated/GeneratedBackend.kt

printf 'source package smoke test passed: %s\n' "$archive"
