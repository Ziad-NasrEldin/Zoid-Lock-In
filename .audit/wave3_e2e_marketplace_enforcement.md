# Wave 3 E2E Marketplace & Enforcement Audit Report

**Audit date:** 2026-09-16  
**Repository revision:** `a5dfed0adb467546e42e9387ade9ccc0aa6add71` (`main`)  
**Scope (read-only):** Complete end-to-end Marketplace Amenity purchase lifecycle for the user-named surfaces **Slack**, **Safari/Browsing**, and **YouTube/Media**, plus **live enforcement countdown**, **22:00 Curfew hard lock**, and the **Emergency Safety Valve** (−2.0c debt; cooldown clarification).  
**Primary product/spec anchors (as requested):** `PRODUCT.md` §4 (Marketplace & Amenity Catalog), `PRODUCT.md` §7 (Emergency Safety Valve & Next-Day Debt), `SPEC.md` §2.2 (`WorkspaceObserver`), `SPEC.md` §2.3 (`GeminiAuditService`).  
**Adjacent sources required for E2E completeness (cited explicitly where used):** `PRODUCT.md` §5.1 (Curfew), §6 (48-hour config lock), `SPEC.md` §2.1 / §2.4 / §2.5 / §4.2 / §5.1 (ExchangeEngine curfew, governance cooldown, daemon/filter, wallet invariants, XPC emergency).  
**Primary subjects:** `AmenityCatalog`, `MarketplaceCoordinator`, `MarketplaceView` / `MarketplaceSnapshot`, `ExchangeEngine.purchaseAmenity`, `AmenityVoucher*`, `EnforcementDaemon` / `DaemonPassController`, `DomainFilterRules`, `FilterFlowEvaluator`, `ContentFilterProvider`, `EmergencySafetyValve*`, `PendingDebtStore` / `EmergencyIncidentStore`, `GovernanceLockPolicy`, `ActivityDetector` / `FocusMinting`, `GeminiAuditClient`.  
**Method:** Source-level walk of purchase → voucher → XPC redeem → policy overlay → countdown → expiry/re-lock, plus curfew and emergency paths, against PRODUCT/SPEC text and deterministic tests under `Tests/ZoidLockInTests/`. Tests were **not executed** in this pass (environment previously failed with `no such module 'Testing'`). Written assertions are design evidence only.

**Legend:** **PASS** = matches intent and numbers · **PARTIAL** = core path present with material deviations · **GAP / MISSING** = absent or contradicted · **FAIL** = product-required surface not reachable in the shipped app path.

---

## 1. Executive Verdict

| Lifecycle / area | Verdict | Confidence |
| :--- | :--- | :--- |
| **Catalog prices & durations (PRODUCT §4.1)** | **PASS** — all seven rows match `AmenityCatalog` | High |
| **YouTube / Media purchase → NE unblock (`.streaming`)** | **PASS** — 1.5c / 60m; YouTube + CDNs + Netflix + Twitch | High |
| **Safari / Browsing / Phone (`.phone`)** | **PARTIAL** — 1.5c / 60m; unlocks WhatsApp/Telegram domains only; **not** general Safari browsing; **not** Apple Focus Mode on Mac | High |
| **Slack** | **GAP** — no amenity, no blacklist, no whitelist entry for `slack.com` | High |
| **Live enforcement countdown** | **PASS** — daemon monotonic remaining → 1s UI tick → ACTIVE PASSES | High |
| **22:00 Curfew hard lock** | **PASS** — engine reject + UI LOCK + daemon clip/revoke; window **22:00–03:59** (SPEC §4.2) | High |
| **Emergency valve: 30m unlock-all + −2.0 debt + mail** | **PARTIAL** — daemon/ledger/mail/engine **PASS**; **hold UI + app coordinator wiring MISSING** | High |
| **“48-hour cooldown” with emergency** | **Clarified** — emergency re-engage cooldown is **24h** in code; **48h** is governance config lock (PRODUCT §6 / SPEC §2.4), not §7 | High |
| **SPEC §2.2 WorkspaceObserver** | **MISSING / PARTIAL** — no `WorkspaceObserver`; idle via `CGEventIdleMonitor` only (upstream of spendable credits) | High |
| **SPEC §2.3 GeminiAuditService** | **PASS (renamed)** — `GeminiAuditClient` + offline meeting mint → wallet → marketplace | High |

