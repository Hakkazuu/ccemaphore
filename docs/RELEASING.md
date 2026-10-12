# Releasing ccemaphore

Maintainer notes for cutting a signed, notarized release. End users don't need any of this: they
install the DMG from the [Releases](https://github.com/hakkazuu/ccemaphore/releases/latest) page once,
and from 1.3.0 on the app updates itself.

Every release publishes two assets:

- **`ccemaphore-<version>.dmg`** is the drag-to-install image for new users. It is also the archive
  that the in-app updater ([Sparkle](https://sparkle-project.org) 2.10.0) downloads.
- **`appcast.xml`** is the signed update feed. Every installed copy polls
  `https://github.com/hakkazuu/ccemaphore/releases/latest/download/appcast.xml` (`SUFeedURL` in
  `Resources/Info.plist`), so whatever release is "latest" decides what everyone is offered.

The pipeline is [`.github/workflows/release.yml`](../.github/workflows/release.yml). Its logic lives in
the scripts in [`Scripts/release/`](../Scripts/release/), which can also be run by hand.

## Cutting a release

1. **Bump the version in Xcode.** Set both build settings:
   - `MARKETING_VERSION` (the human version, e.g. `1.3.1`);
   - `CURRENT_PROJECT_VERSION` (the build number, a plain integer).

   Edit them in *Project ▸ ccemaphore ▸ Build Settings*, or as *Version* / *Build* on the target's
   *General* tab. `Resources/Info.plist` reads both settings, so never type a version into it. The build
   number is what Sparkle compares. It must be greater than every build ever published, prereleases
   included. CI enforces this.
2. **Add the release notes** to `CHANGELOG.md` as a `## [1.3.1] - YYYY-MM-DD` section, in the existing
   Keep a Changelog format. That section, in English Markdown, is shown in the app's update row and
   used as the body of the GitHub release.
3. **Commit and push `main`.** If the packages changed, include
   `ccemaphore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. A stable tag has to
   point at a commit that is already on `main`, so push before you tag.
4. **Tag and push:**
   ```sh
   git tag v1.3.1
   git push origin v1.3.1
   ```
5. **Approve the run.** The `preflight` job runs first and needs no secrets. When it passes, the run
   summary shows the version, the build number and the release notes, and the notes are also attached
   as the `release-notes` artifact. Read them, then approve the `release` environment. If you spot a
   mistake, reject the run before you fix it and move the tag (see
   [When something goes wrong](#when-something-goes-wrong)).
6. When `verify-live` turns green, installed copies are being offered the update. Each copy checks
   about once a day, or right away when the user clicks *Check now* (a copy set to *Off* only then).

### Stable vs. prerelease tags

| Tag | Example | What happens |
| --- | --- | --- |
| `vX.Y.Z` | `v1.3.1` | Stable. Becomes the "latest" release, and its `appcast.xml` is served to every installed copy. Must be tagged on a commit that is on `main`. |
| `vX.Y.Z-<suffix>` | `v1.3.1-rc.1` | Prerelease. Published with its own `appcast.xml`, never marked "latest", so no installed copy sees it unless you point one at it (see [Testing an update](#testing-an-update-end-to-end)). |
| any other `v…` tag | `v1.3`, `v1.3.1.1`, `v1.3.1+5` | Rejected by `preflight`. |
| no leading `v` | `1.3.1` | Starts no run at all: the workflow only reacts to tags that start with `v`. |

For both kinds, `MARKETING_VERSION` must equal `X.Y.Z`. A prerelease uses its own `## [X.Y.Z-suffix]`
CHANGELOG section if one exists, otherwise the `## [X.Y.Z]` section.

### What the workflow does

1. **`preflight`** (Ubuntu, no environment, no secrets) runs `check-version.sh` and refuses the tag
   unless:
   - the tag has the right shape;
   - `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` each have one value across Debug and Release,
     and `MARKETING_VERSION` matches the tag;
   - `Info.plist` still expands those settings and carries the updater keys: the canonical
     `SUFeedURL`, `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`, and a real Ed25519
     `SUPublicEDKey` (the `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` placeholder fails here);
   - the CHANGELOG section exists;
   - `Package.resolved` pins Sparkle to the exact version the project requires;
   - the build number is above every `sparkle:version` in the live feed and in every published
     release's `appcast.xml`, and a stable version is above the live feed's newest one;
   - no published release for the tag exists yet;
   - a stable tag is on `main`.

   It then extracts the release notes.
2. **`release`** (macOS, `release` environment, waits for your approval):
   1. checks that the tag still points at the commit the run was started for. A run keeps that commit
      while it waits for approval and when it is re-run, even after its tag was moved or deleted, so
      without this check it would build and publish the old commit under the tag;
   2. selects the newest *released* Xcode on the runner, never a beta or a release candidate. The runner
      images also install a beta under version-named symlinks (`Xcode_26.5.app` →
      `Xcode_26.5_beta_2.app`), so the real paths are compared, not the names;
   3. builds Release with `-onlyUsePackageVersionsFromResolvedFile` and `CODE_SIGNING_ALLOWED=NO`, and
      checks that Sparkle's `generate_appcast` and `sign_update` came with the package;
   4. runs `check-app.sh`: the bundle carries the expected version and build, the updater keys, a
      universal (arm64 + x86_64) binary, Sparkle and the third-party notices;
   5. imports the `.p12` into a temporary keychain;
   6. runs `sign-app.sh`, which removes Sparkle's unused XPC services and signs inside-out (Autoupdate →
      Updater.app → Sparkle.framework → the app) with Hardened Runtime and a secure timestamp. It does
      not use `--deep`. It verifies the signatures and asserts that every Mach-O in the bundle carries
      `APPLE_TEAM_ID`;
   7. runs `smoke-test.sh`, which starts the signed binary with `--help` and `--update-status`. Every
      Claude Code and Codex hook runs this binary, and its updater launch gate must report `enabled`;
   8. `notarize.sh --app`: notarizes and staples the `.app`, then asks Gatekeeper about it;
   9. `make-dmg.sh`: builds the DMG from the stapled app with `hdiutil` and an `/Applications` symlink,
      then signs it;
   10. `notarize.sh --dmg`: notarizes and staples the DMG;
   11. deletes the keychain;
   12. `make-appcast.sh`: starting from the live feed, runs `generate_appcast` with the EdDSA key on
       stdin. It adds an item for this DMG with an absolute per-tag download URL and the notes
       embedded as Markdown. It keeps a short history (3 versions), turns deltas off and signs the
       whole feed. This step must come **after** stapling, because stapling rewrites the DMG's bytes;
   13. `verify-appcast.sh` checks the feed signature, the new item's EdDSA signature over the DMG, its
       length, URL, versions, minimum macOS and notes, both against `SUPublicEDKey` and with Sparkle's
       `sign_update --verify`. This step matters because `generate_appcast` exits 0 even when it
       could not sign;
   14. checks again that the tag still points at the built commit, then publishes the GitHub Release
       with the DMG and `appcast.xml`. A stable release is created as a draft, both files are uploaded,
       and only then is it published and made "latest", all in one call. A prerelease is never made
       "latest"; the action keeps it as a draft while it uploads, and a separate API call publishes it,
       because the action would otherwise publish a prerelease before uploading its files.
3. **`verify-live`** (Ubuntu, no secrets) runs `verify-live.sh`. It downloads the feed and the DMG
   exactly as an installed copy would and verifies them the same way Sparkle does.

**One release at a time.** All runs share one concurrency group, so two releases never extend the same
"previous" feed. A running release is never cancelled. While one runs or waits for approval, only one
more run can wait behind it: pushing yet another tag cancels the run that was waiting. Push one tag at
a time, and re-run a replaced run from the Actions tab if you still want it.

### Scripts

| Script | Purpose |
| --- | --- |
| `check-version.sh` | The preflight gate described above. |
| `extract-notes.sh` | Extracts a version's CHANGELOG section. |
| `check-app.sh` | Checks the built bundle before signing. |
| `sign-app.sh` | Signs inside-out, verifies, and asserts the team. |
| `smoke-test.sh` | Runs the signed binary headlessly. |
| `notarize.sh` | Runs `notarytool` (and prints Apple's log on failure), staples, and runs Gatekeeper checks. |
| `make-dmg.sh` | Builds and signs the DMG. |
| `make-appcast.sh` | Runs `generate_appcast` and guards the build number. `--signing-pubkey` is for a key rotation only (see [Losing or leaking the EdDSA key](#losing-or-leaking-the-eddsa-key)). |
| `verify-appcast.sh` | Verifies the generated feed before publishing. |
| `verify-live.sh` | Verifies the published feed and DMG. |
| `lib.sh` | Shared constants and helpers, including the release job's tag check (`assert_tag_at`). |
| `release_tool.py` | Python helper used by the scripts (standard library only): pbxproj/plist/feed parsing and an Ed25519 verifier. |
| `selftest.sh` | End-to-end test without secrets: throwaway releases, a key rotation, and the cases that must fail. |

After changing anything in `Scripts/release/` or the workflow, run:

```sh
Scripts/release/selftest.sh
```

It finds Sparkle's tools in DerivedData once Xcode has resolved the packages; otherwise pass
`--sparkle-bin <SourcePackages>/artifacts/sparkle/Sparkle/bin`. The test never launches or registers
anything and deletes everything it creates.

## One-time setup

### Secrets

Store these in **Settings ▸ Environments ▸ `release` ▸ Environment secrets**, not as repository
secrets, so they are only decrypted after the reviewer approves. Keep yourself as the environment's
**Required reviewer**. On the GitHub Free, Pro and Team plans, required reviewers only work in public
repositories. This one has to stay public anyway, because installed copies download the feed and the
DMG without signing in.

| Secret | What it is |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64 of the *Developer ID Application* certificate and its private key, exported as `.p12`. |
| `P12_PASSWORD` | The password set when exporting that `.p12`. |
| `APPLE_TEAM_ID` | The 10-character Team ID of the team that owns the certificate. CI checks that everything is signed by this team. |
| `NOTARY_APPLE_ID` | An Apple ID that is a member of that team. |
| `NOTARY_PASSWORD` | An [app-specific password](https://support.apple.com/102654) for that Apple ID. |
| `SPARKLE_ED_PRIVATE_KEY` | The EdDSA private key that signs updates (see below). |

`KEYCHAIN_PASSWORD` is no longer used: each run creates its keychain with a random password and deletes
it after signing. You can delete that secret.

### The update signing key (EdDSA), once

Every installed copy trusts exactly one key, the `SUPublicEDKey` in its `Info.plist`. Generate it once
and never lose it.

1. **Find Sparkle's tools.** They arrive with the Swift package. After Xcode has resolved packages,
   which happens when you open the project, they are in
   `~/Library/Developer/Xcode/DerivedData/ccemaphore-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
   Or fetch them explicitly:
   ```sh
   xcodebuild -resolvePackageDependencies -project ccemaphore.xcodeproj \
     -clonedSourcePackagesDirPath /tmp/ccemaphore-spm
   BIN=/tmp/ccemaphore-spm/artifacts/sparkle/Sparkle/bin
   ```
2. **Generate the key pair.** The private key goes into your login keychain, and the public key is
   printed:
   ```sh
   "$BIN/generate_keys" --account ccemaphore
   ```
3. **Publish the public key.** Replace the placeholder in `Resources/Info.plist`:
   ```xml
   <key>SUPublicEDKey</key>
   <string>…the printed base64 key…</string>
   ```
   Then commit. `"$BIN/generate_keys" --account ccemaphore -p` prints it again.
4. **Back up the private key, then load it into CI.** Export it into a private temporary folder, never
   into the repository: a stray `git add` there would publish the key that signs every update.
   `mktemp -d` makes a folder outside the repository that only you can read:
   ```sh
   KEYDIR="$(mktemp -d)"
   "$BIN/generate_keys" --account ccemaphore -x "$KEYDIR/ccemaphore-sparkle.key"
   ```
   The file holds the base64 of the key's 32-byte seed. Store its content in your password manager AND
   an offline encrypted backup. Then, in the same terminal, load it into CI and delete the folder:
   ```sh
   gh secret set SPARKLE_ED_PRIVATE_KEY --env release < "$KEYDIR/ccemaphore-sparkle.key"
   rm -rf "$KEYDIR"
   ```
   CI checks that this secret belongs to `SUPublicEDKey` before it signs anything.

#### Losing or leaking the EdDSA key

Installed copies check two signatures against their own `SUPublicEDKey`: the feed's
(`SURequireSignedFeed`) and the DMG's. A new key reaches them only inside an update, so how fast a
rotation works depends on whether you still have the old private key.

**Leaked, but you still have it: rotate at once.** Ship one release that carries the new key but is
signed, feed and DMG, with the old one:

1. Create the new key pair under a new account name, `"$BIN/generate_keys" --account ccemaphore-2`. Put
   its public key into `Info.plist`, bump the version, then commit and push `main`.
2. Cut that release with the [manual flow](#manual-release-fallback), with `SPARKLE_ED_PRIVATE_KEY` set
   to the **old** private key and the old public key passed to the feed scripts:
   `make-appcast.sh … --signing-pubkey <old public key>`, then `verify-appcast.sh … --pubkey <old public
   key>` and `verify-live.sh … --pubkey <old public key>`. CI can't cut this release: it only signs with
   the key that belongs to the app's own `SUPublicEDKey`.
3. Installed copies verify the feed and the DMG with the old key, install the update like any other,
   and from then on trust only the new key. Replace the `SPARKLE_ED_PRIVATE_KEY` secret with the new
   key (export it as in step 4 above, with `--account ccemaphore-2`), and let CI sign every later
   release with it.
4. Time the next release. Until it ships, copies already on the rotation release reject the live feed,
   which is still the rotation release's own, signed with the old key: their scheduled checks fail
   silently, and *Check now* reports "The update failed verification" although they run the newest
   build. The next release ends that, but a copy still on an older build when it ships rejects its
   new-key feed and takes the slow path below. So ship it once the copies you know of have installed the
   rotation release (*Settings ▸ Updates* shows the installed build).

**Lost: the slow path.** Ship an update that carries a new `SUPublicEDKey`, signed by CI with the new
key as usual. Its DMG is also signed with the same team's Developer ID, which is what lets Sparkle accept
it at all:

- `SURequireSignedFeed` makes each installed copy reject a feed signed with another key for **20 days
  from that copy's first failed check**. That is Sparkle's `SUSignedFeedFailureExpirationInterval`
  default, which `Info.plist` doesn't change. During that time scheduled checks fail silently (they are
  only logged), and *Check now* reports "The update failed verification".
- After the 20 days, the copy accepts the feed in a degraded mode. The update is offered without its
  release notes or links, and only with a click, even in *Automatic* mode. Its DMG then passes through
  Sparkle's Developer ID fallback, which also requires the DMG to verify against the new key.
- `verify-live` checks against the repository's (new) key, so it turns green although installed copies
  are still refusing the feed.

Change either the key or the signing team in one release, never both.

### Developer ID certificate (company team)

Releases are signed by the company's Developer ID. Nothing in the code or the workflow names a team:
CI reads `APPLE_TEAM_ID`, and the app accepts any Developer ID signature.

1. Only the company's **Account Holder** can create a *Developer ID Application* certificate. Admins can
   get only a cloud-managed one, which can't be exported for CI. Create it on the website, not in
   *Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates*: Xcode skips the CSR, but Apple doesn't say which
   intermediate it uses, and a certificate from the previous Sub-CA can't sign after February 1, 2027.
   1. On a Mac, open *Keychain Access* (recent macOS no longer lists it in *Utilities*: use Spotlight or
      `open -a "Keychain Access"`), choose *Keychain Access ▸ Certificate Assistant ▸ Request a
      Certificate From a Certificate Authority…*, and save the CSR to disk. This also creates the private
      key in that Mac's login keychain, so do the steps below on the same Mac.
   2. In *developer.apple.com ▸ Certificates, Identifiers & Profiles ▸ Certificates ▸ +*, choose
      **Developer ID Application**, then **G2 Sub-CA (Xcode 11.4.1 or later)**, and upload the CSR.
   3. Download the certificate and double-click it to install it in the keychain where the CSR was made.
      Select it in *Keychain Access* and expand *Issuer Name*: *Organizational Unit* must read **G2**.
      *Apple Certification Authority* there means the previous Sub-CA.
   4. In *Keychain Access ▸ My Certificates*, right-click *Developer ID Application: <Company>
      (<TEAMID>)* and choose *Export*. Save it as a `.p12` with a password, outside the repository. The
      `.p12` must contain exactly one Developer ID Application identity for the team; CI refuses an
      ambiguous one.
2. Replace the secrets. Without piped input, `gh secret set` prompts for the value, and a prompt can take
   the next pasted line as its answer, so paste these commands one at a time. The first one sends nothing
   unless the file was read: a plain `base64 … | gh secret set` that can't read the file stores an empty
   secret. If it reports *Operation not permitted*, the terminal may not open that folder (often
   *Desktop*, *Documents* or *Downloads*): move the file to your home folder in Finder and run it again.
   ```sh
   B64="$(base64 -i DeveloperID.p12)" && [ -n "$B64" ] && printf '%s' "$B64" | gh secret set BUILD_CERTIFICATE_BASE64 --env release
   unset B64
   ```
   ```sh
   gh secret set P12_PASSWORD --env release
   ```
   ```sh
   gh secret set APPLE_TEAM_ID --env release
   ```
   The next two are needed only when another Apple ID notarizes: an app-specific password belongs to an
   Apple ID, not to a team, so the current pair keeps working if that Apple ID is also a member of the
   company team.
   ```sh
   gh secret set NOTARY_APPLE_ID --env release
   ```
   ```sh
   gh secret set NOTARY_PASSWORD --env release
   ```
   Then delete the `.p12` file.
3. **Notarize early.** Make the first run on the new team a prerelease tag. Teams that have only shipped
   to the App Store sometimes get *"Team is not yet configured for notarization"*. That needs Apple
   Developer Program Support, so find out before a real release depends on it.
4. **Renew on time.** G2 Developer ID certificates expire. Apple says new ones are issued for a year, yet
   the company's, issued in October 2026, runs until the G2 authority itself expires on September 17,
   2031. Trust the date in the certificate (*Keychain Access ▸ the certificate ▸ Expires*). Create a
   new one and replace `BUILD_CERTIFICATE_BASE64` and `P12_PASSWORD` before that date. Builds that are
   already signed keep working because they carry a secure timestamp.

The team that signs 1.3.0, the first release with the updater, is the team all later updates should keep.
1.3.0 is installed by hand anyway, so a team change there costs nothing extra. A later team change still
updates, as long as the EdDSA key stays the same in that release. However, macOS ties the Accessibility
permission to the signing team, so users would have to grant it again.

## Testing an update end-to-end

Before a stable release that changes the updater or Sparkle, test the real flow on a Mac with two
notarized prereleases. Local Xcode builds never update themselves, by design.

**Quit the Xcode Debug copy for the whole test, and don't start it with ⌘R until you are done.** It has
the same bundle id. Launching it re-points the Claude Code hooks at its DerivedData binary (the Codex hooks
only if their binary is gone), and while it runs, two lights react to the same sessions and permission
requests, so you can't tell which copy did what. If it ran anyway, open `/Applications/ccemaphore.app`
once, so that the hooks point back at it.

The two update paths are separate code, so the test has two runs. *Check now* always takes the UI path,
even in *Automatic* mode. Only a scheduled background check in *Automatic* takes the silent path.

### Setup

1. Set the build number to N, then tag and publish `v1.3.0-rc.1`. Install that DMG into
   `/Applications` and launch it. Grant Accessibility, turn on the Claude Code and Codex hooks
   (`--hooks-status` and `--codex-hooks-status` are green), and answer the consent row.
2. Set the build number to N+1, then tag and publish `v1.3.0-rc.2`.
3. Point the installed copy at the second prerelease's own feed:
   ```sh
   defaults write com.hakkazuu.ccemaphore SUFeedURL \
     https://github.com/hakkazuu/ccemaphore/releases/download/v1.3.0-rc.2/appcast.xml
   ```
   `ccemaphore --update-status` (the binary is in `/Applications/ccemaphore.app/Contents/MacOS/`) shows
   the override loudly. Only the URL can be overridden: `SUPublicEDKey` is read from `Info.plist`, so
   the test uses real signatures.

Both prereleases are version 1.3.0, so every row and note says "1.3.0". Tell the builds apart by the
build number: *Settings ▸ Updates ▸ Installed version* shows `1.3.0 (N)` or `1.3.0 (N+1)`. Each run starts
on rc.1. To go back to it, quit ccemaphore, drag `ccemaphore.app` from rc.1's DMG onto `/Applications`
(replace the copy there), and open it.

Some steps need a pending permission request. Have Claude Code ask for one, for example by asking it to
run a shell command that isn't allowed yet, so that the permission ribbon shows.

### Run 1: the UI path (*Notify only*, and *Check now* in any mode)

1. On rc.1, choose *Settings ▸ Updates ▸ Notify only*, then click *Check now*.
2. Expect "Version 1.3.0 is available" with *Update*, *Later* and *Skip this version*.
3. While a permission request is pending, *Update* is disabled and the row says why. Answer the request,
   and *Update* is enabled again.
4. Click *Update*. The row shows "Downloading version 1.3.0…", "Preparing version 1.3.0…" and
   "Installing version 1.3.0…". The app quits, installs and relaunches by itself; this path has no
   *Restart* click.
5. After the relaunch, the row says "Updated to version 1.3.0" and *Installed version* shows build N+1.
   Then go through the [checks after every update](#checks-after-every-update).

### Run 2: the silent path (*Automatic*)

1. Go back to rc.1. Choose *Settings ▸ Updates ▸ Automatic* and quit ccemaphore. Then make the next check
   overdue and open the app:
   ```sh
   defaults delete com.hakkazuu.ccemaphore SULastCheckTime
   open /Applications/ccemaphore.app
   ```
   The overdue check runs at launch and downloads in the background. Nothing is shown while it does.
2. Expect "Version 1.3.0 is ready to install" with *Restart* and *Later*, and the status-menu item
   "Restart to Update to 1.3.0".
3. While a permission request is pending, *Restart* is disabled in the row and in the menu, and the row
   says why. Answer the request.
4. **An install that fails after the app has quit.** This is what the relaunch watchdog is for. Lock the
   bundle so that the installer's final swap fails, then wait for the app to quit and unlock it again.
   Paste these lines, then click *Restart* while the loop waits: it ends when the app has quit, and the
   bundle is unlocked two seconds later.
   ```sh
   chflags uchg /Applications/ccemaphore.app
   while pgrep -qf '^/Applications/ccemaphore.app/Contents/MacOS/ccemaphore$'; do sleep 0.2; done; sleep 2
   chflags nouchg /Applications/ccemaphore.app
   ```
   About 10 seconds after the light disappears, it comes back by itself, still on build N, and the row
   says "Version 1.3.0 wasn't installed". The day's log in `~/Library/Logs/ccemaphore/` has a
   `relaunch-watchdog` line that opened the app and an `update: … did not install` line.
   Cancelling the administrator password prompt does not test this: macOS asks for it while the app
   is still running, and Sparkle treats the cancel as the user's choice.
5. Meanwhile the update downloads again in the background; the note stays until you dismiss it. Dismiss
   it, and when the row offers "ready to install" again, click *Restart*. The app quits, installs and
   relaunches by itself, says "Updated to version 1.3.0", and shows build N+1. Go through the
   [checks after every update](#checks-after-every-update).
6. **Install on quit.** Go back to rc.1 and repeat step 1; the mode stays *Automatic*. At "ready to
   install", click *Later*, and the row hides. Then quit ccemaphore from the panel footer or the status
   menu. It installs as it quits and does not relaunch. Open it: "Updated to version 1.3.0", build N+1.

### Checks after every update

- *Settings ▸ Updates ▸ Installed version* shows the new build number;
- the light kept its position;
- Accessibility is still granted (*Open chat* raises the right window);
- `--hooks-status` and `--codex-hooks-status` are unchanged;
- `--update-status` reports the launch gate as `enabled`.

### Clean up

```sh
defaults delete com.hakkazuu.ccemaphore SUFeedURL
```

`--update-status` then shows no override. The installed copy stays on rc.2 and is offered the stable
release like every other copy.

Prerelease builds use up build numbers. The next stable release must have a higher one, or a Mac that
ran the test would treat it as a downgrade. CI enforces this as long as the prereleases stay published.
If you delete them, keep counting up anyway.

## When something goes wrong

- **`preflight` fails.** The message says what to fix. If the fix needs a new commit, push it (to `main`
  for a stable tag) and move the tag to it (`git tag -f vX.Y.Z && git push -f origin vX.Y.Z`), which
  starts a new run. If it doesn't, for example because you only had to push `main` or a download
  failed, pushing the unchanged tag starts nothing: re-run the failed run instead (*Actions ▸ the run ▸
  Re-run failed jobs*, or `gh run rerun <run-id> --failed`).
- **You want to move or re-push a tag.** First reject or cancel every run for that tag that is still
  waiting for approval or running. A run keeps building the commit it was started for, so the `release`
  job checks, at its start and again right before publishing, that the tag still points there. A stale
  run therefore fails instead of publishing the old commit, but while it waits it holds up the new run.
- **A waiting run was cancelled.** Another tag was pushed while a release ran (see
  [One release at a time](#what-the-workflow-does)). Re-run it once the other run is done.
- **Notarization fails.** `notarize.sh` prints Apple's log for the submission.
- **`verify-live` fails.** The run summary lists the next steps. Usually the fix is to take the release
  out of the update path with `gh release edit vX.Y.Z --prerelease`. "latest" then falls back to the
  previous stable release and its feed. If that release has no `appcast.xml`, as for 1.3.0, the first
  release with the updater, the feed returns 404 until the next release. Background checks then fail
  quietly and *Check now* reports an error, but nothing else breaks.
- **You want to undo a release.** Installed copies never downgrade, so a bad build that is already
  installed can only be replaced by a newer one. The fix is always a new release with a higher build
  number.
- **Never edit `appcast.xml` by hand.** It is signed, and installed copies reject a modified feed.
- **Never publish a "latest" release without `appcast.xml`,** and never delete the latest release's
  `appcast.xml`. Every installed copy would get a 404 and find no updates until a later release brings
  one.
- **Keep the feed URL alive.** If the repository is ever renamed or transferred, GitHub's redirect is
  what keeps old copies updating. Never recreate a repository under the old name.

## Security model

**Who can ship code to every installed copy?** Sparkle installs an update when the DMG's EdDSA signature
verifies against the installed copy's `SUPublicEDKey`. Its key-rotation path also accepts an update that
is signed with a Developer ID of the same team and carries a new key. So either secret is enough,
provided you can also publish a release on this repository. The Developer-ID-only path is slow and
visible, though: installed copies refuse a feed signed with another key for 20 days, and then offer the
update only with a click and without notes (see
[Losing or leaking the EdDSA key](#losing-or-leaking-the-eddsa-key)). Both secrets are in the `release`
environment, behind your GitHub account. This binary runs inside every Claude Code and Codex hook and
can answer permission requests, so that account is the real root of trust.

The protections are proportionate to that:

- **Ordinary 2FA** on the GitHub account and on the Apple ID. Don't keep long-lived personal access
  tokens with repo scope.
- **The required reviewer on `release`.** No signing secret is decrypted until you approve the run, even
  for a tag push.
- **Secrets never reach fork pull requests.** The workflow runs only on a tag push, which needs write
  access. It never uses `pull_request_target`, and it runs the workflow file from the tagged commit.
- **CI guards**:
  - strict tags, with stable releases only from `main`;
  - the tag must still point at the commit being built, at the start of `release` and before publishing;
  - build numbers that only go up;
  - the EdDSA key checked against `SUPublicEDKey`;
  - every signature verified before and after publishing.
- **Pinned supply chain**:
  - third-party actions are pinned to full commit SHAs. To bump one, resolve the new SHA with
    `gh api repos/<owner>/<action>/commits/refs/tags/<version> --jq .sha` (it resolves annotated and
    lightweight tags alike to the commit) and update the comment;
  - Sparkle is pinned exactly via `Package.resolved`;
  - Sparkle's CLI tools come from the same checksum-verified package as the framework;
  - releases are built by a released Xcode, never a beta or a release candidate.
- **The app's own checks**:
  - `SURequireSignedFeed` means nobody can alter the feed, its links or its notes without the key;
  - `SUVerifyUpdateBeforeExtraction` means the DMG is verified before it is even mounted;
  - downgrades are refused.

The remaining risk sits with you: merging a malicious change and then tagging it. Review every pull
request, especially changes to `.github/workflows/`, `Scripts/` and build settings. Sparkle is now a
dependency, so watch [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) (*Custom ▸
Releases + Security alerts*). Dependabot does not see all of its advisories. Treat a Sparkle security
release as a reason to ship.

## Manual release (fallback)

If CI is unavailable, the same scripts run on your Mac. Use the build directory `build/`, which is
git-ignored. Build from a clean checkout of the commit you release, pushed to GitHub.

Once its `<…>` placeholders are filled in, each block below is safe to paste into zsh; run them one at
a time, in one terminal, and read each block's output before the next. First set the version, the build number, the tag and the
signing identity, and check the checkout: nothing uncommitted may go into the build, so stop if the
guard prints STOP. `--require-on-main` applies to stable tags only.

```sh
V=1.3.1 B=5 TAG=v1.3.1 TEAM=<TEAMID> ID="Developer ID Application: <Company> (<TEAMID>)"
git fetch origin
[ -z "$(git status --porcelain)" ] || echo "STOP: uncommitted changes would go into the build"
Scripts/release/check-version.sh --tag "$TAG" --require-on-main
Scripts/release/extract-notes.sh "$V" build/notes.md
```

Build, sign and smoke-test the app:

```sh
xcodebuild -project ccemaphore.xcodeproj -scheme ccemaphore -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/dd -clonedSourcePackagesDirPath build/spm \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
ditto build/dd/Build/Products/Release/ccemaphore.app build/out/ccemaphore.app
Scripts/release/check-app.sh --app build/out/ccemaphore.app --short-version "$V" --build "$B"
Scripts/release/sign-app.sh --app build/out/ccemaphore.app --identity "$ID" --team "$TEAM"
Scripts/release/smoke-test.sh --app build/out/ccemaphore.app
```

Notarize the app, then build and notarize the DMG. Once per Mac, store the notary credentials first:
`xcrun notarytool store-credentials ccemaphore-notary --apple-id <id> --team-id "$TEAM"`.

```sh
export NOTARY_KEYCHAIN_PROFILE=ccemaphore-notary
Scripts/release/notarize.sh --app build/out/ccemaphore.app
Scripts/release/make-dmg.sh --app build/out/ccemaphore.app --out "build/out/ccemaphore-$V.dmg" --identity "$ID" --team "$TEAM"
Scripts/release/notarize.sh --dmg "build/out/ccemaphore-$V.dmg"
```

Fetch the live feed. A 404 means there is none yet: then drop `--prev-feed` from `make-appcast.sh`
below.

```sh
curl -fsSL -o build/prev.xml https://github.com/hakkazuu/ccemaphore/releases/latest/download/appcast.xml
```

Read the EdDSA private key: run this line on its own and paste the key from your password manager at
its prompt (nothing is echoed). Anything pasted along with it would be read as the key.

```sh
read -rs SPARKLE_ED_PRIVATE_KEY && export SPARKLE_ED_PRIVATE_KEY
```

Build the feed and check it against the DMG. `verify-appcast.sh` is the last step that needs the
private key, so the block ends by dropping it from the terminal's environment (if a step fails, read
the key again before you re-run it):

```sh
Scripts/release/make-appcast.sh --dmg "build/out/ccemaphore-$V.dmg" --build "$B" --notes build/notes.md \
  --out-dir build/appcast --prev-feed build/prev.xml --sparkle-bin build/spm/artifacts/sparkle/Sparkle/bin \
  --download-prefix "https://github.com/hakkazuu/ccemaphore/releases/download/$TAG/" \
  --release-page "https://github.com/hakkazuu/ccemaphore/releases/tag/$TAG"
Scripts/release/verify-appcast.sh --feed build/appcast/appcast.xml --dmg "build/out/ccemaphore-$V.dmg" \
  --build "$B" --short-version "$V" --notes build/notes.md --sparkle-bin build/spm/artifacts/sparkle/Sparkle/bin \
  --url "https://github.com/hakkazuu/ccemaphore/releases/download/$TAG/ccemaphore-$V.dmg"
unset SPARKLE_ED_PRIVATE_KEY
```

Publish and check the live release. `gh` uploads both assets before it publishes; add `--prerelease`
for a prerelease (and `--prerelease true` to `verify-live.sh`). `--target` makes the tag that `gh`
creates point at the commit you built; without it, GitHub would tag whatever `main` is now.

```sh
gh release create "$TAG" --target "$(git rev-parse HEAD)" --title "$TAG" --notes-file build/notes.md \
  "build/out/ccemaphore-$V.dmg" build/appcast/appcast.xml
Scripts/release/verify-live.sh --tag "$TAG" --version "$V" --short-version "$V" --build "$B" --prerelease false
```

For a [key rotation](#losing-or-leaking-the-eddsa-key),
add `--signing-pubkey <old public key>` to `make-appcast.sh` and `--pubkey <old public key>` to
`verify-appcast.sh` and `verify-live.sh`. If creating the tag starts the workflow, the run stops in
`preflight` because the release already exists. `make-appcast.sh` runs `generate_appcast` with a
throwaway home folder, so the unpacked copy of the signed app that `generate_appcast` caches is deleted
with it. Afterwards, unregister and delete the local copies. Both the build and running the binary
register the bundle with LaunchServices, and no stray `com.hakkazuu.ccemaphore` copy may stay
registered (see the hard rules in `CLAUDE.md`). The second pass runs on the deleted paths, because a
nested `Updater.app` record can survive the first; there, `lsregister` may print "failed to scan …
-10814", which is expected. The last line must list only your own copies:

```sh
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
unregister_build() {
  for app in build/dd/Build/Products/Release/ccemaphore.app build/out/ccemaphore.app; do
    "$LSR" -u "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    "$LSR" -u "$app"
  done
}
unregister_build; rm -rf build/; unregister_build
"$LSR" -dump | grep -E 'path: .*(ccemaphore|Sparkle)'
```

The App Sandbox is **off**, because the app has to read `~/.claude`. Distribution is therefore
Developer ID plus notarization, outside the Mac App Store.
