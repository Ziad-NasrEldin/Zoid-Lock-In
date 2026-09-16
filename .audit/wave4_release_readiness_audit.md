# Wave 4 — Release Readiness & Usability Audit

**Audit date:** 2026-09-16T11:52:19Z  
**Repository revision (HEAD):** `5339d481635ae3945da2f3fe4297e3b1e809e7f1` (`main`)  
**HEAD subject:** `feat(e2e): complete multi-wave audit, pre-seed default habits, wire emergency valve and sentinel controls`  
**Working tree at audit time:** dirty — uncommitted edits in `PasswordHasher.swift`, `SecurityGatekeeper.swift`, `CommandDashboardView.swift` (complexity / 10-min session / enroll placeholder)  
**Scope:** User-facing interaction integrity across Focus Popover, Habits Checklist, Marketplace Catalog (active countdowns), Offline Meeting evidence submission, Command Dashboard (overview / ledger / settings), and privileged Sentinel Daemon controls.  
**Method:** Source-level control inventory + state-transition walk + live `swift build` / packaging inspection. Interactive GUI recording was not executed (menu-bar companion + privileged daemon require signed host + System Settings approval). Automated `swift test` could not execute in this environment (see §10).  
**Prior waves consulted:** `.audit/wave1_ui_surfaces_audit.md`, `wave1_enforcement_audit.md`, `wave3_e2e_*.md`, `wave4_economy_remediation_audit.md`.

**Legend:** **PASS** = control wired and state path is coherent · **PARTIAL** = reachable with material UX / product deviation · **FAIL** = broken, crash-risk, or product-required path incomplete · **BLOCKED** = cannot verify live in this environment.

---

## 1. Executive Verdict

| Surface | Buttons / tabs / timers | State transitions | Crash / error hygiene | Release readiness |
| :--- | :--- | :--- | :--- | :--- |
| **Focus Popover** | **PASS** | **PASS** | **PARTIAL** (silent catch) | **Ready for companion use** |
| **Habits Checklist** | **PASS** (complete + add) | **PASS** | **PARTIAL** | **Ready** with CRUD gaps |
| **Marketplace + countdowns** | **PASS** | **PASS** | **PASS** (errors surface) | **Ready** for spend path |
| **Offline Meeting** | **PASS** | **PASS** | **PASS** (errors surface) | **Ready** if Gemini key present |
| **Command Dashboard** | **PASS** | **PASS** | **PARTIAL** | **Ready** for audit UI |
| **Emergency Safety Valve** | **PARTIAL** | **PARTIAL** | **FAIL** (silent XPC + wrong refresh flag) | **Not product-complete** |
| **Sentinel Daemon controls** | **PARTIAL** | **FAIL** (packaging) | **PARTIAL** | **Not shippable as packaged** |

**Overall Wave-4 release readiness: CONDITIONAL — NOT PRODUCTION HARD-LOCKDOWN READY.**

The menu-bar companion surfaces (Focus / Market / Meet / Habit) and Command Dashboard tabs are **structurally complete**: every primary button is wired through `MenuBarSession`, 1-second ticks drive timers/countdowns, and purchase / habit / meeting failures that reach coordinators generally appear as footer banners. HEAD **builds** (`swift build --product ZoidLockInApp` succeeded).  

Ship blockers for a real lockdown release:

1. **Packaged `.app` omits LaunchDaemon helper + plist** → Sentinel **REGISTER** cannot enable privileged enforcement.  
2. **Emergency valve UI is one-click + alert**, not the PRODUCT §7 **5-second hold**; XPC failures are swallowed.  
3. **Working-tree WIP currently breaks compilation** (`keychain.set` vs `setData`) — must not merge as-is.  
4. **Automated regression suite is BLOCKED** in this environment (`Testing` module / Xcode license).  
5. Adjacent product gaps from Waves 1–3 remain open (Slack amenity, phone≠Safari Focus, streak §5.2 wording, habit edit/delete UI).

---

## 2. Environment & Evidence Baseline

