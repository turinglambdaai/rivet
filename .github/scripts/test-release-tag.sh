#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="${repo_root}/.github/scripts/validate-release-tag.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

git init -q -b main "$tmp"
cd "$tmp"
git config user.name "Rivet Release Test"
git config user.email "release-test@example.invalid"

printf 'base\n' > release-test.txt
git add release-test.txt
git commit -q -m base
base_commit="$(git rev-parse HEAD)"

printf 'main\n' >> release-test.txt
git commit -q -am main
main_commit="$(git rev-parse HEAD)"

git tag -a v-good "$base_commit" -m "good release"
bash "$validator" v-good main "$base_commit" >/dev/null

# The workflow must validate the same commit it actually checked out.
expect_failure bash "$validator" v-good main "$main_commit"

# Lightweight tags are too easy to create accidentally and do not carry the
# annotated release object required by the documented release process.
git tag v-light "$main_commit"
expect_failure bash "$validator" v-light main "$main_commit"

# An annotated tag on a commit outside main history must never publish.
git switch -q -c experiment "$base_commit"
printf 'experiment\n' >> release-test.txt
git commit -q -am experiment
experiment_commit="$(git rev-parse HEAD)"
git tag -a v-experiment "$experiment_commit" -m "not releasable"
git switch -q main
expect_failure bash "$validator" v-experiment main "$experiment_commit"

# Missing tags and missing main refs should fail closed with no implicit
# fallback to another branch or commit.
expect_failure bash "$validator" v-missing main "$main_commit"
expect_failure bash "$validator" v-good missing-main "$base_commit"

printf 'release tag provenance tests passed\n'
