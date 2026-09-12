# PRD: Zoid Lock In — Autonomous Personal Economy & Discipline Engine

## Problem Statement

As a high-performing creator and software founder, maintaining unwavering daily focus and eliminating chronic procrastination is hindered by the frictionless availability of digital entertainment, social media, online food delivery, and daytime comforts. When leisure and conveniences are disconnected from real output, willpower alone predictably deteriorates throughout the week. Furthermore, existing time-tracking and blocker tools suffer from fatal flaws:
- They are easy to kill, pause, or uninstall in moments of low discipline.
- They allow hoarding yesterday's progress to justify today's slacking.
- They lack immediate, tangible stakes tied to real living amenities (food delivery, gaming, evening social outings, and even sleeping in bed).
- Off-screen professional obligations (in-person client meetings, physical strategy sessions) go uncredited because trackers assume all productive labor occurs behind a computer monitor.

The user needs an uncompromising, local-first personal economy system that introduces artificial scarcity, enforces hard operating-system barriers, requires multimodal proof for off-screen labor, resets daily, and locks configuration changes behind high-friction multi-factor security.

---

## Solution

**Zoid Lock In** is a standalone, local-first macOS application and menu bar companion that transforms daily existence into a closed-loop internal market economy:
1. **Daily Reset & Artificial Scarcity:** Every day starts at 0.0 credits at 00:00:00. Unspent credits vanish at 23:59:59 into a permanent Lifetime Surplus Vault. Baseline living amenities and recreation require spending earned credits.
2. **Deep Work Minting Engine:** Automatically measures verified focus time using proven local workspace observation primitives adapted from Zoid 0 (1 hour = 1.0 credit).
3. **Morning Momentum Multiplier:** Completing the day's first uninterrupted 90-minute focus block before 12:00 PM Noon applies a 2.0× multiplier, instantly generating 3.0 credits to fund morning breaks or the bed comfort.
4. **Triple-Gate Offline Meeting Audit:** Real-time punch-in/out timers plus mandatory agenda notes, physical receipts, and contextual photos audited multimodally by the Gemini API, with a Gemini Pro arbitration pass unlocked after 3 consecutive denials.
5. **Hard Digital Lockdown & Cross-Device Shield:** A root-level Privileged Helper Daemon kills unauthorized processes (Steam, Discord, game launchers) and blocks web domains (YouTube, Reddit, social networks, and food delivery portals like Talabat and Uber Eats). State syncs with iPhone via iCloud and push notifications to trigger iOS Focus Filters.
6. **Anti-Cheating Governance:** Admin access requires a 12+ character password, Google Authenticator TOTP 2FA, automated warning email dispatch, and a 48-hour cooldown lockout on any price or rule edits (with a developer override for pre-production).
7. **Curfew & Deficit Disciplines:** 22:00 curfew on entertainment/food purchases; finishing below 3.0 credits levies a -1.0 credit focus debt the following morning; a 5-second press-and-hold Emergency Safety Valve provides 30-minute relief at the cost of an incident alert and a -2.0 credit debt tomorrow.
8. **Permanent Friday Rest Mode:** A hardcoded, immutable weekly rest day where basic comforts cost 0 credits and no deficits are evaluated.

---

## User Stories

