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
archive_entries="$tmp/archive-entries.txt"
unzip -Z1 "$archive" > "$archive_entries"

if grep -Eq '(^|/)([.]build|[.]rivet|build|dist)/' "$archive_entries"; then
  echo "source package contains a generated build/output directory" >&2
  exit 1
fi

# Mobile protocol foundations are library sources rather than generated desktop
# scaffolds. Verify them directly in the source archive so a release cannot omit
# a platform that its package metadata and documentation advertise.
grep -Eq '(^|/)platform/android/build.gradle.kts$' "$archive_entries"
grep -Eq '(^|/)platform/android/gradle/wrapper/gradle-wrapper.jar$' "$archive_entries"
grep -Eq '(^|/)platform/android/src/main/kotlin/dev/rivet/runtime/Protocol.kt$' "$archive_entries"
grep -Eq '(^|/)platform/android/src/main/kotlin/dev/rivet/runtime/Client.kt$' "$archive_entries"
grep -Eq '(^|/)platform/android/src/main/kotlin/dev/rivet/runtime/State.kt$' "$archive_entries"

# Code generation is split into internal modules.  A package containing only
# the public facade installs successfully but fails later when a project is
# generated, so keep the internal dependency closure explicit in this smoke.
grep -Eq '(^|/)rivet-cli/codegen/cpp.rkt$' "$archive_entries"
grep -Eq '(^|/)rivet-cli/codegen/kotlin.rkt$' "$archive_entries"
grep -Eq '(^|/)rivet-cli/codegen/model.rkt$' "$archive_entries"
grep -Eq '(^|/)rivet-cli/codegen/naming.rkt$' "$archive_entries"
grep -Eq '(^|/)rivet-cli/codegen/snapshot.rkt$' "$archive_entries"
grep -Eq '(^|/)rivet-cli/codegen/swift.rkt$' "$archive_entries"
grep -Eq '(^|/)rivet-cli/codegen/type-graph.rkt$' "$archive_entries"

# The canonical learning project and both walkthrough languages are public
# package content, not files that happen to exist only in the Git checkout.
grep -Eq '(^|/)examples/taskboard/app/backend.rkt$' "$archive_entries"
grep -Eq '(^|/)examples/taskboard/rivet-schema.json$' "$archive_entries"
grep -Eq '(^|/)examples/taskboard/README.md$' "$archive_entries"
grep -Eq '(^|/)examples/taskboard/README.zh-CN.md$' "$archive_entries"
grep -Eq '(^|/)examples/taskboard/PERFORMANCE.md$' "$archive_entries"
grep -Eq '(^|/)examples/taskboard/windows/MainWindow.xaml$' "$archive_entries"
grep -Eq '(^|/)examples/taskboard/macos-host/Sources/RivetHost/ContentView.swift$' "$archive_entries"
grep -Eq '(^|/)examples/taskboard/linux/src/main.cpp$' "$archive_entries"
grep -Eq '(^|/)platform/macos/Sources/RivetSystem/FileDialogs.swift$' "$archive_entries"
grep -Eq '(^|/)platform/linux/system/file_dialogs.cpp$' "$archive_entries"
user_home="$tmp/racket-user"
work="$tmp/work"
mkdir -p "$user_home" "$work"

# Install the exact archive into a fresh user package scope. The repository's
# Force applies only to the fresh user scope: it lets the archive shadow a
# maintainer machine's installation-scope link. The pkg-directory assertion
# below proves all commands resolve this exact archive, not the checkout.
PLTUSERHOME="$user_home" \
  raco pkg install --auto --no-docs --scope user --force --name rivet "$archive"

PLTUSERHOME="$user_home" \
  racket -e '(require rivet/backend rivet/protocol rivet/resources)'
PLTUSERHOME="$user_home" \
  raco rivet help >/dev/null

installed_root="$(PLTUSERHOME="$user_home" racket -e \
  '(require pkg/lib) (display (path->string (pkg-directory "rivet")))')"
case "$installed_root" in
  "$user_home"/*) ;;
  *)
    echo "source package did not take precedence in the isolated user scope: $installed_root" >&2
    exit 1
    ;;
esac
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
PLTUSERHOME="$user_home" racket -e '
  (require json)
  (define report (call-with-input-file "inspect.json" read-json))
  (define (expect actual expected label)
    (unless (equal? actual expected)
      (raise-arguments-error
       (quote source-package-smoke)
       "inspect report did not match the packaged scaffold"
       "field" label
       "expected" expected
       "actual" actual)))
  (expect (hash-ref report (quote contract-version)) 1 "contract-version")
  (expect (hash-ref (hash-ref report (quote project)) (quote name))
          "ArchiveSmoke"
          "project.name")
  (expect (hash-ref (hash-ref (hash-ref report (quote backend)) (quote source))
                    (quote exists))
          #t
          "backend.source.exists")
  (expect (hash-ref (car (hash-ref (hash-ref report (quote edit-points))
                                  (quote windows-ui)))
                    (quote exists))
          #t
          "edit-points.windows-ui[0].exists")
  (expect (hash-ref (hash-ref (hash-ref report (quote generated-clients))
                             (quote kotlin))
                    (quote path))
          ".rivet/generated/kotlin/dev/rivet/generated/GeneratedBackend.kt"
          "generated-clients.kotlin.path")
'

# The published archive must still generate every typed client, including the
# Kotlin client that Android applications consume from the shared tree.
PLTUSERHOME="$user_home" \
  raco rivet generate
test -s .rivet/generated/kotlin/dev/rivet/generated/GeneratedBackend.kt

printf 'source package smoke test passed: %s\n' "$archive"