**Overall Wave-3 marketplace/enforcement E2E:** The **core spend → HMAC voucher → privileged redeem → kind-scoped unlock → monotonic expiry → UI countdown** path is implemented and test-backed for food / phone / streaming / gaming. **YouTube/Media is aligned.** **Safari/Browsing and Slack diverge** from product language (phone pass is messaging-portal scoped; Slack is absent). Curfew is **hard-locked** at both ledger and daemon. The Emergency Safety Valve’s **privileged machinery and −2.0 levy are solid**, but the product-required **5-second hold control is not wired into the app UI**, so the shipped E2E path for §7 is incomplete. The request’s “48-hour cooldown” on the valve conflates **governance** (48h) with **emergency re-arm** (24h).

---

## 2. Sources of Truth Mapped

### 2.1 PRODUCT.md §4 — Marketplace & Amenity Catalog

| ID | Requirement (condensed) | Primary implementation | Status |
| :--- | :--- | :--- | :--- |
| P4.1a | Bed Comfort **3.0** (self-enforced) | `AmenityKind.bed` / cost 3.0; no `PassKind` | **PASS** |
| P4.1b | Food Delivery **2.5** / 30-min Mac+Phone unblock | `.food` → `.food` pass; `foodDeliverySuffixes`; Mobile Shield | **PASS** |
| P4.1c | Phone / Social Browsing **1.5** / 60 min Focus release | `.phone` → NE messaging suffixes + iOS shield; **not** Focus Mode / Safari | **PARTIAL** |
| P4.1d | YouTube / Entertainment **1.5** / 60 min NE unblock | `.streaming` → `streamingSuffixes` | **PASS** |
| P4.1e | Gaming **1.5** / 30 min process barrier release | `.gaming` → process soft; empty domain relax | **PASS** |
| P4.1f | Outing **5.0** milestone | `.outing`; no daemon pass | **PASS** |
| P4.1g | Midday Rest **0.5** / 30 min | `.rest`; local timer only | **PASS** |

### 2.2 PRODUCT.md §7 — Emergency Safety Valve

| ID | Requirement | Primary implementation | Status |
| :--- | :--- | :--- | :--- |
| P7.1a | Always-accessible override (no password/2FA) | XPC method ungated by admin auth; **UI missing** | **PARTIAL** |
| P7.1b | Press-and-hold **5 continuous seconds** | `EmergencySafetyValveEngine.requiredHoldDuration = 5.0` | **PASS** (logic) / **FAIL** (UI) |
| P7.1c | Confirmation prompt (verbatim PRODUCT copy) | `confirmationPromptText` matches PRODUCT | **PASS** (logic) / **MISSING** (UI) |
| P7.1d | Unlock all distractions **30 minutes** | `DaemonLocalPass.emergencyDurationSeconds = 1800`; full blacklist whitelist + soft kills | **PASS** |
| P7.2a | Incident audit email | `AlertMailService` + coordinator `confirm()` | **PASS** (service) / **PARTIAL** (live app) |
| P7.2b | Next-day **−2.0** credit deficit (2-hour debt) | Incident → reconcile `.penalty` −2.0 | **PASS** |

### 2.3 SPEC.md §2.2 / §2.3 (requested) — upstream of purchases

| ID | Requirement | Primary implementation | Status |
| :--- | :--- | :--- | :--- |
| S2.2a | `WorkspaceObserver` via `NSWorkspace` + ScreenCaptureKit + Accessibility | **No type**; no NSWorkspace frontmost classification found | **MISSING** |
| S2.2b | Anti-idle via `CGEvent.tapCreate` / IOHID; 5 min idle → grace | `CGEventIdleMonitor` (`CGEventSource.secondsSinceLastEventType`); `FocusMinting` 30s/300s dual threshold | **PARTIAL** |
| S2.2c | Whitelisted tools feed focus ticks; non-whitelist interrupts | Focus is **manual** `startFocus` + idle sensor; no productive-app whitelist gate in observer | **GAP** |
| S2.3a | Gemini REST (`gemini-2.5-flash` / `pro`); `x-goog-api-key` header | `GeminiAuditClient` / `GeminiAuditModel` | **PASS** |
| S2.3b | Keychain service `com.mavoid.zoidlockin.gemini` | Keychain retrieval path in Gemini client | **PASS** (per Wave-1/3 focus audits) |
| S2.3c | Prompt sanitization + EXIF gate + structured JSON | Agenda sanitizer + EXIF + `APPROVED`/`REJECTED` | **PASS** |
| S2.3d | Appeal after **3** consecutive failures | `GeminiAuditPolicy.rejectionsBeforeAppeal = 3` | **PASS** |
| S2.3→Market | Approved meeting mints credits → spendable for amenities | `ExchangeEngine.mintEarnedMeeting` → wallet → `purchaseAmenity` | **PASS** |

