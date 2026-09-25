# CapBar v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkboxes for tracking.

**Goal:** Build a working macOS menu bar app that shows per-account Claude Code and Codex quota snapshots, manual refresh, and optional refresh when opening the popover.

**Architecture:** A SwiftPM executable and core library host an AppKit status item and a SwiftUI popover. Pure Swift models, parsers, persistence, and an actor-based refresh coordinator sit behind provider interfaces; Claude uses a restricted PTY session plus OAuth read, while Codex uses app-server JSON-RPC. All refresh policy values come from a bundled JSON resource.

**Tech Stack:** Swift 6.3, Foundation, AppKit, SwiftUI, Security, Swift Package Manager; no third-party runtime packages.

**Spec:** [spec.md](spec.md), with the approved visual contract in [capbar-visual-study.html](capbar-visual-study.html).

## Global Constraints

- Minimum OS: macOS 14; initial distributable target: Apple Silicon macOS `.app`.
- No background quota polling. User settings: account directories, open-popover auto-refresh toggle (off by default), one shared threshold (5 minutes by default).
- Internal retry policy is bundled, not hard-coded in refresh logic or exposed in user settings: 3 attempts total, 45-second per-attempt timeout, randomized 10–20-second retry delay in the initial resource file.
- Default Claude directory launches without `CLAUDE_CONFIG_DIR`; custom directories use their absolute paths. Provider identities and quota values come from the real accounts, never from editable display names.
- No OAuth token, raw provider payload, or conversation text in snapshots or logs. Never execute Claude tools or MCP during probes.
- `references/AIBar` remains ignored reference material. Do not copy its source into CapBar.
- Run `swift run CapBarChecks` as the test gate: the installed Command Line Tools lack runnable XCTest, and Swift Testing compiles without discovering tests here. Test-first for domain rules, parsers, storage, refresh concurrency, retries, and provider protocols. Visual styling receives screenshot/manual QA against the HTML.

## File Map

