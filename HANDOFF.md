# Zoid Lock In — Comprehensive Agent Handoff Document

This document provides complete architectural, operational, and development context for any autonomous agent or developer continuing work on the **Zoid Lock In** macOS project.

---

## 1. Executive Summary & Project Mission

**Zoid Lock In** is a high-discipline, local-first macOS productivity system and behavioral economy designed to enforce extreme focus and eliminate digital distraction. It combines a kernel-level enforcement layer (Network Extension and LaunchDaemon process sentinel) with an internal economic ledger, amenity marketplace, 48-hour governance rate-limiting, and a Japanese SUMI-E Ink visual aesthetic.

- **Primary Repository:** `/Users/ziadnasreldin/Work/GitHub/Zoid Lock In`
- **Current Deployed Artifact:** `/Applications/Zoid Lock In.app` (active in menu bar)
- **Primary Specification Documents:**
  - [`PRODUCT.md`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/PRODUCT.md) — Product requirements, game mechanics, and economic doctrine.
  - [`PRD.md`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/PRD.md) — Exhaustive functional requirements (Requirements 1–49).
  - [`SPEC.md`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/SPEC.md) — Technical specifications, database schemas, IPC interfaces, and security model.

---

## 2. Status of the 9 Vertical Slices

All 9 vertical slices outlined in the architectural specification are implemented and verified:

1. **Slice 1: Network Extension & Enforcer Prototype**
   - Implemented `SMAppService.daemon` LaunchDaemon integration, `ContentFilterProvider` socket-level filtering (`filterSockets = true`, `filterPackets = false`, bundle identifier `com.mavoid.zoidlockin.filter`) for restricted domains, and 1.5s background process scan (`SIGSTOP`/`SIGKILL` on distraction processes).
2. **Slice 2: XPC Gatekeeper & Emergency Valve**
   - Secure Mach-O XPC with `audit_token_t` entitlement verification, 5-second press-and-hold Emergency Safety Valve granting 30-minute unhindered access with incident audit email dispatch and -2.0 credit penalty, and unprivileged daemon heartbeat.
3. **Slice 3: Core Economic Ledger & Menu Bar Ticker**
   - `ExchangeEngine` (NTP clock sync, 2.0x morning momentum bonus, 5-minute grace tolerance, debt carryover, 22:00 curfew, Friday rest mode) backed by atomic SQLite in WAL mode with append-only triggers via direct `libsqlite3` C-APIs, plus SUMI-E menu bar ticker.
4. **Slice 4: Marketplace Catalog & Amenity Passes**
   - Purchasing of temporary amenity passes (Food, Phone, Bed, Streaming, Gaming, Rest) backed by SQLite transactions, pass auto-expiration, and socket-level re-locking.
5. **Slice 5: Cross-Device Mobile Shield**
   - Encrypted state synchronization via `EncryptedStateStore` (`state.json`, AES-GCM) in the ubiquitous iCloud container with local `mobile-shield` fallback, and silent APNs push relay via Cloudflare Worker for iOS Shortcuts lockdown.
6. **Slice 6: Offline Meeting Triple-Gate Core (Local)**
   - Monotonic punch-in/punch-out timer, triple-artifact verification (Notes, Receipt, Environment Photo), ImageIO EXIF inspection, SHA-256 digests, and 30-day raw artifact purge.
7. **Slice 7: Multimodal AI Audit Integration**
   - Automated agenda note and photo verification via Gemini Flash, prompt injection sanitization, unique meeting reference minting, and Gemini Pro arbitration after 3 rejections.
8. **Slice 8: Customizable Micro-Habits & Governance**
   - Daily discipline tasks awarding credits up to 1.50c/day, frequency limits from 1x to 5x daily, cascading habit deletion, and 48-hour monotonic configuration cooldown.