### 2.4 Adjacent curfew / cooldown (required for requested E2E topics)

| ID | Requirement | Status |
| :--- | :--- | :--- |
| P5.1 / S4.2 | No entertainment/food(/phone/gaming) purchases **22:00–04:00** | **PASS** |
| P6 / S2.4 | **48h** config mutation lock (`172800`s) | **PASS** (`GovernanceLockPolicy`) |
| Emergency re-arm | Code: **24h** `DaemonPassController.emergencyCooldownSeconds` | **PASS in code**; not in PRODUCT §7 |

### 2.5 Key constants

| Constant | Value | Location |
| :--- | ---: | :--- |
| Bed / Food / Phone / Streaming / Gaming / Outing / Rest | **3.0 / 2.5 / 1.5 / 1.5 / 1.5 / 5.0 / 0.5** | `AmenityCatalog.intrinsicCost` |
| Phone / Streaming duration | **3600** s | `AmenityCatalog.durationSeconds` |
| Food / Gaming / Rest duration | **1800** s | same |
| Emergency pass | **1800** s | `DaemonLocalPass.emergencyDurationSeconds` |
| Emergency debt | **−2.0** | `PendingDebtRecord.emergencyPenaltyCredits` |
| Emergency re-engage cooldown | **86400** s (24h) | `DaemonPassController.emergencyCooldownSeconds` |
| Governance config cooldown | **172800** s (48h) | `GovernanceLockPolicy.cooldownSeconds` |
| Curfew window | hour `≥ 22 \|\| < 4` | `LocalCivilClock.isCurfew` |
| Hold duration | **5.0** s | `EmergencySafetyValveEngine` |
| Daemon watchdog | **0.25** s | `EnforcementDaemon.startWatchdog` |
| UI economy tick | **1** s | `ZoidLockInApp` timer |

---

## 3. Amenity Surface Mapping: Slack, Safari/Browsing, YouTube/Media

There is **no** catalog item named Slack or Safari. Mapping against PRODUCT §4.1 and the codebase:

| User label | Closest PRODUCT row | Code `AmenityKind` | Cost / duration | What unlocks | Gaps |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Slack** | Phone / Social Browsing | *(none)* | — | Nothing for Slack | **GAP:** `slack.com` not in blacklist or `communicationSuffixes`; Slack is neither blocked nor purchasable |
| **Safari / Browsing** | Phone / Social Browsing (mechanism: Apple Focus) | `.phone` | 1.5 / 60m | NE whitelist: `whatsapp.com`, `web.whatsapp.com`, `telegram.org`, `t.me` (+ Mobile Shield for phone) | Safari.app is **not** process-targeted; general browsing of non-blacklist hosts is already allowed; social hosts (Reddit/FB/IG/X/TikTok) stay **blocked** even with a phone pass |
| **YouTube / Media** | Streaming / Video | `.streaming` | 1.5 / 60m | NE whitelist: YouTube + googlevideo/ytimg CDNs + Netflix + Twitch families | **PASS** vs PRODUCT mechanism (network domain unblock). Process kills remain hard. Streaming is **not** an iOS Mobile Shield pass kind |

**Evidence — phone vs streaming scopes** (`DaemonLocalPass.swift`):

- `.phone.relaxedDomainSuffixes` → `DomainFilterRules.communicationSuffixes` (WhatsApp / Telegram only).
- `.streaming.relaxedDomainSuffixes` → `DomainFilterRules.streamingSuffixes` (YouTube / Netflix / Twitch + CDNs).
- Tests: `Slice3AdversarialHardeningTests.phoneAndStreamingPassScopes`, `Slice4AdversarialHardeningTests.streamingCDNDomainBlockingAndUnblocking`.