| Check | Result |
| :--- | :--- |
| Host | macOS 27.0 (Build 26A428), arm64 |
| Swift (CLT) | Apple Swift 6.3.3 (`swift-driver` 1.148.6) |
| `swift build --product ZoidLockInApp` @ HEAD (WIP stashed) | **PASS** — link + apply succeeded |
| `swift build` with dirty WIP | **FAIL** — `SecurityGatekeeper.swift:451` `keychain.set` — no such member on `KeychainDataStoring` |
| `swift test` (CLT) | **FAIL** — `no such module 'Testing'` |
| `DEVELOPER_DIR=/Applications/Xcode.app/... swift test` | **BLOCKED** — Xcode license not agreed |
| Packaged app (`scripts/package_app.sh` output) | `build/Zoid Lock In.app` contains only `MacOS/ZoidLockInApp` + `Resources/AppIcon.icns` — **no** `Contents/Library/LaunchDaemons/`, **no** `ZoidLockInDaemon` |
| Live GUI click-through | **Not executed** — report is design + build evidence |

---

## 3. Surface Topology (what the user can reach)

```
MenuBarExtra (.window)
├─ surfaceSwitcher tabs: FOCUS | MARKET | MEET | HABIT
├─ OPEN COMMAND DASHBOARD  →  Window("command-dashboard")
└─ active pane:
     FocusPopoverView | MarketplacePopoverView
     | OfflineMeetingPopoverView | MicroHabitsPopoverView

CommandDashboardView (1200×800)
├─ 概 OVERVIEW | 帳 LEDGER | 鍵 SETTINGS
└─ Settings side rail:
     48h Governance · Emergency Valve · Sentinel Daemon
```

**App wiring:** `Sources/ZoidLockInApp/ZoidLockInApp.swift` (`MenuBarSession` + 1 Hz `DispatchSourceTimer` on main queue).  
**UI modules:** `Sources/ZoidLockInEconomy/{FocusPopoverView,MarketplaceView,OfflineMeetingView,MicroHabitsView,CommandDashboardView}.swift`.

---

## 4. Control Inventory — Every Button, Tab, Timer

### 4.1 Menu-bar chrome

| Control | Type | Handler | Expected effect | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| `集 FOCUS` | Tab | `surface = .focus` | Swap pane | **PASS** |
| `市 MARKET` | Tab | `surface = .market` | Swap pane | **PASS** |
| `会 MEET` | Tab | `surface = .meeting` | Swap pane | **PASS** |
| `習 HABIT` | Tab | `surface = .habits` | Swap pane | **PASS** |
| `OPEN COMMAND DASHBOARD` | Button | `openWindow(id:)` + activate | Opens 1200×800 window | **PASS** |
| Menu-bar label ticker | Live label | `session.snapshot` @ 1 Hz | Balance / focus caption | **PASS** |

### 4.2 Focus Popover

| Control / display | Type | Handler / source | State notes | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| Status banner | Display | `focusState` | idle / active / grace / completed / abandoned | **PASS** |
| Elapsed timer | Timer | `formattedElapsed` via 1 Hz tick | Updates while active/grace | **PASS** |
| Next mint countdown | Timer | `focusRemainingToNextMintSeconds` | Hidden as `—` when idle | **PASS** |
| `PUNCH IN FOCUS BLOCK` | Button | `toggleFocus` → `startFocus` | Disabled path: none (always tappable when idle) | **PASS** |
| `COMPLETE FOCUS SESSION` | Button | `toggleFocus` → `completeFocus` | Shown for active **and** pausedGrace | **PASS** |
| Day / curfew / Friday footer | Display | ticker flags | Cosmetic | **PASS** |

**State machine (digital focus):**

```
nil ──startFocus──► active ──idle 30–300s──► pausedGrace
                      │                         │
                      │◄──────activity──────────┘
                      │
                      ├──idle ≥300s──► abandoned
                      └──completeFocus──► completed (+ mint / momentum)
```

Offline meeting punch-in mutually excludes digital focus (`ExchangeEngineError.offlineMeetingActive`) — error is **swallowed** in `toggleFocus` (`_ = error`), so the button may appear to do nothing. **PARTIAL** UX.

### 4.3 Habits Checklist