1. As a user, I want the system to reset my credit balance to zero at midnight every night, so that I cannot rest on yesterday's accomplishments and must earn today's comforts through fresh daily focus.
2. As a user, I want unspent credits at 23:59:59 to be transferred to a permanent Lifetime Surplus Vault on my dashboard, so that my past discipline is visibly celebrated without funding current idleness.
3. As a user, I want verified focus sessions to automatically mint credits at a baseline rate of 1.0 credit per hour (and 0.5 credits per 30 minutes), so that my productive time is smoothly converted into purchasing power.
4. As a user, I want completing my first 90-minute focus block before 12:00 PM Noon to apply a 2.0× multiplier ($1.5 \times 2.0 = 3.0\text{ credits}$), so that I am strongly incentivized to wake up early and begin working immediately.
5. As a user, I want a 5-minute (300-second) grace window during focus sessions, so that brief system sleeps, app restarts, or urgent phone calls do not prematurely abort my 90-minute morning block.
6. As a user, I want any pause or interruption exceeding 5 minutes during the morning block to reset the continuous timer to zero, so that fragmented attention is not mistakenly rewarded with the momentum multiplier.
7. As a user, I want focus sessions initiated or completed after 12:00 PM Noon to earn at the standard 1.0× rate, so that sleeping in late loses access to the morning momentum bonus.
8. As a user, I want to punch in when an offline meeting starts and punch out when it ends, so that my professional work outside the office is captured accurately.
9. As a user, I want to attach meeting agenda notes, a transaction receipt/documentation, and a contextual photo to my offline meeting record, so that I provide complete proof of legitimate work.
10. As a user, I want my offline meeting proof bundle to be automatically audited by the Gemini multimodal API, so that credits are minted only after photographic and textual authenticity are verified.
11. As a user, I want raw offline meeting photos and receipt scans to be auto-purged from local storage after 30 days while retaining permanent cryptographic hashes, so that my local disk space remains clean and private.
12. As a user, I want the option to submit an official appeal after three consecutive Gemini AI rejections on an offline meeting, so that legitimate edge cases can be reconsidered without allowing instant bypasses.
13. As a user, I want offline meeting appeals to be evaluated by a secondary Gemini Pro deep-reasoning arbitration model, so that complex edge cases receive thorough scrutiny.
14. As a user, I want an offline meeting to be permanently sealed as rejected if the Gemini Pro arbitration pass rejects the appeal, so that the zero-cheating doctrine is preserved.
15. As a user, I want to configure custom micro-tasks (such as brushing teeth, making the bed, or drinking 2L of water) with fractional credit rewards, so that essential hygiene and foundational life habits are reinforced.
16. As a user, I want each micro-task to have an enforceable daily completion limit, so that I cannot spam repetitive micro-tasks to circumvent deep work requirements.
17. As a user, I want total daily micro-task earnings to be capped at 1.5 credits per day, so that the vast majority of my daily credits must come from focused work.
18. As a user, I want target desktop gaming applications (Steam, Discord, Battle.net, Riot Client, Epic Games) to be terminated or suspended by default, so that entertainment is inaccessible during work hours.
19. As a user, I want the background enforcement daemon to run as a root-level `LaunchDaemon` with `KeepAlive: true`, so that it cannot be terminated from Activity Monitor or Terminal.
20. As a user, I want the daemon to immediately trigger a fail-closed full system lock if it detects an ungraceful restart or forced kill attempt, so that tampering attempts are rendered completely futile.
21. As a user, I want entertainment web domains (YouTube, Reddit, Facebook, Instagram, Twitter/X, Twitch, Netflix) to be blocked by default at the system packet-filter level, so that I cannot open them in any browser.
22. As a user, I want food delivery portals (Talabat, Uber Eats, Elmenus) to be blocked on macOS and mobile by default, so that impulse junk food ordering is halted.
23. As a user, I want Zoid Lock In state changes to sync with an encrypted `state.json` on iCloud Drive and a push webhook relay, so that my iPhone stays in lockstep with my Mac Mini.
24. As a user, I want work focus sessions to trigger an iOS Focus Mode that silences notifications and hides entertainment and delivery apps on my phone, so that my phone cannot serve as an escape hatch.
25. As a user, I want to purchase a 30-minute Food Pass for 2.5 credits, so that food delivery websites and apps are temporarily unblocked across Mac and phone for long enough to place an order.
26. As a user, I want food delivery apps and domains to automatically re-lock once the 30-minute Food Pass window elapses, so that I do not linger on food apps after ordering.
27. As a user, I want to purchase a 60-minute Phone Pass for 1.5 credits, so that I can use personal social media guilt-free during dedicated relaxation windows.
28. As a user, I want to purchase a 60-minute YouTube / Streaming Pass for 1.5 credits, so that I can watch curated videos with full peace of mind.
29. As a user, I want to purchase a 30-minute Gaming Pass for 1.5 credits, so that desktop game launchers are temporarily authorized to run.
30. As a user, I want to purchase the Bed Amenity for 3.0 credits daily, so that I earn the right to sleep in a comfortable bed rather than sleeping on the floor or couch.
31. As a user, I want to purchase a Social Outing Pass for 5.0 credits, so that evening dinners or outings with friends are treated as premium rewards requiring substantial daytime focus.
32. As a user, I want to purchase 30-minute Rest Breaks for 0.5 credits, so that taking midday breaks away from screens is recognized as an active economic transaction.
33. As a user, I want all entertainment, gaming, social media, and food delivery purchases to be disabled at 22:00:00 every night, so that I am prevented from late-night credit dumping and sleep disruption.
34. As a user, I want finishing the day with all baseline amenities paid and zero deficit to increment my Daily Victory Streak, so that I build long-term psychological momentum.
35. As a user, I want finishing a non-rest day below the 3.0 credit baseline to record a permanent Deficit Strike on my dashboard, so that non-compliance is visibly logged.
36. As a user, I want an end-of-day deficit to levy a mandatory -1.0 credit focus debt onto the following morning, so that slacking today creates immediate friction tomorrow.
37. As a user, I want morning work to first calculate my 2.0× momentum multiplier before deducting any carried-over debt, so that my morning momentum is rewarded while the debt is fully settled.
38. As a user, I want an Emergency Safety Valve that activates after pressing and holding a button for 5 continuous seconds, so that genuine medical or critical emergencies can bypass locks without accidental misclicks.
39. As a user, I want activating the Emergency Safety Valve to grant immediate 30-minute unhindered access, dispatch an incident audit email, and charge a mandatory -2.0 credit debt tomorrow, so that emergencies are handled safely while deterring trivial use.
40. As a user, I want Friday to be hardcoded as an immutable Rest Day, so that baseline amenities cost 0 credits and no deficit penalties are evaluated.
41. As a user, I want Friday Rest Mode to be permanently locked against modification or rescheduling even within the 2FA Admin Dashboard, so that I cannot impulsively shift my rest day.
42. As a user, I want accessing the Admin Settings Dashboard to require a 12+ character complex password and Google Authenticator TOTP 2FA, so that I cannot casually alter economic parameters.
43. As a user, I want every admin dashboard login to immediately dispatch a psychological warning email via transactional email API, so that I am confronted with my commitment before changing any settings.
44. As a user, I want any configuration change in the admin dashboard to trigger a mandatory 48-hour read-only cooldown lockout, so that emotional or impulse rule changes are impossible.
45. As a user, I want a developer override flag during development and pre-production testing, so that the 48-hour lock does not impede rapid testing and tuning prior to release.
46. As a user, I want a lightweight Menu Bar companion with a live credit ticker and quick unlock popover, so that I can see my economic status and execute transactions without opening a large window.
47. As a user, I want a standalone macOS desktop command window designed in the SUMI-E Ink aesthetic, so that managing my economy feels calm, deliberate, and high-craft.
48. As a user, I want all transactions, balances, and history stored locally in an atomic SQLite database via GRDB, so that my behavioral data never leaves my device.
49. As a user, I want a 3-day calibration onboarding phase with soft warning banners before full hard enforcement activates on Day 4, so that I can verify my daily routines before hard locks engage.

