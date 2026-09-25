# CapBar 0.1.0 Public Release Plan

## Goal

Publish a public, MIT-licensed CapBar repository and a macOS Apple Silicon installer built from the `v0.1.0` source tag.

## Repository and privacy

- Review every tracked text file, historical Git blob, and committed image for real account identifiers or credentials. Replace the account examples with fictional data.
- Keep the original private repository as an archive because GitHub can still resolve old commits by SHA after a history rewrite. Publish only the sanitized history in a fresh repository at `kikkimo/CapBar`.
- Verify the public repository has only the intended `main` branch and release tag. Verify anonymous access cannot read an old private commit.

## CI and release

- Run `./scripts/package-installer.sh` on an Apple Silicon macOS 15 runner for pull requests and pushes to `main`. The script runs all `CapBarChecks`, builds the release app, checks the bundle, and creates the non-relocatable installer.
- For a `vX.Y.Z` tag, require the tag commit to be on `main` and the tag version to match `scripts/Info.plist`. Upload the installer and a SHA-256 checksum as CI artifacts.
- Once that tag build passes, publish a GitHub Release with the installer, checksum, and versioned release notes. Give only the release job `contents: write` permission.
- State that this first installer uses ad hoc app signing and is not Developer ID signed or notarized. Do not present it as a Gatekeeper-ready signed distribution.

## Verification gates

- Local: `swift run CapBarChecks`, `./scripts/package-installer.sh`, package metadata inspection, `codesign --verify`, checksum verification, and `git diff --check`.
- Remote: the pull request checks pass, its tested commit is merged to `main`, the tag workflow passes, and release assets match the checksums.
- Publication: GitHub reports the new repository as public, the Release tag points to the verified `main` commit, and an unauthenticated request for a commit from the private archive is denied.