| Control | Type | Handler | Disable / lock rules | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| Governance lock banner | Display | `governance.bannerCaption` | Live remaining countdown | **PASS** |
| Habit checkbox | Button | `completeHabit(id)` | Disabled when `!canComplete` (freq / 1.5c cap / disabled) | **PASS** |
| Reward chips `0.25` / `0.5` | Button | draft state | Locked when editor locked | **PASS** |
| Frequency `1/DAY` / `2/DAY` | Button | draft state | Locked when editor locked | **PASS** |
| `ADD` | Button | `createHabit` | Disabled if locked or empty title | **PASS** |
| Edit / delete / disable habit | — | Domain has `updateHabit` / `setEnabled` | **No UI** | **PARTIAL / GAP** |
| Default catalog seed | Boot | `MicroHabit.defaultCatalog` if empty | Teeth / bed / water / stretch | **PASS** (HEAD) |

**State transitions:** complete → mint `EARNED_HABIT` → wallet + feedback chip; daily cap → `1.5c LOCKED`; create → 48h governance mutation (or bypass in DEBUG). Errors → `lastError` footer. **PASS**.

### 4.4 Marketplace Catalog + active countdowns

| Control | Type | Handler | Disable rules | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| Shield banner | Display | `mobileShieldCaption` | Truthful NOT CONFIGURED / LOCAL / PASS | **PASS** |
| Catalog `BUY` | Button | `purchase(kind)` | Disabled if `purchaseInFlight` **or** curfew-blocked | **PASS** |
| Catalog `LOCK` | Button label | curfew | Same disable; seal muted | **PASS** |
| ACTIVE PASSES section | Timer list | daemon remaining + local rest timer | 1 Hz via assemble | **PASS** |
| Per-row remaining | Timer | `formattedRemaining` | `m:ss` / `h:mm:ss` | **PASS** |
| Purchase error banner | Display | `purchaseError` | Insufficient credits, curfew, XPC | **PASS** |
| Insufficient balance pre-disable | — | Engine rejects only | Button stays enabled until fail | **PARTIAL** (safe, noisy) |

**Purchase path:** `MenuBarSession.purchase` → `MarketplaceCoordinator.purchase` → ledger debit → HMAC voucher → XPC redeem → refund on redeem failure → shield publish. In-flight guard is **double** (session + coordinator). Countdown for food/phone/streaming/gaming comes from daemon `activePasses.remainingSeconds`; `.rest` uses local monotonic timer. **PASS**.

### 4.5 Offline Meeting evidence submission

| Control | Type | Handler | Disable rules | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| Elapsed timer | Timer | monotonic / uptime | Live while recording | **PASS** |
| Punch IN / OUT | Button | `punchToggle` | Disabled when neither `canPunchIn` nor `canPunchOut` | **PASS** |
| Artifact `DROP` / `REPLACE` | Button + fileImporter | `importArtifact` | Disabled after submit | **PASS** |
| Drag-drop destination | Drop | same | Highlights target row | **PASS** |
| `SUBMIT BUNDLE` | Button | `submitMeeting` → Flash audit | Disabled until triple-valid + punched out | **PASS** |
| `ABANDON MEETING` | Button + confirm | `abandonMeeting` | Disabled when `!canAbandon` | **PASS** |
| `RETRY AUDIT` | Button | `retryMeetingAudit` | When `canRetryAudit` | **PASS** |
| `APPEAL TO GEMINI PRO` | Button → sheet | `appealMeeting` | After 3 Flash rejections | **PASS** |
| Appeal `SUBMIT` / `DISMISS` | Sheet | statement sanitize + Pro | Empty statement disabled | **PASS** |
| Error / retention captions | Display | `lastError`, 30-day purge | | **PASS** |

**Phase machine:** `idle → recording → awaitingEvidence → submitted` (+ audit substates). **PASS** for UI/state integrity. Live Gemini success is environment-dependent (API key) — marked **BLOCKED** for live proof only.

### 4.6 Command Dashboard — Overview / Ledger / Settings