---

## Implementation Decisions

### 1. Architectural Topology & Modularity
- **Process Model:** Zoid Lock In operates as a dual-tier architecture:
  - **Tier 1 (User UI Process):** Native Swift 6 / SwiftUI application hosting the `MenuBarExtra` companion item, the main SUMI-E Ink dashboard window, and the local SQLite state coordinator.
  - **Tier 2 (Privileged Helper Daemon & Network Extension):** A root-level daemon registered via modern macOS `SMAppService.daemon(plistName:)`, hosting Apple's **Network Extension Content Filter (`NEFilterDataProvider`)** to intercept socket flows by hostname/SNI, neutralizing VPN and Private Relay bypasses.
- **Fail-Closed Daemon Authority:** The helper daemon terminates unauthorized processes (`SIGKILL`), enforces socket-level drops, and communicates with the UI process via Mach-O XPC audited via `audit_token_t`. It runs with `KeepAlive: true` and defaults to locking target applications if communication is severed.

### 2. Time-Tracking & Workspace Observation Engine
- **Engine Adaptation from Zoid 0:** Incorporates the application-level activation observer and ScreenCaptureKit pipeline from Zoid 0. It monitors active frontmost applications and window focus, maintaining a continuous active-task clock.
- **Anti-Idle Human Input Detection:** Taps system event streams (`CGEvent.tapCreate` / IOHIDEventSystem) to require physical keyboard and mouse activity. 5 minutes of zero physical inputs immediately triggers the grace period countdown, preventing mouse-jiggler farming.
- **Monotonic Clock & NTP Anti-Tamper:** Combines `mach_absolute_time()` with an encrypted startup NTP baseline check to prevent clock-skewing in macOS System Settings.
- **Grace Window Logic:** Tracks an `interruptionStartTimestamp`. If an interruption resolves within 300 seconds, the session state transitions back to `activeFocus` without resetting the elapsed block timer. If interruption duration exceeds 300 seconds, the block resets to zero.