**Product-mechanism drift (phone):** PRODUCT §4.1 says *“Apple Focus Mode temporary release (60 min)”*. Implementation is **Network Extension suffix whitelist** on Mac plus **Mobile Shield / push** for iOS (`food` / `phone` only). No macOS Focus Mode API call sites were found for amenity redemption.

---

## 4. End-to-End Marketplace Purchase Lifecycle

```
MarketplaceCatalogRow BUY
  → MenuBarSession.purchase(kind)
  → MarketplaceCoordinator.purchase
       ├─ ExchangeEngine.purchaseAmenity  (curfew / spendable / ledger debit / HMAC voucher)
       ├─ redeemer.redeemAmenityVoucher   (XPC → EnforcementDaemon)
       │     ├─ verify voucher + replay journal
       │     ├─ clip duration to secondsUntilCurfew
       │     └─ DaemonPassController.install(kind)
       ├─ publishEffectivePolicy → FilterPolicyHub / NE overlay
       └─ MobileShield publish (food/phone)
  → 1s UI tick: queryStatus → MarketplaceSnapshot remainingSeconds
  → 0.25s daemon watchdog: expireIfNeeded → revoke overlay → re-lock
```

### 4.1 Step map with evidence

| Step | Behavior | Evidence | Status |
| :--- | :--- | :--- | :--- |
| 1. UI entry | Catalog rows; BUY disabled when curfew or in-flight | `MarketplaceView.swift` (~287–390) | **PASS** |
| 2. App wire | Async purchase; refresh snapshot + status | `ZoidLockInApp.swift` `purchase(_:)` (~559–585) | **PASS** |
| 3. Coordinator atomicity | Debit then redeem; **refund** on XPC failure; replay-nonce treated as success | `MarketplaceCoordinator.swift` (~89–124) | **PASS** |
| 4. Ledger debit | `BEGIN IMMEDIATE`; cost vs `CreditMath.spendable`; Friday zero for basics | `ExchangeEngine.purchaseAmenity` (~522–576) | **PASS** |
| 5. Voucher | HMAC claims: kind, catalog duration, nonce, transactionID, 300s TTL | `AmenityVoucher.swift`; daemon ignores client duration and uses catalog | **PASS** |
| 6. Privileged redeem | Verify → journal → install pass → publish | `EnforcementDaemon.redeemAmenityVoucher` (~154–198) | **PASS** |
| 7. Policy overlay | Kind-scoped whitelist union; gaming/emergency soft process mode | `EnforcementPolicy.overlay(for:)` (~49–88) | **PASS** |
| 8. NE enforcement | Filter sysex evaluates hostname on inspected ports | `ContentFilterProvider` + `FilterFlowEvaluator` | **PASS** (activation wiring residual from Wave-1 noted below) |
| 9. Countdown | Daemon `remainingSeconds` → `MarketplaceSnapshot.formattedCountdown` → ACTIVE PASSES | `MarketplaceSnapshot.swift` (~130–174); UI (~253–274); 1s tick (~417–456) | **PASS** |
| 10. Expiry / re-lock | Monotonic expiry; curfew revoke of sensitive kinds | `publishEffectivePolicy` (~413–426); `expireIfNeeded` | **PASS** |

### 4.2 Concurrent passes

Food and phone (and streaming) are **kind-indexed** and may run concurrently without clobbering (`DaemonPassController.passes: [PassKind: DaemonLocalPass]`). Covered by `Slice4MarketplaceTests.concurrentPassesExpireIndependently` and `marketplace coordinator XPC flow purchases food then phone together`.

### 4.3 Non-enforced amenities

| Kind | Spend | Daemon pass | Timer |
| :--- | :--- | :--- | :--- |
| `.bed` | Yes | No | None (day / self-enforced) |
| `.outing` | Yes | No | None |
| `.rest` | Yes | No | Local `MarketplaceCoordinator.localTimers` |

---

## 5. Live Enforcement Countdown

| Layer | Mechanism | Status |
| :--- | :--- | :--- |
| Expiry clock | Monotonic continuous (`DaemonLocalPass.remainingSeconds`); not wall `expires_at` from client | **PASS** |
| Daemon publish | Watchdog every **0.25s** recomputes `activePasses` + `remainingPassSeconds` | **PASS** |
| XPC status | `queryStatus()` → `EnforcementStatus.activePasses[]` | **PASS** |
| Snapshot | Maps `PassKind` remaining onto catalog rows; rest uses local timer | **PASS** |
| UI | ACTIVE PASSES list + per-row duration caption flip to `m:ss` / `h:mm:ss` | **PASS** |
| App refresh | Main timer **1s** pulls engine tick + `queryStatus` + reassembles marketplace | **PASS** |
| Countdown **to** curfew | `secondsUntilCurfew` used for **duration clipping** only; UI shows static `CURFEW 22:00–03:59` caption | **PARTIAL** |