| Control | Type | Handler | Verdict |
| :--- | :--- | :--- | :--- |
| Tab `OVERVIEW` | Tab | local `@State tab` | **PASS** |
| Tab `LEDGER` | Tab | local `@State tab` | **PASS** |
| Tab `SETTINGS` | Tab | local `@State tab` | **PASS** |
| Overview metrics / vault / streak / strikes | Display | `CommandDashboardSnapshot` @ ≤1 Hz (ledger cache 30s) | **PASS** |
| Ledger filter chips (ALL/MINT/…) | Button | reset page=1 | **PASS** |
| Search field | Text | page=1 on change | **PASS** |
| Page size 10/25/50 | Button | page=1 | **PASS** |
| `PREV` / `NEXT` | Button | clamped via query | **PASS** |
| `JUMP` + page field | Button | `Int(jumpPage)` — query clamps; **field text may desync** | **PARTIAL** |
| `UNLOCK SETTINGS` | Button | `unlockSettings` | Disabled &lt;12 chars or TOTP &lt;6 | **PASS** |
| `ENROLL 2FA` | Button | `enrollSettings` | Secret generated on appear | **PASS** (HEAD) / **PARTIAL** (WIP complexity) |
| `LOCK SETTINGS` | Button | `lockSettings` | Clears fields | **PASS** |
| Governance remaining | Display | 48h lock caption | **PASS** |
| Amenity price editor | — | Domain only | **GAP** |
| Habit admin CRUD | — | Menu-bar only | **GAP** in dashboard |

### 4.7 Emergency Safety Valve (Settings)

| Control | Type | Handler | Product expectation | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| `ENGAGE EMERGENCY VALVE (30m)` | Button | alert → `triggerEmergencyValve` → XPC | Always accessible, **5s press-and-hold** then confirm | **PARTIAL / FAIL vs PRODUCT** |
| Confirm alert | Alert | destructive engage | Copy matches `EmergencySafetyValveEngine.confirmationPromptText` | **PASS** (copy) |
| Active caption | Display | `emergencyValveActive` | 30m override engaged | **PARTIAL** (see §6.2) |
| `EmergencySafetyValveCoordinator` / hold engine | Domain | **Not bound to UI** | Required hold state machine unused | **FAIL (wiring)** |

### 4.8 Privileged Sentinel Daemon controls

| Control | Type | Handler | Verdict |
| :--- | :--- | :--- | :--- |
| Status caption | Computed | `SMAppService.daemon(plistName:).status` | **PARTIAL** — no dedicated `@State` refresh after register |
| `REGISTER SENTINEL DAEMON` | Button | `try? SMAppService…register()` | **FAIL in packaged app** — helper bundle missing; errors discarded |
| Enabled idle text | Display | when `.enabled` | **PASS** (design) |

---

## 5. Timer & Live-Update Integrity

| Timer / ticker | Interval | Source of truth | UI consumer | Verdict |
| :--- | ---: | :--- | :--- | :--- |
| Economy / UI tick | **1.0 s** | `MenuBarSession` main-queue timer + `TickCoalescer` | All companion panes + dashboard | **PASS** |
| Focus elapsed / next mint | 1 s | `ExchangeEngine.snapshot` | Focus popover | **PASS** |
| Meeting elapsed | 1 s | `OfflineSessionCoordinator.snapshot` | Meet popover | **PASS** |
| Amenity countdown | 1 s | Daemon `remainingSeconds` (+ local rest) | Market ACTIVE PASSES + row caption | **PASS** |
| Governance remaining | 1 s | `GovernanceLockCoordinator.snapshot` | Habit banner + Settings card | **PASS** |
| Calibration remaining | 1 s | `CalibrationCoordinator` | Dashboard banner | **PASS** |
| Shield publish throttle | 60 s / on change | `MobileShieldCoordinator` | Market banner | **PASS** |
| Artifact purge | 60 s | `MeetingArtifactPurgeScheduler` | Background | **PASS** |
| Ledger cache reload | 30 s / balance change | SQLite | Dashboard ledger | **PASS** (stale ≤30s acceptable) |
| Admin session timeout | **600 s** | WIP `SecurityGatekeeper.isUnlocked` | Settings unlock | **WIP only** — not in HEAD; see §9 |

