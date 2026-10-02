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
   them as New, Fixes and Improvements. To give the release a summary line, edit the
   draft and add one sentence above the notes.
5. **Attach the signed DMG and the appcast, and publish** from your Mac (assets can only be
   added while the release is a draft):
   ```sh
   git fetch && git switch release/<version>
   scripts/release.sh --upload
   ```
   Installed copies read `appcast.xml` from the latest release once a day (Sparkle)
   and offer the update in the sidebar and the menu bar.

Nobody can push directly to `main` or `develop`, force-push them or delete them.

## The update key

Updates are signed with an EdDSA key in your login Keychain (account
`com.amalitech.DiagnoMac`); `SUPublicEDKey` in `project.yml` is its public half.
Without the private key, installed copies can't be updated, so keep a backup
somewhere safe, outside the repo:

```sh
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account com.amalitech.DiagnoMac -x ~/diagnomac-update-key
```

## Measuring

`scripts/measure.sh <DiagnoMac.app> <page|menubar>` reports CPU, energy impact, idle
wake-ups and memory the way performance PRs show them, before and after.

## Checking the assistant

The on-device model is small, and a change to its prompts or readings can make it drift off topic.
Write questions to a file, one per line (start a line with `+` to follow up in the same conversation,
or `#` for a comment), then ask them all with a debug build:

```sh
open -n build/DerivedData/Build/Products/Debug/DiagnoMac.app --args -openPage apps -captureDelay 30 -askEach ~/questions.txt
```

After the scan, and 30 seconds for DiagnoMac to see which apps are idle, it writes each answer and the
readings it used to `~/questions.txt.answers`, then quits. Compare the answers before and after the change.

## Pull request descriptions

Describe the change under **What**, for someone who uses the app, and how you checked it
under **Checked**. Measurements go in a table, before and after.

## Tests

The logic that doesn't need the app (release notes, networkQuality parsing, which readings
the assistant reads for a question) lives in
`Packages/DiagnoKit` and runs without launching anything:

```sh
cd Packages/DiagnoKit && swift test
```