---

## 6. 22:00 Curfew Hard Lock

### 6.1 Product / Spec

- **PRODUCT §5.1:** Entertainment, gaming, social media, and food delivery purchases disabled at **22:00:00**.
- **SPEC §4.2 Curfew Invariant:** No insert of `FOOD_PASS` / `GAMING_PASS` / `STREAMING_PASS` / `PHONE_PASS` between **22:00:00** and **04:00:00** local.
- **SPEC §2.1:** `ExchangeEngine` enforces the 22:00 curfew (engine responsibility).

### 6.2 Implementation (dual gate)

| Gate | Behavior | Evidence | Status |
| :--- | :--- | :--- | :--- |
| Civil clock | `hour >= 22 \|\| hour < 4` | `LocalCivilClock.isCurfew` | **PASS** |
| Catalog policy | food, phone, streaming, gaming, **outing** blocked; bed/rest allowed | `AmenityCatalog.isBlockedByCurfew` | **PASS** (+ outing stricter than PRODUCT list) |
| Ledger | `purchaseAmenity` throws `.curfew` | `ExchangeEngine` (~532–534) | **PASS** |
| UI | `isBlockedByCurfew` → BUY label **LOCK** + disabled | `MarketplaceView` | **PASS** |
| Daemon redeem | Rejects curfew-sensitive vouchers; clips duration to `secondsUntilCurfew` | `clippedAmenityDurationLocked` | **PASS** |
| Live revoke | On watchdog, `revokeCurfewSensitive()` drops food/phone/streaming/gaming | `publishEffectivePolicy` | **PASS** |
| Emergency | **Not** curfew-sensitive; may span overnight | `PassKind.isCurfewSensitive` | **PASS** (intentional) |

### 6.3 Tests (design evidence)

- `ExchangeEngineTests.curfewBlocksPurchases` — 21:59 OK; 22:00 food+streaming fail; bed OK.
- `Slice4MarketplaceTests.curfewRejectsEntertainmentAllowsRest` + `curfewSnapshotWarning`.
- `Slice4AdversarialHardeningTests.curfewDurationClipping` (21:55 → 300s remaining) + `curfewRejectAndWatchdogRevoke`.

### 6.4 Gaps

1. No dedicated overnight boundary tests for **03:59 still locked / 04:00 open**.
2. Shared curfew logic covers phone/gaming/outing, but purchase tests emphasize food/streaming.
3. No UI countdown-to-curfew (helper exists; caption only).

---

## 7. Emergency Safety Valve (−2.0c) and Cooldown Clarification

### 7.1 Intended vs shipped E2E

**Intended (PRODUCT §7 + tests):**

```
Press 5s → Confirm prompt → XPC engageEmergencySafetyValve
  → Daemon: incident append + 30m emergency pass (unlock-all)
  → User-space: record −2.0 pending debt + Resend incident mail
  → Midnight reconcile: levy −2.0 .penalty from unlevied incidents
```

**Shipped app path:**

| Piece | Status |
| :--- | :--- |
| Hold engine + coordinator (pure logic) | **PASS** — `EmergencySafetyValve.swift` |
| Daemon engage + 30m unlock-all | **PASS** — `EnforcementDaemon.engageEmergencySafetyValve` |
| Incident store + XPC query/mark levied | **PASS** |
| −2.0 at reconcile | **PASS** — `ExchangeEngine.reconcileLocked` (~752–771) |
| Mail formatter / Resend | **PASS** — `AlertMailService` |
| Dashboard card | **Status-only** (`EMERGENCY VALVE ARMED/OPEN` + pending debt) — `CommandDashboardView.emergencyCard` |
| Press-and-hold UI | **MISSING** — no Economy/App SwiftUI hold control |
| `EmergencySafetyValveCoordinator` app wiring | **MISSING** — constructed in tests only |