No unbounded recursion or re-entrant tick without coalescing was found. `try! SQLiteEconomicLedger()` fallback in `init` is a theoretical crash if even the in-memory ledger fails — treated as **Low** residual risk.

---

## 6. Critical Defects (release blockers / high severity)

### 6.1 RR-01 — Packaged app cannot register Sentinel (CRITICAL)

**Evidence:** `scripts/package_app.sh` copies only `ZoidLockInApp` into `Contents/MacOS/` and the app icon into `Resources/`. Inspected bundle:

- Present: `Contents/MacOS/ZoidLockInApp`, `Contents/Resources/AppIcon.icns`, `Info.plist`  
- Missing: `Contents/Library/LaunchDaemons/com.mavoid.zoidlockin.helper.plist`  
- Missing: `Contents/MacOS/ZoidLockInDaemon` (plist `BundleProgram`)

`SMAppService.daemon(plistName:)` requires the LaunchDaemon plist inside the app bundle. Without it, status resolves to **notFound** / registration fails. UI uses `try?` and shows no error toast.

**Impact:** Privileged process sentinel + Mach XPC enforcement **do not activate** from the shipped companion path → marketplace voucher redeem / emergency / hard lockdown degrade or fail silently.

### 6.2 RR-02 — Emergency valve UX ≠ PRODUCT §7 + stale active flag (HIGH)

1. PRODUCT requires **5 continuous seconds hold** then confirmation. UI is a normal button + SwiftUI `.alert`. `EmergencySafetyValveEngine` / `EmergencySafetyValveCoordinator` exist but are **unused** by `CommandDashboardView`.  
2. After engage, `MenuBarSession.refreshDashboard()` sets:

```swift
emergencyValveActive: marketplace.mobileShield.passActive
```

`passActive` means **food/phone mobile pass**, not `.emergency`. Until the next tick that observes daemon status containing `.emergency`, the Settings card can show the engage button again or mislabel state. Tick path correctly uses `status?.activePasses.contains { $0.kind == .emergency }`.

3. `triggerEmergencyValve` catches and discards XPC errors — when daemon is unregistered, user sees **no failure**.

### 6.3 RR-03 — Working-tree compile break (CRITICAL for merge)

Uncommitted `SecurityGatekeeper.consumeTOTPWindow` calls `keychain.set(data:service:account:)` but `KeychainDataStoring` only exposes `setData(_:service:account:)`. Dirty-tree `swift build` fails. Adjacent WIP adds complexity UI + 10-minute session timeout (desirable) but is **unsafe to ship** until fixed and tests re-run.

### 6.4 RR-04 — Silent failure pattern across session actions (HIGH usability)

`MenuBarSession` swallows errors for focus toggle, meeting punch/submit/audit/appeal/abandon/import, habit complete/create, enroll/unlock, emergency, and policy publish (`_ = error`). Surfaces that **do** show errors (marketplace `purchaseError`, habits/meeting `lastError`, settings `unlockError`) are fine; focus and emergency are the worst offenders for “button does nothing.”

### 6.5 RR-05 — Automated verification BLOCKED (HIGH process)

Cannot execute the Slice 1–9 suite here. Release gate should require green `swift test` under a licensed Xcode toolchain before tagging.

---

## 7. Medium / Low Usability Findings

