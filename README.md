# CapBar

[![CI](https://github.com/kikkimo/CapBar/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kikkimo/CapBar/actions/workflows/ci.yml)
[![Version 0.1.0](https://img.shields.io/badge/version-0.1.0-2F80ED?style=flat-square)](scripts/Info.plist)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-333333?style=flat-square&logo=apple&logoColor=white)](#install-and-use)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](Package.swift)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-0A7F75?style=flat-square)](#build-from-source)
[![License MIT](https://img.shields.io/badge/license-MIT-0A7F75?style=flat-square)](LICENSE)

**Claude Code and Codex usage, together in your macOS menu bar.** CapBar shows the remaining quota, reset time, and capture time for multiple local account profiles in one compact window.

[English](README.md) · [简体中文](docs/README-zh.md)

| Dark appearance | Light appearance |
| :---: | :---: |
| ![CapBar overview in dark appearance](docs/images/overview-dark.png) | ![CapBar overview in light appearance](docs/images/overview-light.png) |

*Illustrations rendered from the CapBar app with fictional `example.com` accounts. No real account data is included.*

## Features

- **Multiple accounts:** Add Claude Code and Codex configuration directories. CapBar identifies available email, plan, and organization details instead of asking for display names.
- **Quota at a glance:** See available 5-hour and 7-day windows, remaining percentages, reset times, and the age of each account's snapshot. A window that the provider does not report stays hidden.
- **Refresh when you choose:** Refresh one account or all idle accounts. Opening the window shows saved snapshots by default. Optional refresh on open checks each account against a shared threshold of 5 minutes by default.
- **Clear states:** Refreshing accounts show progress while keeping their previous values. A failed refresh preserves the last successful snapshot and marks the failure.
- **Native macOS behavior:** Light and dark appearances, a resizable popover, a right-click menu, and an optional launch-at-login setting.

## Install and use

CapBar 0.1.0 requires **macOS 14 or later** on **Apple Silicon**. Download the CI-built installer and checksum from [GitHub Releases](https://github.com/kikkimo/CapBar/releases/latest).

1. Download `CapBar-0.1.0.pkg` and `SHA256SUMS` from the release, then run `shasum -a 256 -c SHA256SUMS` in that folder.
2. Open `CapBar-0.1.0.pkg`. The installer places the app at `/Applications/CapBar.app`.
3. Launch CapBar from Applications. It appears in the menu bar, without a Dock icon.
4. Click the menu bar item to view snapshots. Select **Refresh All (全部刷新)** or refresh an individual account when you want current data.

The installer has no Developer ID signature or Apple notarization. macOS may require an explicit choice in **System Settings → Privacy & Security** after you try to open it; see [Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac). You can also [build from source](#build-from-source).

On first launch, CapBar adds `~/.claude` and `~/.codex` as default entries. Add other configuration directories in the settings view. Right-click the menu bar item for Refresh All, Settings, About CapBar, and Quit. The popover footer also has a Quit action. The app interface currently uses Chinese labels.

**Launch at login is off by default.** Once the app is installed in `/Applications`, enable it in Settings if desired. macOS may require approval in System Settings. The development copy under `dist/` cannot register itself as a login item. Starting at login does not probe accounts; the optional refresh-on-open setting only applies when you open the popover.

## Settings

![CapBar settings with fictional accounts](docs/images/settings.png)

*This settings illustration comes from a development preview, where launch at login is disabled until the app is installed.*

The popover starts at 448 × 620 pt. Enter a precise width or height and submit it, or use the steppers in 10 pt increments. Wider windows rearrange account details horizontally. Snapshots and settings are stored as JSON under `~/Library/Application Support/CapBar/`.

## How quota refresh works

Each Claude refresh attempt starts a short, restricted interactive Claude Code session to obtain a fresh statusline, then queries Anthropic's usage endpoint with the existing OAuth credential for that configuration directory. CapBar uses whichever valid channel is available and selects the newer observation for each quota window. These attempts can consume Claude usage, especially if retries occur. CapBar reads the credential from macOS Keychain for this query, but does not store tokens in its JSON files or logs.

Codex refresh uses the local read-only app-server interface and does not send a conversation. Refreshes can continue after the popover closes; results are saved per account.

## Build from source

You need a Swift 6 toolchain and the macOS command-line packaging tools.

```sh
git clone https://github.com/kikkimo/CapBar.git
cd CapBar
./scripts/package-installer.sh
```

The script runs the checks, builds `dist/CapBar.app`, verifies the app bundle, and creates `dist/CapBar-0.1.0.pkg`. It verifies that the package targets `/Applications` **without relocating** to an existing development copy.

```sh
swift run CapBarChecks
./scripts/render-readme-screenshots.sh
```

The screenshot command renders sample data from the SwiftUI app and updates `docs/images/`. It does not query any real accounts.

## Troubleshooting

**Installer reports success, but CapBar is missing from Applications:** Earlier packages could relocate to an existing `dist/CapBar.app`. Build or use the corrected package and install it again. An installation receipt alone does not prove where the app was placed; check `/Applications/CapBar.app`.

**Launch at login needs approval:** Open the macOS Login Items page using the button shown in CapBar settings, then allow CapBar. The setting is available only in the installed app.

## Project documents

- [Visual design](design/capbar-visual-study.html)
- [Product and engineering specification](design/spec.md)
- [Implementation plan](design/implementation-plan.md)

## License

CapBar is available under the [MIT License](LICENSE).