**Verdict:** Privileged and ledger halves of §7 are **PASS**. Product-facing **zero-friction hold control is FAIL/MISSING**, so the complete user E2E for Emergency Access is not shippable from the current UI.

### 7.2 Cooldown: do **not** conflate 48h with emergency

| Mechanism | Duration | Scope | Spec anchor | Status |
| :--- | ---: | :--- | :--- | :--- |
| **Governance config lock** | **48h (172800s)** | Amenity price / habit / blocklist mutations | PRODUCT §6; SPEC §2.4 (`CooldownManager` → `GovernanceLockPolicy`) | **PASS** |
| **Emergency re-engage** | **24h (86400s)** | Second `engageEmergencySafetyValve` after prior incident | Code-only (`DaemonPassController`); PRODUCT §7 silent | **PASS in code**; product-extra |

Emergency engagement is **not** gated by the 48-hour governance lock. Governance does **not** unlock distractions. Tests: `Slice2HardeningTests.emergencyCooldownRejectsRefresh` (24h); `Slice8MicroHabitsTests` (48h config).

### 7.3 Confirm prompt fidelity

`EmergencySafetyValveEngine.confirmationPromptText` matches PRODUCT §7.1 verbatim:

> *Confirm Emergency Access: This unlocks all distractions for 30 minutes, dispatches an incident audit alert, and levies a mandatory 2-hour focus debt tomorrow.*

---

## 8. SPEC §2.2 / §2.3 Adjacency to Marketplace

Marketplace purchases require a **spendable** wallet balance (`CreditMath.spendable`). Credits arrive from focus minting, offline meetings, and micro-habits.

### 8.1 SPEC §2.2 `WorkspaceObserver`

| Spec expectation | Code reality | Impact on marketplace |
| :--- | :--- | :--- |
| Named `WorkspaceObserver` | **Absent** | Naming drift |
| `NSWorkspace.didActivateApplicationNotification` + ScreenCaptureKit / Accessibility | **Not found** | No frontmost-app whitelist feeding the engine |
| CGEvent / HID anti-idle; 5 min → grace | `CGEventIdleMonitor` + `FocusMinting.presence` (active ≤30s; grace &lt;300s; abandon ≥300s) | Focus sessions can still mint → spend; idle farming mitigated partially |
| Whitelisted productive tools → ticks | Manual `startFocus` / `completeFocus`; idle only | User can run focus while non-productive apps are frontmost |

**Marketplace impact:** Spending path itself does not depend on WorkspaceObserver. **Earning** (and therefore ability to buy amenities) is weaker than SPEC §2.2’s anti-cheat story.

### 8.2 SPEC §2.3 `GeminiAuditService`

Implemented as `GeminiAuditClient` + `OfflineMeetingAuditCoordinator` (Flash audit, Pro appeal after 3 rejections, Keychain key, structured JSON). Approved meetings mint `.earnedMeeting` credits into the same wallet used by `purchaseAmenity`.

**Marketplace impact:** **PASS** as an upstream credit source for purchases; not part of pass redemption or curfew.

---

## 9. Requirement Traceability Matrix

| # | Requirement | Status | Notes |
| ---: | :--- | :--- | :--- |
| 1 | PRODUCT §4.1 pricing table | **PASS** | Exact match |
| 2 | PRODUCT §4.1 durations | **PASS** | Food/gaming/rest 30m; phone/streaming 60m |
| 3 | YouTube/Media NE unblock | **PASS** | `.streaming` |
| 4 | Safari/Browsing amenity behavior | **PARTIAL** | Messaging portals only; Safari unrestricted for non-blacklist hosts |
| 5 | Slack amenity / block / unlock | **GAP** | Not present |
| 6 | Phone = Apple Focus Mode | **GAP** | NE + Mobile Shield instead |
| 7 | Live pass countdown | **PASS** | Daemon + 1s UI |
| 8 | 22:00 purchase hard lock | **PASS** | Engine + UI + daemon |
| 9 | Overnight to 04:00 (SPEC §4.2) | **PASS** | `hour < 4` |
| 10 | Emergency 5s hold UI | **FAIL** | Logic only |
| 11 | Emergency 30m unlock-all | **PASS** | Daemon |
| 12 | Emergency −2.0 next-day debt | **PASS** | Reconcile levy |
| 13 | Emergency incident mail | **PARTIAL** | Service yes; app path unwired |
| 14 | 48h cooldown on emergency | **N/A / clarified** | 48h = governance; emergency = 24h |
| 15 | SPEC §2.2 WorkspaceObserver | **MISSING / PARTIAL** | Idle monitor only |
| 16 | SPEC §2.3 Gemini auditor | **PASS** | Renamed client; feeds wallet |