| ID | Severity | Finding |
| :--- | :--- | :--- |
| RR-06 | Medium | Habit UI supports **create + complete** only; no edit/delete/disable despite coordinator APIs. |
| RR-07 | Medium | Dashboard Settings has **no amenity price editor** despite `setAmenityPrice` / SQLite overrides. |
| RR-08 | Medium | `BUY` not disabled for insufficient credits — fails post-tap with banner (safe, slightly confusing). |
| RR-09 | Medium | Sentinel status is computed without local `@State`; successful register may not repaint until an unrelated `@Published` dashboard change. |
| RR-10 | Medium | HEAD enroll enforces **length only**; WIP adds complexity **UI** but still does not call `validateComplexity` inside `SecurityGatekeeper.enroll`. |
| RR-11 | Low | Ledger `JUMP` text field does not sync when PREV/NEXT change `page` (display clamp hides crash; caption can lie until JUMP). |
| RR-12 | Low | Fixed pane heights (Focus 700, Habit 780, Meet 860) + switcher + dashboard strip may clip on short displays / scaled UI. |
| RR-13 | Low | Focus has no explicit **Abandon** control; abandonment is idle-driven only (by design) but may surprise users mid-grace. |
| RR-14 | Info | Wave-3 product gaps remain: no Slack amenity; phone pass ≠ general Safari / macOS Focus Mode. |
| RR-15 | Info | Wave-4 economy audit: victory streak still ignores “zero deficit + baseline paid” PRODUCT §5.2 wording. |

---

## 8. Per-Surface State Transition Matrices

### 8.1 Focus

| From | Action | To | Credits | UI |
| :--- | :--- | :--- | :--- | :--- |
| Idle | Punch In | Active | — | Banner ACTIVE; timer runs |
| Active | Brief idle | Grace | freeze elapsed | Banner PAUSED |
| Grace | Activity | Active | — | Resume |
| Active/Grace | Complete | Completed | mint + optional 2× | Button → Punch In |
| Active | Idle ≥5m | Abandoned | no mint | Banner abandoned |
| Idle | Punch while meeting | Idle | — | **Silent no-op** |

### 8.2 Marketplace

| From | Action | To | Notes |
| :--- | :--- | :--- | :--- |
| Open day, funds OK | BUY timed amenity | Active pass + countdown | XPC redeem required |
| Open day, low funds | BUY | Unchanged + error banner | |
| Curfew | BUY entertainment | LOCK disabled | Engine also rejects |
| Active pass | Tick | Countdown −1s | Expiry removes ACTIVE row |
| Rest purchase | Local timer | ACTIVE without daemon | |

### 8.3 Habits

| From | Action | To |
| :--- | :--- | :--- |
| Unchecked, under cap | Check | Completion + feedback + balance |
| At frequency | Check | Disabled |
| Cap reached | Check | Disabled; CAP badge LOCKED |
| Editor unlocked | ADD | New row (48h mutation) |
| Editor locked | ADD / chips | Disabled + LOCKED badge |

### 8.4 Offline Meeting

| From | Action | To |
| :--- | :--- | :--- |
| Idle | Punch In | Recording |
| Recording | Punch Out | Awaiting evidence |
| Awaiting | DROP×3 valid | canSubmit |
| canSubmit | SUBMIT | Submitted + Flash audit |
| Rejected &lt;3 | RETRY | Re-audit |
| Rejected =3 | APPEAL sheet | Pro arbitration |
| Any non-idle | ABANDON confirm | Idle discard |

### 8.5 Dashboard tabs

| Tab | Primary state | Mutations |
| :--- | :--- | :--- |
| Overview | Read-only metrics | None |
| Ledger | Filter/search/page local | Does not mutate ledger |
| Settings | Enroll / unlock / lock / emergency / sentinel | Security + XPC + SMAppService |

---

## 9. Working-Tree WIP vs HEAD (do not confuse)

| Item | HEAD `5339d48` | Dirty tree |
| :--- | :--- | :--- |
| Emergency button + alert | Present | Present |
| Sentinel register button | Present | Present |
| Default habit seed | Present | Present |
| Password complexity helper | Absent | Present (`validateComplexity`) |
| Complexity gate on ENROLL button | Length only | UI complexity disable |
| Complexity in `enroll()` backend | Length only | Still length only |
| 10-minute admin session timeout | Absent | Present (`sessionTimeoutSeconds = 600`) |
| Build | **PASS** | **FAIL** (`keychain.set`) |

**Recommendation:** Fix `set` → `setData` (or reuse `persistReplayWindow`), enforce complexity in `enroll`/`unlock`, add unit tests, then merge. Until then treat dirty tree as **non-releasable**.

---

## 10. Verification Execution Log

