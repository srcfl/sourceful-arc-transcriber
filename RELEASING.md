# Releasing

## TL;DR

A commit on `main` whose **subject line** starts with `patch:`, `minor:`,
or `major:` triggers a signed + notarized build and a new GitHub Release.

```
patch: fix mic meter on stereo inputs         → v0.1.2 → v0.1.3
minor: add Arc inbox upload                   → v0.1.3 → v0.2.0
major: rewrite transcript storage             → v0.2.0 → v1.0.0
```

Anything else on main builds nothing.

The running app polls `releases/latest` every 6 h and every time the
user picks "Check for updates…"; when the remote `tag_name` beats the
bundled `CFBundleShortVersionString`, it offers to install and restart.

## First-time setup (required once)

The workflow needs five GitHub Secrets. Add them at
`https://github.com/srcfl/sourceful-arc-transcriber/settings/secrets/actions`.

| Secret | What it is | How to get it |
|---|---|---|
| `APPLE_CERTIFICATE_BASE64` | Developer ID Application cert `.p12` base64-encoded | Export from Keychain Access → Right-click the Developer ID cert → Export → `.p12`. Then `base64 -i cert.p12 \| pbcopy`. |
| `APPLE_CERTIFICATE_PASSWORD` | Password you set when exporting the `.p12` | — |
| `APPLE_ID` | Your Apple Developer account email | — |
| `APPLE_TEAM_ID` | 10-char team identifier | [developer.apple.com → Membership → Team ID](https://developer.apple.com/account/) |
| `APPLE_APP_PASSWORD` | App-specific password for `notarytool` | [appleid.apple.com → Sign-In and Security → App-Specific Passwords](https://appleid.apple.com/) |

After adding them, verify with:

```bash
gh secret list --repo srcfl/sourceful-arc-transcriber
```

You should see all five.

## Bootstrapping the first release

From a clean `main`, make any change, then commit with a `patch:` prefix:

```bash
git commit -m "patch: first release"
git push
```

The workflow will:

1. Parse the commit → `release_type=patch`
2. Look for the latest `v*` tag, find none, start from `v0.0.0`
3. Bump to `v0.0.1`, build, sign, notarize, zip
4. Attach `Transcriber-0.0.1-macos-arm64.zip` to a fresh GitHub Release

From that point on every `patch:`/`minor:`/`major:` commit produces the
next version in sequence. You never edit a version file — the git tag
history is the source of truth.

## Manual trigger

If you want a release without making a real commit:

```
Actions → Build & Release → Run workflow
  release_type: patch | minor | major
  release_title: <free text>
```

Same pipeline. Uses the latest tag + the chosen bump.

## What ends up in the Release

- Title: `v<X.Y.Z> — <commit-subject-after-prefix>`
- Body: commit body (excluding `Co-Authored-By:` lines)
- Asset: `Transcriber-<X.Y.Z>-macos-arm64.zip` — unzip, drag to Applications

## Local dev still uses `build.sh`

The shell script keeps the ad-hoc-signed local workflow for day-to-day
iteration. It does **not** use your Developer ID cert; you get a
build that runs fine on your own machine but isn't distributable.
Switch back and forth without changing anything.

## Debugging a failed release

- **"No identity found"** in `Sign with hardened runtime`: the `.p12`
  didn't import. Usually wrong password or the `.p12` is missing the
  private key. Re-export from Keychain with **both** certificate and
  key ticked.
- **Notarization fails**: `xcrun notarytool log <submission-id> --apple-id … --team-id … --password …` from any Mac will give the detailed reason. Most common: missing hardened-runtime flag, which we do pass; second most common: entitlements the cert isn't approved for.
- **Deploy ran but no Release appeared**: check `check-release` job —
  probably the commit prefix didn't match. Remember the space: `patch: msg`, not `patch:msg`.
