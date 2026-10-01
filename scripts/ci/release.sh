#!/bin/bash
# Runs on every push to main, i.e. a merged develop → main pull request
# (.github/workflows/release.yml): creates release/<version>, the annotated tag
# v<version> and a *draft* GitHub release with notes generated from the merged
# PRs. The repo has immutable releases on, so nothing can be added once a
# release is published: the signed DMG is attached to the draft from a Mac,
# which then publishes it (scripts/release.sh --upload).
set -euo pipefail

version=$(awk -F'"' '/CFBundleShortVersionString/ {print $2; exit}' project.yml)
tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "::notice::$tag is already released; nothing to do."
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git push origin "HEAD:refs/heads/release/$version"
git tag -a "$tag" -m "$tag"
git push origin "$tag"
gh release create "$tag" --verify-tag --title "$tag" --generate-notes --draft
echo "::notice::Drafted $tag. Attach the DMG and publish from your Mac: git switch release/$version && scripts/release.sh --upload"
