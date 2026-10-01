# Branches and releases

`develop` is the default branch. `main` only holds released code and changes
only through a pull request from `develop`.

```
feat/… fix/… bug/… chore/…  ──PR──▶  develop  ──PR──▶  main  ──▶  release/<version> + tag v<version>
```

1. **Start from `develop`**: `git switch develop && git pull && git switch -c feat/app-history`.
   Prefixes: `feat/`, `fix/`, `bug/`, `chore/`, and also `docs/`, `refactor/`, `perf/`, `test/`, `ci/`.
2. **Open a pull request into `develop`.** It needs the *Branch rules* and *Core tests*
   checks to pass. Squash or merge it. Its title becomes a line in the release notes,
   so write it as what changed for someone using the app.
3. **Release**: bump `CFBundleShortVersionString` (and `CFBundleVersion` by one) in
   `project.yml`, run `xcodegen generate` so `Info.plist` follows, and commit both in
   a `chore/` PR into `develop`. Then open a PR from `develop` into
   `main` and merge it with a merge commit. The check refuses a version that is
   already released.
4. **The Release workflow** then creates `release/<version>`, the tag `v<version>` and a
   *draft* GitHub release. Its notes list the merged PRs under Features, Fixes and
   Chores, from the label each PR gets from its branch name. The update window shows
   them as New, Fixes and Improvements.

Nobody can push directly to `main` or `develop`, force-push them or delete them.

## Pull request descriptions

Describe the change under **What**, for someone who uses the app, and how you checked it
under **Checked**. Measurements go in a table, before and after.

## Tests

The logic that doesn't need the app (release notes, networkQuality parsing) lives in
`Packages/DiagnoKit` and runs without launching anything:

```sh
cd Packages/DiagnoKit && swift test
```