| Step | Command / inspection | Outcome |
| :--- | :--- | :--- |
| 1 | Inventory SwiftUI views + `MenuBarSession` handlers | Complete control map §4 |
| 2 | Walk coordinators for timers / disables / errors | §5–§8 |
| 3 | `swift build --product ZoidLockInApp` @ HEAD | **PASS** |
| 4 | `swift build` with WIP | **FAIL** compile |
| 5 | `swift test` (CLT) | **FAIL** `import Testing` |
| 6 | Xcode toolchain test | **BLOCKED** license |
| 7 | Inspect `build/Zoid Lock In.app` | Daemon packaging **missing** |
| 8 | Live click-through / screen recording | **Not run** |

---

## 11. Release Gate Checklist

| Gate | Status |
| :--- | :--- |
| Companion tabs switch without crash (source) | **PASS** |
| Focus start/complete/timer coherent (source) | **PASS** |
| Habit complete + add + lock coherent (source) | **PASS** |
| Marketplace BUY + countdown coherent (source) | **PASS** |
| Meeting punch → artifacts → submit → appeal coherent (source) | **PASS** |
| Dashboard overview/ledger/settings coherent (source) | **PASS** |
| Emergency valve product-faithful (5s hold + feedback) | **FAIL** |
| Sentinel register works from packaged app | **FAIL** |
| Clean build on release commit | **PASS** @ HEAD / **FAIL** on dirty WIP |
| Green automated test suite | **BLOCKED** |
| No silent critical failures (daemon down, emergency) | **FAIL** |
| PRODUCT §5.2 streak / Slack / phone Focus gaps accepted | **Open** (product decision) |

**Ship decision:**  
- **Internal dogfood of economy UI:** YES (menu-bar companion + dashboard read paths).  
- **Production hard lockdown / App Store-style release:** **NO** until RR-01, RR-02, RR-03, RR-05 are closed and a live signed-bundle soak confirms Sentinel + NE + emergency.

---

## 12. Recommended Fix Order (for a follow-up remediation wave)

1. Extend `package_app.sh` to embed `ZoidLockInDaemon` + `Contents/Library/LaunchDaemons/com.mavoid.zoidlockin.helper.plist`; surface SMAppService errors in UI; refresh status `@State` after register.  
2. Bind Settings emergency control to `EmergencySafetyValveCoordinator` (5s hold → confirm → XPC); fix `refreshDashboard` emergency flag; surface XPC errors.  
3. Repair WIP `keychain.setData`; enforce `PasswordHasher.validateComplexity` in `SecurityGatekeeper.enroll`; keep 600s timeout.  
4. Propagate user-visible errors for focus / emergency / sentinel (reuse seal banners).  
5. Unlock licensed Xcode / CI and run full `swift test` + a signed GUI soak checklist matching §4.

---

## 13. Primary File Index

| Area | Paths |
| :--- | :--- |
| App session / ticks | `Sources/ZoidLockInApp/ZoidLockInApp.swift` |
| Focus UI | `Sources/ZoidLockInEconomy/FocusPopoverView.swift` |
| Market UI | `Sources/ZoidLockInEconomy/MarketplaceView.swift` |
| Meeting UI | `Sources/ZoidLockInEconomy/OfflineMeetingView.swift` |
| Habits UI | `Sources/ZoidLockInEconomy/MicroHabitsView.swift` |
| Dashboard UI | `Sources/ZoidLockInEconomy/CommandDashboardView.swift` |
| Market / focus engine | `MarketplaceCoordinator.swift`, `ExchangeEngine.swift`, `FocusMinting.swift` |
| Habits / meetings | `MicroHabitCoordinator.swift`, `OfflineSessionCoordinator.swift`, `OfflineMeetingAuditCoordinator.swift` |
| Emergency | `EmergencySafetyValve.swift`, XPC `engageEmergencySafetyValve` |
| Sentinel | `DaemonServiceRegistrar.swift`, `DaemonConfiguration.swift`, `Resources/com.mavoid.zoidlockin.helper.plist`, `scripts/package_app.sh` |
| Security WIP | `PasswordHasher.swift`, `SecurityGatekeeper.swift` |

---

*End of Wave 4 Release Readiness & Usability Audit.*
