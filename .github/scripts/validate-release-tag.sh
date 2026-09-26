#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: validate-release-tag.sh TAG MAIN_REF [EXPECTED_REF]" >&2
  exit 2
}

[[ $# -ge 2 && $# -le 3 ]] || usage

tag="$1"
main_ref="$2"
expected_ref="${3:-}"
tag_ref="refs/tags/${tag}"

if ! tag_type="$(git cat-file -t "$tag_ref" 2>/dev/null)"; then
  echo "release tag does not exist locally: ${tag}" >&2
  exit 1
fi

if [[ "$tag_type" != "tag" ]]; then
  echo "release tag must be annotated: ${tag}" >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "${main_ref}^{commit}" >/dev/null; then
  echo "release main reference does not resolve to a commit: ${main_ref}" >&2
  exit 1
fi

tag_commit="$(git rev-parse "${tag_ref}^{commit}")"

if ! git merge-base --is-ancestor "$tag_commit" "$main_ref"; then
  echo "release tag ${tag} points outside ${main_ref} history: ${tag_commit}" >&2
  exit 1
fi

if [[ -n "$expected_ref" ]]; then
  if ! git rev-parse --verify --quiet "${expected_ref}^{commit}" >/dev/null; then
    echo "expected release reference does not resolve to a commit: ${expected_ref}" >&2
    exit 1
  fi
  expected_commit="$(git rev-parse "${expected_ref}^{commit}")"
  if [[ "$tag_commit" != "$expected_commit" ]]; then
    echo "release tag ${tag} points to ${tag_commit}, expected ${expected_commit}" >&2
    exit 1
  fi
fi

printf 'validated annotated release tag %s -> %s in %s history\n' \
  "$tag" "$tag_commit" "$main_ref"