| File or directory | Responsibility |
| --- | --- |
| `Package.swift`, `Sources/CapBarCore/Resources/ProbePolicy.json` | SwiftPM target and bundled probe policy. |
| `Sources/CapBarCore/Domain/Models.swift` | Account IDs, identity, quota windows, snapshots, errors. |
| `Sources/CapBarCore/Domain/TimeLabel.swift` | Relative and absolute collection-time copy. |
| `Sources/CapBarCore/Storage/SettingsStore.swift`, `SnapshotStore.swift` | Versioned, private, atomic JSON persistence. |
| `Sources/CapBarCore/Refresh/RetryRunner.swift`, `RefreshCoordinator.swift` | Retry classification, per-account single flight, all/open triggers. |
| `Sources/CapBarCore/Providers/Codex/` | Codex app-server transport and response parser. |
| `Sources/CapBarCore/Providers/Claude/` | Claude auth/Keychain, statusline/OAuth parsing, PTY session, source selection. |
| `Sources/CapBar/App/`, `Sources/CapBar/UI/` | Status item, popover, account rows, settings, visual states. |
| `Tests/CapBarChecks/, `Tests/Fixtures/` | Unit tests, fake clocks/providers/processes, sanitized response fixtures. |
| `scripts/package-app.sh`, `scripts/Info.plist` | SwiftPM executable to local `.app` bundle and ad-hoc signature. |

## Review Focus

The following cases need explicit tests in their owning tasks:

1. Two configurations with the same email remain separate because provider＋directory is the key (Tasks 1–2).
2. A failed automatic probe records `lastAttemptAt`, retains `capturedAt`, and does not retrigger within the threshold (Tasks 2–3).
3. Repeated “全部刷新” skips in-flight accounts without queueing a second request (Task 3).
4. Codex response with only a seven-day `primary` window shows no invented five-hour window (Task 4).
5. Claude statusline absent or OAuth rejected still succeeds if the other channel yields a valid window, and no token enters logs (Tasks 5–6).

---

### Task 1: SwiftPM shell, domain models, bundled policy

**Files:** Create `Package.swift`, `Sources/CapBarCore/Domain/Models.swift`, `Sources/CapBarCore/Resources/ProbePolicy.json`, `Tests/CapBarChecks/ModelChecks.swift`, `Sources/CapBar/App/main.swift`.

**Interfaces:**

```swift
enum Provider: String, Codable, Sendable { case claude, codex }
struct AccountID: Hashable, Codable, Sendable { let provider: Provider; let directory: String }
struct AccountIdentity: Codable, Sendable { let email: String?; let plan: String?; let organization: String? }
enum WindowKind: String, Codable, Sendable { case fiveHour, sevenDay }
struct QuotaWindow: Codable, Sendable { let kind: WindowKind; let remainingPercent: Double; let resetsAt: Date? }
struct UsageSnapshot: Codable, Sendable { let identity: AccountIdentity; let windows: [QuotaWindow]; let capturedAt: Date }
struct ProbePolicy: Codable, Sendable { let maxAttempts: Int; let attemptTimeoutSeconds: Double; let retryDelayMinSeconds: Double; let retryDelayMaxSeconds: Double }
```

- [ ] **RED:** Add tests that canonicalizing `~/.claude` and its absolute spelling yields the same `AccountID`, two directories with the same email remain distinct, and invalid policy values reject decoding/validation. Run `swift run CapBarChecks --filter ModelTests`; expect failures because the types are absent.
- [ ] **GREEN:** Add the package with a `CapBarCore` library, `CapBar` executable, and `CapBarChecks` executable check target. Implement the models, directory normalization, percentage validation, and `ProbePolicy.validate()`. Put `3 / 45 / 10 / 20` into `ProbePolicy.json`, include it as a SwiftPM resource, and make a minimal executable entry point. Run `swift run CapBarChecks --filter ModelTests`; expect all tests to pass.
- [ ] **REFACTOR/VERIFY:** Run `swift run CapBarChecks` and `swift build`; confirm the bundle resource can be loaded in tests. Commit this independently buildable foundation.

### Task 2: JSON settings, snapshots, and time labels

**Files:** Create `Sources/CapBarCore/Storage/SettingsStore.swift`, `SnapshotStore.swift`, `Sources/CapBarCore/Domain/TimeLabel.swift`, `Tests/CapBarChecks/StorageChecks.swift`, `TimeLabelChecks.swift`.

**Interfaces:**

```swift
struct UserSettings: Codable, Sendable {
    var accounts: [AccountID]
    var defaultsSeeded: Bool
    var autoRefreshOnOpen: Bool
    var refreshThresholdMinutes: Int
}
struct AccountRecord: Codable, Sendable {
    let id: AccountID
    var snapshot: UsageSnapshot?
    var lastAttemptAt: Date?
    var lastError: String?
}
actor SettingsStore { func loadOrSeed() throws -> UserSettings; func save(_ value: UserSettings) throws }
actor SnapshotStore { func load() throws -> [AccountID: AccountRecord]; func update(_ record: AccountRecord) throws }
func capturedAtLabel(_ date: Date?, now: Date, calendar: Calendar) -> String
```

- [ ] **RED:** In temp directories, test first-run default seeding once, removal of `~/.claude` surviving a new store instance, two accounts with the same email preserving separate records, concurrent updates preserving both, and corrupt JSON returning a readable error without overwriting the file. Test time labels at 3 minutes, 59 minutes, 60 minutes, and a prior year. Run `swift run CapBarChecks --filter StorageTests` and `swift run CapBarChecks --filter TimeLabelTests`; expect failures.
- [ ] **GREEN:** Implement versioned `settings.json` and `snapshots.json` under Application Support, with `0600` permissions, a serialized actor write path, and atomic replacement. Keep `lastAttemptAt` independent from `snapshot.capturedAt`. Implement time copy exactly as the spec states. Run the two filtered test suites; expect passes.
- [ ] **REFACTOR/VERIFY:** Run `swift run CapBarChecks`, inspect written JSON for absence of secrets, and commit storage/time formatting.

### Task 3: Refresh coordinator and retry state machine

**Files:** Create `Sources/CapBarCore/Refresh/RefreshCoordinator.swift`, `RetryRunner.swift`, `Tests/CapBarChecks/RefreshCoordinatorChecks.swift`, `RetryRunnerChecks.swift`.

**Interfaces:**

```swift
enum ProbeFailure: Error, Sendable { case transient(String), permanent(String) }
protocol UsageProvider: Sendable { func probe(account: AccountID) async throws -> UsageSnapshot }
actor RefreshCoordinator {
    func requestRefresh(_ id: AccountID) async -> Bool
    func requestRefreshAll() async -> Int
    func openedPopover(settings: UserSettings) async -> Int
    func state() async -> [AccountID: AccountRecord]
}
```

- [ ] **RED:** Use controllable fake providers and a fake clock/sleeper. Assert a running account rejects a second single refresh, “全部刷新” starts only idle accounts while its button stays usable, opening with the toggle off starts none, opening with the toggle on checks each account's `lastAttemptAt`, a failed attempt remains on cooldown, and closing the popover has no cancellation effect. Assert transient failures attempt at most three times with jitter values in range, while permanent failures attempt once. Run `swift run CapBarChecks --filter RefreshCoordinatorTests` and `swift run CapBarChecks --filter RetryRunnerTests`; expect failures.
- [ ] **GREEN:** Implement one in-flight task per `AccountID` in an actor. Persist `lastAttemptAt` at start, expose state changes to the UI, use injected provider/clock/random delay to make tests deterministic, and preserve old snapshots on failure. Read `ProbePolicy` from the bundled resource and reject invalid policy at launch. Run both filtered suites; expect passes.
- [ ] **REFACTOR/VERIFY:** Run `swift run CapBarChecks`; inspect that no popover-close event cancels a task and no second task is queued for a busy account. Commit the coordinator.

### Task 4: Codex app-server adapter

**Files:** Create `Sources/CapBarCore/Providers/Codex/CodexPayload.swift`, `CodexClient.swift`, `CodexProcess.swift`, `Tests/CapBarChecks/CodexClientChecks.swift`, `Tests/Fixtures/codex-weekly-only.json`, `codex-two-windows.json`.

**Interfaces:** `CodexClient: UsageProvider`; `CodexPayload.decodeRateLimits(_:) throws -> [QuotaWindow]`; process transport accepts injected executable path and environment for tests.

- [ ] **RED:** Add sanitized JSON fixtures for a seven-day-only `primary` window, a two-window response, absent `rateLimitsByLimitId`, `account/read` with null email, and a JSON-RPC error. Assert mapping by `windowDurationMins`, remaining percentage conversion, and absence of invented windows. Assert custom account directories set `CODEX_HOME` and process arguments request read-only mode with approval policy `never`. Run `swift run CapBarChecks --filter CodexClientTests`; expect failures.
- [ ] **GREEN:** Implement `initialize` → `initialized` → `account/read` → `account/rateLimits/read` over one app-server stdio connection, choose the Codex metered bucket when present, and parse primary/secondary by duration. Bound process lifetime by policy, terminate on timeout, and redact diagnostics. Run the filtered suite; expect passes.
- [ ] **REFACTOR/VERIFY:** Run `swift run CapBarChecks` and an opt-in local read of one configured Codex account; verify the current machine's seven-day-only response. Commit the adapter.

### Task 5: Claude parsing, identity, credentials, and source selection

**Files:** Create `Sources/CapBarCore/Providers/Claude/ClaudePayload.swift`, `ClaudeCredentials.swift`, `ClaudeObservation.swift`, `Tests/CapBarChecks/ClaudeParsingChecks.swift`, `Tests/Fixtures/claude-statusline.json`, `claude-oauth.json`.

**Interfaces:** `ClaudeObservation` carries optional windows and a local `observedAt`; `ClaudeObservation.select(_:_:)` produces one `UsageSnapshot`; credential loader returns an in-memory token only.

- [x] **RED:** Test statusline missing five-hour or seven-day windows, OAuth `utilization` values 0/100, percent conversion, reset parsing, per-window selection of the later observation, fallback when one source is absent, and complete failure when neither has a valid window. Test `claude auth status --json` identity parsing and Keychain services: default `Claude Code-credentials`, custom `Claude Code-credentials-` plus the first 8 hex digits of SHA-256 of the normalized absolute path. Exercise the bounded `/usr/bin/security` reader with a fake executable, including timeout; do not access real credentials in automated tests. Assert token and raw payload are absent from `AccountRecord` JSON and formatted errors. Run `swift run CapBarChecks --filter ClaudeParsingTests`; expect failures.
- [x] **GREEN:** Parse both provider shapes into a common observation; use the local receipt time per window for selection. Read the correct per-directory Claude credentials through a bounded `/usr/bin/security` child process with no persistent copy. Keep identity fields optional. Run the filtered suite; expect passes.
- [x] **REFACTOR/VERIFY:** Compare sanitized fixtures against the five observed local profile shapes without committing secrets. Run `swift run CapBarChecks`, then commit parsers and credential abstraction.

### Task 6: Restricted Claude interactive probe

**Files:** Create `Sources/CapBarCore/Providers/Claude/ClaudeClient.swift`, `ClaudeTerminalSession.swift`, `ClaudeOAuthClient.swift`, `Tests/CapBarChecks/ClaudeClientChecks.swift`.

**Interfaces:** `ClaudeClient: UsageProvider`; `ClaudeTerminalSession` protocol exposes `start`, `send`, `readStatusline`, `stop`, and `terminate` so tests never consume real tokens.

- [x] **RED:** With a fake terminal and HTTP client, assert the order one prompt → statusline wait → OAuth GET → `/exit`, one prompt per attempt, OAuth fallback when statusline is absent, statusline fallback when OAuth fails, and termination/temporary-file cleanup on timeout. Assert the default profile leaves `CLAUDE_CONFIG_DIR` unset, custom profiles set it, and launch flags disable tools and MCP. Run `swift run CapBarChecks --filter ClaudeClientTests`; expect failures.
- [x] **GREEN:** Implement a PTY-backed `Process`, app-owned temporary cwd and statusline capture script, `--restricted`, `--tools ""`, `--strict-mcp-config`, temporary `--settings`, OAuth usage read, and guaranteed process cleanup. Do not mutate the user's Claude settings or credentials. Return success if either channel has a valid window. Run the filtered suite; expect passes.
- [x] **REFACTOR/VERIFY:** Run `swift run CapBarChecks`. Perform one real-account integration probe with the smallest prompt, check statusline/OAuth fields, `/exit` completion, and absence of an orphan Claude process; keep token and raw transcript out of output. Commit the Claude adapter.

### Task 7: Native menu bar UI and settings

**Files:** Create `Sources/CapBar/App/CapBarApp.swift`, `StatusItemController.swift`, `Sources/CapBar/UI/PopoverView.swift`, `AccountRowView.swift`, `SettingsView.swift`, `TimeLabelView.swift`, `Tests/CapBarChecks/PopoverModelChecks.swift`; retire the Task 1 minimal `main.swift` entry point.

**Interfaces:** A main-actor presentation model observes coordinator state and provides per-account rows, menu summary, button enabled state, and settings actions.

- [x] **RED:** Test presentation mapping for snapshot/loading/error/no-snapshot, per-account button disabled only during its own refresh, global button always enabled, hidden five-hour window when missing, and elapsed-time label updates without calling providers. Run `swift run CapBarChecks --filter PopoverModelTests`; expect failures.
- [x] **GREEN:** Create an `NSStatusItem` and `NSPopover` with SwiftUI content. Wire open/close, manual all/single refresh, add/remove directories, the default-off auto-on-open switch, and the shared threshold. Keep live tasks in the coordinator when the popover closes. Reproduce the approved HTML's typography, spacing, grouping, light/dark states, and loading/error states with native controls. Run `swift run CapBarChecks --filter PopoverModelTests`; expect passes.
- [x] **REFACTOR/VERIFY:** Build and launch locally; compare light and dark popover states against the HTML and inspect normal, loading, failure, and no-snapshot renderings with `swift run CapBarChecks --render-popover`. Native refresh buttons have account-specific accessibility labels and the standard SwiftUI keyboard behavior.

### Task 8: Bundle, integration, and delivery

**Files:** Create `scripts/package-app.sh`, `scripts/Info.plist`; update root `README.md`, `design/README.md`, and `.gitignore` only as needed for generated output.

- [x] **RED:** Run packaging checks against an empty output directory; they should fail because the bundle script and executable are not yet present. Specify assertions for `CFBundleExecutable`, `LSUIElement=true`, a bundled `ProbePolicy.json`, valid `plutil`, `codesign --verify`, and no credentials in packaged resources.
- [x] **GREEN:** Script `swift run CapBarChecks`, `swift build -c release --product CapBar`, copy the executable and SwiftPM resources into `CapBar.app/Contents`, install `Info.plist` and an app icon, and ad-hoc sign using the available Command Line Tools. Package the app in a local `.pkg` for `/Applications`. Add local build/run instructions and explain where user settings and snapshots live. Keep the ignored AIBar checkout out of the bundle.
- [x] **REFACTOR/VERIFY:** Run 135 fixture checks, the app bundle self-check, `plutil -lint`, `codesign --verify --deep --strict`, and a local launch. Live default-account checks verified Claude's statusline and OAuth, Codex app-server, and a full manual all-account refresh that persisted both snapshots and fed the popover model. The installer is locally built and unsigned; distribution signing and notarization remain outside v1.

## Plan Self-Review

- Spec coverage: Tasks 1–2 cover identity, config, storage, and time; Task 3 covers triggers/retries; Tasks 4–6 cover both providers; Task 7 covers the visual contract; Task 8 covers packaging and end-to-end verification.
- Review Focus cases are tied to explicit failing tests in Tasks 1–6.
- Development proceeds RED → GREEN → REFACTOR per task. Integration probes that consume Claude tokens run only when needed for a concrete provider risk; fixture tests remain the default.
- Implementation begins after review of this spec and plan, using `superpowers:executing-plans` and native in-session work; no subagents are required.