9. **Slice 9: SUMI-E Ink Desktop Dashboard & Calibration**
   - Standalone SUMI-E Ink desktop command dashboard window, 3-day soft calibration mode with infraction tracking, PBKDF2-SHA256 password auth, RFC 6238 TOTP 2FA gatekeeper, and pre-production cooldown bypass (PRD #45).

---

## 3. Toolchain, Build, and Test Procedures

### Testing Command Line
The test suite utilizes Swift Testing. When running under the macOS Command Line Tools environment, framework and runtime library search paths must be specified:

```bash
swift test \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

- **Current Test Status:** **271 tests across 33 test suites passing with 0 failures (100% green).**

### Application Packaging & Local Deployment
The project contains an automated packaging script that compiles release binaries, copies launch daemons and resource bundles, embeds icons, and codesigns the application:

```bash
cd "/Users/ziadnasreldin/Work/GitHub/Zoid Lock In"
./scripts/package_app.sh
```

To install and launch the packaged app:
```bash
pkill -f "/Applications/Zoid Lock In.app/Contents/MacOS/ZoidLockInApp" || true
cp -R "build/Zoid Lock In.app" /Applications/
open "/Applications/Zoid Lock In.app"
```

---

## 4. Database Schemas & Storage Architecture (Direct SQLite3 C-APIs, Zero GRDB)

The local persistence engine uses atomic SQLite with WAL mode (`PRAGMA journal_mode = WAL;`), foreign keys (`PRAGMA foreign_keys = ON;`), and serialized write transactions via direct system `libsqlite3` C-APIs rather than third-party GRDB or ORMs. This ensures zero third-party dependencies and kernel-safe shared headers, guaranteeing that the privileged LaunchDaemon helper never links or inherits database engine code.

The local database is located at `~/Library/Application Support/ZoidLockIn/db.sqlite` (or isolated temporary paths during testing), managed via [`SQLiteEconomicLedger`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/SQLiteEconomicLedger.swift). Append-only ledger integrity is strictly protected against tampering by database-level SQLite triggers (`wallet_transactions_no_update`, `wallet_transactions_no_delete`).

### Primary Tables:
1. **`wallet_transactions`**: Append-only ledger recording all minted focus credits, habit credits, amenity purchases, refunds, and debt strikes. Enforced by immutable SQLite triggers preventing update or deletion.
2. **`micro_habits`**: Catalog of daily discipline habits (`id`, `title`, `reward_credits`, `daily_frequency_limit`, `is_enabled`, timestamps).
3. **`micro_habit_completions`**: Individual completions of micro-habits linked to civil dates and monotonic timestamps.
4. **`governance_state`**: Monotonic mutation baseline, boot session identifier, accrued monotonic elapsed time, and pinned time zone.
5. **`governance_seal`**: Serialized HMAC envelope verifying governance state integrity against clock tampering and direct disk modifications.
6. **`calibration_state`**: Tracks the 3-day soft calibration window and logged infractions.
7. **`offline_meetings`**: Punch-in/out timestamps, artifact SHA-256 hashes, audit status, and awarded credits.
8. **`amenity_price_overrides`**: Custom pricing rules for marketplace items.
9. **`blocklist_rules`**: Custom domain suffix rules enforced by the network filter.

---

## 5. Recent Changes & Newly Landed Capabilities

### 1. Network Extension Activation UI Flow in Command Dashboard (PRD #21, SPEC §5.2)
- **Problem Solved:** Activating Apple's Network Extension content filter requires unprivileged app-level system extension authorization and preferences configuration that previously lacked user guidance.
- **Solution:** Integrated `ContentFilterManager` and `ContentFilterSettingsCard` into the Command Dashboard Settings view:
  - Reactively displays filter status chips (`DISABLED`, `PENDING USER APPROVAL IN SYSTEM SETTINGS`, `ENABLED · CONTENT FILTER`, `ACTIVATION FAILED`).
  - Action button triggers `requestActivation()` submitting an `OSSystemExtensionRequest` to prompt macOS System Settings authorization.
  - Automatically loads and applies `NEFilterProviderConfiguration` via `NEFilterManager.shared()` (explicitly targeting socket filtering via `filterSockets = true`, `filterPackets = false`, provider bundle identifier `com.mavoid.zoidlockin.filter`) and setting `disableEncryptedDNSSettings = true` on macOS 15+ to prevent DNS-over-HTTPS / Private Relay circumvention.
  - Verified with comprehensive test coverage in `ContentFilterActivationTests` and `ContentFilterManagerTests`.

### 2. Ported Zoid 0 Live Activity Tracking Engine (`ZoidZeroLiveTracker` & `FocusSessionCoordinator`)
- **Ported Architecture:** Ported directly from Zoid 0's proven application activity and idle tracking stack, dropping legacy ScreenCaptureKit window captures in favor of lightweight application activation notifications and event source sampling.
- **Frontmost Workspace Observation:** `ZoidZeroLiveTracker` observes frontmost application transitions via `NSWorkspace.didActivateApplicationNotification` against a whitelist of productive tools (Xcode, Cursor, VS Code, Terminal, Warp, iTerm2, Linear, Notion, Obsidian, GitHub Client, Figma, Slack, Teams), plus system sleep/wake and display lock/unlock lifecycle hooks.
- **Anti-Idle Physical HID Sampling:** Taps macOS event streams with `CGEventSource.secondsSinceLastEventType(.combinedSessionState, anyInputEventType)` via a 5-second polling timer against a 90-second pause threshold.
- **Layered Architecture & Automated Focus Coordination:**
  - **Tracker Layer (`ZoidZeroLiveTracker`):** Pauses at 90s idle (`TrackingPauseReason.idle`) or when switching away from productive apps.
  - **Economic Engine Layer (`FocusMinting` / `ExchangeEngine`):** Manages session presence: typing pauses `<= 30s` remain in active focus; `30s < idle < 300s` enters the 300-second grace window; idle `>= 300s` abandons and resets the uncompleted block.
  - **Coordination Layer (`FocusSessionCoordinator`):** Drives `ExchangeEngine.startFocus()` on verified productive activity and ticks the engine to evaluate grace windows and credit milestones.

### 3. Encrypted Mobile Shield State Store with Local Fallback & Push Relay
- **Encrypted State Envelope:** `EncryptedStateStore` persists lock and amenity pass states as versioned AES-GCM encrypted envelopes (`state.json`) with monotonic sequence high-water marks and anti-time-travel guards.
- **Seamless Local Fallback:** Resolves the ubiquitous iCloud container (`iCloud~com~mavoid~zoidlockin`) with an automatic, resilient fallback to local application support (`~/Library/Application Support/ZoidLockIn/mobile-shield/state.json`) when iCloud is unavailable or during test execution.
- **Silent APNs Push Relay:** Dispatches authenticated state change payloads via `PushRelayClient` to a Cloudflare Worker relay that emits silent APNs background notifications (`content-available: 1`) to toggle paired iOS Shortcuts Focus Filters.

### 4. 48-Hour Rate Limiting & Cooldown Pre-Production Bypass Mode (PRD #45)
- **Problem Solved:** Modifying an amenity price or adding a custom blocklist rule would immediately activate a 48-hour hard cooldown, locking all administrative settings on development/test machines.
- **Solution:** Implemented the pre-production bypass mode specified in PRD Requirement 45.
  - Added `bypassCooldown` controls in [`GovernanceLockCoordinator`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInCore/Economy/GovernanceLockCoordinator.swift).
  - Added dedicated UI toggles (`BYPASS 48H COOLDOWN` / `RESET 48H COOLDOWN`) in the Command Dashboard Settings view and in the governance sidebar card.
  - Added disk reset capabilities to clear orphaned SQLite lock states.

### 5. Micro-Habits 5x Daily Frequency & Habit Deletion
- **Expanded Daily Cap:** Increased `HabitCreditMinting.maxDailyFrequency` from 2 to 5 in [`MicroHabitRecords`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInCore/Economy/MicroHabitRecords.swift) to support frequent routines (e.g., 5 daily prayers).
- **UI Frequency Selectors:** Updated the habit creation form in [`CommandDashboardView`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/CommandDashboardView.swift) to include options from `1x/day` through `5x/day`, and added chips (`1x` to `5x`) in [`MicroHabitsView`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/MicroHabitsView.swift).
- **Deletion Support:** Added `deleteHabit(id:)` across [`MicroHabitStoring`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInCore/Economy/MicroHabitStore.swift), [`SQLiteEconomicLedger`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/SQLiteMicroHabits.swift), [`MicroHabitCoordinator`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInCore/Economy/MicroHabitCoordinator.swift), and [`MenuBarSession`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInApp/ZoidLockInApp.swift).
- **UI Delete Action:** Each habit row now includes a `DELETE` button, disabled when the configuration is strictly locked.

---

## 6. Key Source File Directory

| Module / Component | Path | Description |
|---|---|---|
| **App Entry Point** | [`Sources/ZoidLockInApp/ZoidLockInApp.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInApp/ZoidLockInApp.swift) | Main menu bar extra and dashboard window manager. |
| **Command Dashboard** | [`Sources/ZoidLockInEconomy/CommandDashboardView.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/CommandDashboardView.swift) | 3-tab SUMI-E desktop dashboard (Overview, Ledger, Settings). |
| **Micro-Habits UI** | [`Sources/ZoidLockInEconomy/MicroHabitsView.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/MicroHabitsView.swift) | Popover checklist and editor view. |
| **Marketplace & Focus** | [`Sources/ZoidLockInEconomy/MarketplaceView.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/MarketplaceView.swift) | Focus launcher, amenity marketplace, and meeting tabs. |
| **Habit Coordination** | [`Sources/ZoidLockInCore/Economy/MicroHabitCoordinator.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInCore/Economy/MicroHabitCoordinator.swift) | Coordinator validating habit rules, credit minting, and mutations. |
| **Governance Engine** | [`Sources/ZoidLockInCore/Economy/GovernanceLockCoordinator.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInCore/Economy/GovernanceLockCoordinator.swift) | 48-hour monotonic cooldown coordinator and bypass logic. |
| **Economic Ledger** | [`Sources/ZoidLockInEconomy/SQLiteEconomicLedger.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/SQLiteEconomicLedger.swift) | Primary SQLite persistence layer for all transactions and tables. |
| **Live Tracker** | [`Sources/ZoidLockInEconomy/ZoidZeroLiveTracker.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/ZoidZeroLiveTracker.swift) | Zoid 0 ported frontmost app observer and anti-idle HID sampler. |
| **Focus Coordinator** | [`Sources/ZoidLockInEconomy/FocusSessionCoordinator.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/FocusSessionCoordinator.swift) | Connects live activity tracker events to the ExchangeEngine focus state machine. |
| **Filter Manager** | [`Sources/ZoidLockInFilterExtension/ContentFilterManager.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInFilterExtension/ContentFilterManager.swift) | System Extension authorization and NEFilterManager lifecycle coordinator. |
| **Encrypted State Store** | [`Sources/ZoidLockInCore/Economy/EncryptedStateStore.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInCore/Economy/EncryptedStateStore.swift) | AES-GCM encrypted state.json store with iCloud Drive and local fallback. |
| **Push Relay Client** | [`Sources/ZoidLockInCore/Economy/PushRelayClient.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInCore/Economy/PushRelayClient.swift) | Authenticated Cloudflare Worker push relay client for iOS APNs triggers. |
| **Proof Renderers** | [`Sources/ZoidLockInEconomy/DesktopDashboardProofRenderer.swift`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Sources/ZoidLockInEconomy/DesktopDashboardProofRenderer.swift) | Headless offscreen PNG proof generation for visual verification. |
| **Test Suites** | [`Tests/ZoidLockInTests/`](file:///Users/ziadnasreldin/Work/GitHub/Zoid%20Lock%20In/Tests/ZoidLockInTests) | 33 test suites (271 tests, 100% passing) verifying security, anti-cheating, and domain logic. |

---

## 7. Recommended Next Steps for the Incoming Agent

1. **System Extension Real-World Network Filtering:**
   - Verify System Extension installation and Content Filter approval flow on macOS 14/15 under user System Settings -> Network -> Filters.
2. **Cloudflare Push Relay Credentials:**
   - When deploying mobile shield synchronization to physical devices, configure the Cloudflare Worker URL and HMAC secret in macOS Keychain or environment variable `ZOID_LOCK_IN_PUSH_RELAY_URL`.
3. **Gemini Live Multimodal Audit Token:**
   - Supply a valid Google Gemini API key via the Keychain provider (`com.mavoid.zoidlockin.gemini-api-key`) to test live online multimodal meeting audits.
4. **Git Housekeeping:**
   - Review and stage current modifications (`git status`) and create clean milestone commits.
