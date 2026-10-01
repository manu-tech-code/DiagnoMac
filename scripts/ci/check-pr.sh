#!/bin/bash
# Enforces the branch flow on pull requests (run by .github/workflows/pr-rules.yml):
#   feat|fix|bug|chore|docs|refactor|perf|test|ci/<name>  →  develop
#   develop  →  main, and only with a version in project.yml that isn't released yet
# Needs BASE and HEAD (branch names); HEAD_REPO and REPO when run in CI.
set -euo pipefail
: "${BASE:?}" "${HEAD:?}"

if [[ -n "${HEAD_REPO:-}" && "$HEAD_REPO" != "${REPO:-}" ]]; then
  echo "::error::Pull requests must come from a branch in ${REPO}, not a fork."
  exit 1
fi

case "$BASE" in
  develop)
    if [[ ! "$HEAD" =~ ^(feat|fix|bug|chore|docs|refactor|perf|test|ci)/.+$ ]]; then
      echo "::error::Branches into develop are named feat/…, fix/…, bug/…, chore/…, docs/…, refactor/…, perf/…, test/… or ci/… (this one is '$HEAD')."
      exit 1
    fi
    echo "OK: $HEAD → develop" ;;
  main)
    if [[ "$HEAD" != develop ]]; then
      echo "::error::Only develop merges into main (this PR is from '$HEAD'). Point it at develop instead."
      exit 1
    fi
    version=$(awk -F'"' '/CFBundleShortVersionString/ {print $2; exit}' project.yml)
    if git ls-remote --exit-code --tags origin "refs/tags/v$version" >/dev/null; then
      echo "::error::v$version is already released. Bump CFBundleShortVersionString and CFBundleVersion in project.yml through a chore/ PR into develop first."
      exit 1
    fi
    echo "OK: merging this releases v$version" ;;
  *)
    echo "No rules for $BASE" ;;
esac
