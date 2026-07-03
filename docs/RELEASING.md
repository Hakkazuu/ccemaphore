# Releasing ccemaphore

Maintainer-facing notes for cutting a signed, notarized release. End users don't need any of this —
they just download the DMG from the [Releases](https://github.com/hakkazuu/ccemaphore/releases/latest)
page. This document covers the CI pipeline, the required secrets, and the security model.

The pipeline lives in [`.github/workflows/release.yml`](../.github/workflows/release.yml).

## Cutting a release

```sh
# 1. Bump MARKETING_VERSION in the Xcode target to match the tag you're about to push.
# 2. Tag and push:
git tag v1.0.0
git push origin v1.0.0
```

Pushing a `v*` tag triggers the workflow, which:

1. Builds a **Release** `ccemaphore.app` with `xcodebuild` (newest installed Xcode).
2. Signs it with a **Developer ID Application** certificate — Hardened Runtime, secure timestamp.
3. Packages it into a compressed DMG (via `hdiutil`) with an `/Applications` symlink, and signs the DMG.
4. **Notarizes** the DMG with `notarytool --wait` and **staples** the ticket.
5. Attaches `ccemaphore-<version>.dmg` to the GitHub Release (auto-generated release notes).

The version in the DMG name is derived from the tag (`v1.0.0` → `1.0.0`).

## Required secrets

Add these under **Settings ▸ Secrets and variables ▸ Actions** (or, preferably, scoped to the
`release` environment — see [Security model](#security-model)):

| Secret | What it is |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64 of your *Developer ID Application* certificate exported as `.p12` |
| `P12_PASSWORD` | The password you set when exporting that `.p12` |
| `KEYCHAIN_PASSWORD` | Any throwaway string — password for the temporary CI keychain |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID (e.g. `AB12CD34EF`) |
| `NOTARY_APPLE_ID` | The Apple ID email tied to your developer account |
| `NOTARY_PASSWORD` | An [app-specific password](https://support.apple.com/102654) for that Apple ID |

### Producing the certificate secrets

1. In **Keychain Access**, find your *Developer ID Application* certificate, right-click ▸ **Export**,
   and save a `.p12` with a password (that password becomes `P12_PASSWORD`).
2. Base64-encode it for the secret:
   ```sh
   base64 -i DeveloperID.p12 | pbcopy   # paste into BUILD_CERTIFICATE_BASE64
   ```
3. `NOTARY_PASSWORD` is **not** your Apple ID password — generate an app-specific password at
   <https://account.apple.com> ▸ Sign-In and Security ▸ App-Specific Passwords.

## Security model

**Only the maintainer can produce a signed build.** Three independent barriers make it impossible for
an outside contributor to get malicious code signed with your certificate:

1. **Secrets are never exposed to fork pull requests.** GitHub does not pass repository/environment
   secrets to workflows triggered by a PR from a fork. A malicious PR — even one that rewrites this
   workflow — runs with empty secrets, so there's nothing to sign with.
2. **The workflow only triggers on `push` of a `v*` tag.** Pushing tags requires **write access** to
   the repo, which outside contributors don't have. We deliberately use `on: push: tags`, never the
   dangerous `pull_request_target` (which *would* run fork code with secret access).
3. **The workflow is taken from the tagged commit**, not from any PR. A workflow edit inside a PR has
   no effect on the protected run.

### Residual risk & hardening

The only remaining risk is a supply-chain one that lives with **you**: if you merge a malicious PR and
then tag it, that code gets built and signed. It's mitigated by process, not by CI config:

- **Review every PR before merging** — pay special attention to changes under `.github/workflows/**`,
  `Scripts/`, and build settings.
- **Gate the secrets behind a protected Environment.** The workflow declares `environment: release`.
  Create it under **Settings ▸ Environments ▸ `release`**, add yourself as a **Required reviewer**, and
  move the six secrets there. Now every tag push *pauses* and waits for you to click **Approve** before
  the secrets are ever decrypted — a manual gate on top of the automatic ones above.
- **Pin third-party actions to a full commit SHA** (already done: `actions/checkout` and
  `softprops/action-gh-release`). This stops a compromised action *tag* from injecting code into the
  secret-bearing run. To bump one, resolve the new SHA and update both the pin and the `# vN` comment:
  ```sh
  gh api repos/softprops/action-gh-release/git/ref/tags/v2 --jq '.object.sha'
  ```
- **Restrict who can create tags** via a repository ruleset (Settings ▸ Rules ▸ Rulesets ▸ tag
  protection) if more people gain write access.

## Manual release (fallback)

If you ever need to build and notarize locally instead of via CI:

```sh
# Build a Release .app (unsigned):
Scripts/package_app.sh                      # → build/ccemaphore.app

# Sign it with your Developer ID (Hardened Runtime, timestamp):
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" build/ccemaphore.app

# Package + notarize + staple (plain hdiutil, mirrors CI):
mkdir -p build/dmg-src && cp -R build/ccemaphore.app build/dmg-src/
ln -s /Applications build/dmg-src/Applications
hdiutil create -volname ccemaphore -srcfolder build/dmg-src -fs HFS+ -format UDZO -ov \
  build/ccemaphore-1.0.0.dmg
xcrun notarytool submit build/ccemaphore-1.0.0.dmg \
  --apple-id "you@example.com" --password "app-specific-password" --team-id "TEAMID" --wait
xcrun stapler staple build/ccemaphore-1.0.0.dmg
```

App Sandbox is **off** (required to read `~/.claude`), so distribution is Developer-ID + notarization,
outside the Mac App Store.