### 3. Economic State Machine & Ledger
- **Deterministic Event-Driven Engine:** All credit adjustments flow through an append-only transaction ledger (`WalletTransaction`).
- **Core Calculation Rules:**
  - Standard focus: +1.0 credit per 3600 seconds of verified focus; fractional increments evaluated every 1800 seconds (+0.5 credits).
  - Morning Momentum: If a session reaches 5400 seconds (90 minutes) continuous focus, was initiated on or after 00:00:00, and finishes before 12:00:00 local time, mints $1.5 \times 2.0 = 3.0\text{ credits}$.
  - Debt Reconciliation: If `walletBalance < 0.0`, earned credits apply to debt before yielding spendable balance.
  - Midnight Reconciliation: At 23:59:59, unspent positive balance is added to `lifetimeSurplusVault` and `walletBalance` is set to 0.0 (or -1.0 if daily earnings were under 3.0 credits on a non-rest day).
  - Friday Rest Rule: Day-of-week check enforces 0.0 cost on comfort items and bypasses deficit penalty checks on Friday.

### 4. Triple-Gate Offline Meeting & Gemini AI Pipeline
- **Punch-In / Punch-Out Coordinator:** Records local monotonic timestamps for offline sessions.
- **Evidence Bundle Packaging:** Requires 3 attached payloads: Markdown agenda note, JPEG/PNG receipt document, and JPEG/PNG contextual photo.
- **EXIF Verification & Prompt Sanitization:** Validates local image EXIF metadata (capture timestamps, camera signatures) before dispatch and strips prompt-injection patterns from agenda notes.
- **Gemini Multimodal Client:** Sends the bundled artifacts to Gemini API using a system prompt that cross-examines document dates, visual room clues, and duration reasonableness.
- **Appeal Pipeline:** Counts consecutive denials in SQLite (`denialCount`). When `denialCount == 3`, an "Appeal to Gemini Pro" action unlocks, routing the package and user statement through Gemini Pro for final binding arbitration.
- **Storage Lifecycle:** Original image binaries are removed from disk 30 days after creation; SHA-256 digests and audit logs remain permanently in SQLite.