---

## 10. Findings (Prioritized)

### F-01 — Emergency hold UI not wired (PRODUCT §7.1) — Severity: **High**

- **Evidence:** `CommandDashboardView.emergencyCard` is caption-only; no `EmergencySafetyValveCoordinator` in `ZoidLockInApp` / Economy UI; coordinator used in `EmergencySafetyValveTests` only.
- **Impact:** User cannot perform the product-specified 5-second hold → confirm flow; privileged APIs exist but are unreachable from the shipped surface.
- **Action:** Wire always-visible hold control (menu bar and/or dashboard) to `EmergencySafetyValveCoordinator` with XPC dispatcher + mailer + incident-projecting debt store.
- **Verify:** Manual hold &lt;5s cancels; ≥5s + confirm → 30m unlock, mail attempt, pending −2.0; daemon cooldown rejects immediate re-fire.

### F-02 — Slack not in marketplace or filter matrix — Severity: **Medium**

- **Evidence:** No `slack` / `slack.com` matches under `Sources/`.
- **Impact:** Slack is neither blocked nor purchasable; PRODUCT “social browsing / messaging” expectation unmet for Slack users.
- **Action:** Product decision — add `slack.com` (+ CDN hosts if needed) to blacklist and `.phone` communication suffixes, or document Slack as out of scope.
- **Verify:** Without pass → drop; with `.phone` → allow; curfew blocks purchase.

### F-03 — Phone / “Safari browsing” ≠ PRODUCT Focus Mode / social browse — Severity: **Medium**

- **Evidence:** `communicationSuffixes` = WhatsApp/Telegram only; social hosts remain blacklisted under phone pass (`Slice3…phoneAndStreamingPassScopes`); no Focus Mode API.
- **Impact:** Buying Phone Pass does not enable Safari social browsing (Reddit/IG/X/etc.) nor macOS Focus release as written.
- **Action:** Align PRODUCT wording with NE messaging scope, **or** expand phone whitelist / add Focus integration.
- **Verify:** Domain matrix tests for intended hosts; Focus state if adopted.

### F-04 — Emergency cooldown is 24h, not 48h — Severity: **Low** (documentation / request clarity)

- **Evidence:** `DaemonPassController.emergencyCooldownSeconds = 24 * 60 * 60`; `GovernanceLockPolicy.cooldownSeconds = 172_800`.
- **Impact:** Request phrasing “Emergency Safety Valve (−2.0c, 48-hour cooldown)” mixes two systems; operators may misconfigure expectations.
- **Action:** Document both in PRODUCT/SPEC; decide whether emergency re-arm should be 24h, 48h, or unlimited (PRODUCT §7 currently silent).
- **Verify:** Existing Slice 2 / Slice 8 tests already encode current numbers.

### F-05 — SPEC §2.2 WorkspaceObserver absent — Severity: **Medium** (earning integrity, indirect marketplace)

- **Evidence:** No `WorkspaceObserver`; focus uses manual session + `CGEventIdleMonitor` only.
- **Impact:** Credits (and thus amenity purchasing power) can accrue without productive-app classification SPEC requires.
- **Action:** Implement frontmost/whitelist observer or amend SPEC to the idle-only model.
- **Verify:** Non-whitelist frontmost pauses minting; idle ≥300s abandons.

### F-06 — NE host activation residual (Wave-1 carry) — Severity: **Medium** (runtime)

- **Evidence:** Prior Wave-1 enforcement audit: `ContentFilterActivation` helpers exist; production app activation / `disableEncryptedDNSSettings` call-site gaps.
- **Impact:** Correct voucher/pass logic may not affect live Safari/YouTube sockets if the system extension is not enabled.
- **Action:** Confirm sysex registration path in app packaging (outside pure ledger/daemon unit tests).
- **Verify:** Manual: streaming purchase allows `youtube.com:443`; expiry re-drops.

### F-07 — No countdown-to-curfew UI — Severity: **Low**