### 5. Multi-Factor Admin Governance & Anti-Cheating
- **Password Engine:** Argon2id password hashing with random salt stored in macOS Keychain.
- **TOTP Engine:** Standard RFC 6238 TOTP algorithm verified against a shared base32 secret generated on initial onboarding.
- **Transactional Alert Dispatcher:** Dispatches HTTP POST requests to the Resend API with an email alerting the user whenever an authenticated admin session is opened or emergency override is engaged.
- **48-Hour Cooldown Controller:** Records `lastConfigChangeTimestamp` in SQLite. All write interfaces in settings check `(now - lastConfigChangeTimestamp) >= 172800` seconds. In debug builds, a pre-production bypass flag overrides this check.

### 6. Mobile Synchronization & Network Shield
- **iCloud Drive Channel:** Writes an encrypted JSON payload (`state.json`) with Last-Write-Wins timestamps into the app's ubiquitous container.
- **Webhook Relay:** Dispatches state changes to a Cloudflare Worker that forwards push notifications to iOS Shortcuts.
- **iOS Shortcut Focus Filter Window:** Triggers an iOS automation that adjusts iOS Focus Mode filters for 30 minutes when a Food Pass or Phone Pass is active.

---

## Testing Decisions

### What Makes a Good Test
Tests for Zoid Lock In must strictly verify **observable external behavior and state outputs**, never private implementation mechanics. Tests should feed concrete domain inputs (time events, transactions, file attachments, clock transitions) into the public interface and assert that the resulting wallet balances, lock states, debt carryovers, and audit records match expectations.

### Modules Under Test
1. **`ExchangeEngineTests` (The Primary Seam):**
   - Verification of 1.0/hr base earning and 0.5/30min milestones.
   - Verification of the 90-minute morning momentum 2.0× multiplier before 12:00 PM vs 1.0× after 12:00 PM.
   - Verification of the 5-minute grace tolerance vs 301-second reset behavior.
   - Verification of debt priority (earnings multiply, then debts deduct).
   - Verification of 22:00 curfew rejection on entertainment purchases.
   - Verification of midnight expiration, surplus vault accrual, and victory streak incrementation.
   - Verification of Friday rest day zero-cost comfort and exemption from deficit penalties.
   - Verification of 48-hour configuration cooldown lockout and testing override toggle.
2. **`GeminiAuditParserTests`:**
   - Evaluates structured JSON responses from Gemini API mock responses (approvals, rejections, appeal gates after 3 failures).
3. **`TOTPValidatorTests`:**
   - Evaluates RFC 6238 time-step token verification against known test vectors.
4. **`DaemonPolicyGeneratorTests`:**
   - Verifies that correct `pfctl` rule strings and process target lists are generated for locked vs unlocked states.

### Prior Art in Codebase
Derived from the local-first unit testing suites in [Zoid 0](file:///Users/ziadnasreldin/Work/GitHub/Zoid%200) (`ScreenwatchTests`, `MeetingReceiptTests`), utilizing deterministic in-memory SQLite instances and mock clock providers.

---

## Out of Scope

1. **Windows or Linux Support:** Exclusively targets macOS 14+ and paired iOS devices.
2. **Cloud Account Management / Social Features:** Zero centralized accounts, leaderboards, or multiplayer economies. Local-first only.
3. **Automated Food Purchasing:** The system does not place orders via Uber Eats / Talabat APIs; it unblocks access and issues passes.
4. **Permanent Financial Penalties:** The system enforces disciplinary work debts and digital lockdowns, not real monetary fines.
5. **Screen Recording or Surveillance of Private Content:** Uses window-level process metadata and OCR primitives without saving full screen video recordings.

---

## Further Notes

- **Single Primary Seam:** All economic rules, timers, lock transitions, and governance checks converge at the **`ExchangeEngine`** interface. This enables 100% test coverage of the entire product specification via fast, deterministic unit tests without requiring root daemon permissions during continuous integration.
- **SUMI-E Ink Design Palette:** UI development must strictly adhere to the SUMI-E Ink design tokens established across the Zoid ecosystem (charcoal ink, rice-paper canvas, vermilion seal accents, serif typography).