- **Evidence:** `secondsUntilCurfew` used for clipping; marketplace footer is static caption.
- **Impact:** Users see LOCK at 22:00 but not a live T− warning.
- **Action:** Optional ticker using `secondsUntilCurfew` before 22:00.
- **Verify:** Caption reaches `0:00` at curfew boundary.

---

## 11. Test Coverage Map (Design Evidence)

| Suite | What it proves for this audit |
| :--- | :--- |
| `Slice4MarketplaceTests` | Debit, curfew, Friday zero-cost, concurrent food/phone, streaming after food expiry, snapshot countdown, XPC purchase flow |
| `Slice4AdversarialHardeningTests` | Voucher TTL 300s, curfew clip at 21:55, curfew redeem reject + watchdog revoke, streaming CDN allow/deny |
| `Slice3AdversarialHardeningTests` | Phone vs streaming domain scopes; emergency engage path (partial) |
| `Slice5MobileShieldTests` | Food/phone mobile sync + expiry relock |
| `ExchangeEngineTests` | Curfew purchase reject; emergency −2.0 netting (adjacent Wave-2) |
| `EmergencySafetyValveTests` | 5s hold progression, cancel, confirm → XPC+mail+−2.0, daemon unlock |
| `Slice2HardeningTests` | Emergency 30m overlay + **24h** cooldown |
| `Slice8MicroHabitsTests` | **48h** governance lock (`172_800`) |
| `AlertMailServiceTests` | Emergency mail subject/body |
| `DomainFilterRulesTests` / `ContentFilterAndSentinelTests` | YouTube blacklist / whitelist mechanics |

**Coverage holes:** Slack hosts; overnight 03:59/04:00 purchase boundary; phone/gaming/outing explicit curfew purchase tests; **UI** hold for emergency; end-to-end app wiring of valve coordinator.

---

## 12. Residual Risk & Exclusions

**In scope and verified at source level:** Amenity catalog, purchase coordinator, voucher/redeem, kind-scoped NE overlays for phone/streaming, live countdown, curfew dual gate, emergency daemon+debt+mail services, governance 48h vs emergency 24h distinction, SPEC §2.2/§2.3 adjacency.

**Exclusions / not re-proven here:** Full sysex packaging & notarization; live Resend/APNs credentials; iOS Shortcuts Focus Filter physical device behavior; NTP (covered in Wave-3 focus audit as GAP); admin 2FA depth (Wave-2 governance).

**Residual risk:** Highest product risk is **F-01** (emergency UI missing) combined with **F-06** (filter activation). Highest catalog fidelity risk for the named surfaces is **Slack absent** and **phone pass ≠ Safari social browsing**.

---

## 13. Proposed Remediation Batches (Audit Only — Not Applied)

1. **Batch A — Emergency valve ship path:** Wire hold UI + coordinator; connect mailer and incident debt projection; add UI integration test / manual checklist.
2. **Batch B — Messaging/browsing product alignment:** Decide Slack + social-browse hosts; update `communicationSuffixes` / PRODUCT §4.1 mechanism text; extend Slice 3 domain tests.
3. **Batch C — Spec hygiene:** Document emergency 24h cooldown; rename or add `WorkspaceObserver` adapter; clarify SPEC §2.2 vs idle-only reality.
4. **Batch D — Curfew polish:** Overnight boundary tests; optional countdown-to-curfew caption.

---

## 14. Completion Evidence

| Item | Detail |
| :--- | :--- |
| Revision | `a5dfed0adb467546e42e9387ade9ccc0aa6add71` |
| Mode | Read-only audit; report written to `.audit/wave3_e2e_marketplace_enforcement.md` only |
| Tools | Repository grep/read; parallel explore agents for marketplace / curfew / emergency; cross-check with Wave-1/2 audit notes |
| Tests run | **None** (compile environment previously lacked `Testing` module) |
| Requested anchors covered | PRODUCT §4, §7; SPEC §2.2, §2.3; plus adjacent §5.1 / §6 / SPEC §4.2 for curfew & cooldown topics named in the query |

**Bottom line:** Marketplace **YouTube/Media** and the **debit→voucher→daemon→countdown→re-lock** spine are solid; **curfew is hard-locked**; **−2.0 emergency debt** levies correctly. **Slack is missing**, **Safari/browsing semantics drift**, the **emergency hold UI is unwired**, and **“48-hour cooldown” belongs to governance — not the valve (which arms a 24h re-engage lock in code).**
