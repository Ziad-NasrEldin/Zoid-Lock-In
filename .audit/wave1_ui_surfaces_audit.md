# Wave 1 UI Surfaces Audit Report

**Scope:** Read-only comparison of `PRODUCT.md` §§2.3, 2.4, 4, 5, 6 and `SPEC.md` against:

| Surface / Module | Path |
| :--- | :--- |
| Marketplace | `Sources/ZoidLockInEconomy/MarketplaceView.swift` |
| Focus | `Sources/ZoidLockInEconomy/FocusPopoverView.swift` |
| Offline Meeting | `Sources/ZoidLockInEconomy/OfflineMeetingView.swift` |
| Micro-Habits | `Sources/ZoidLockInEconomy/MicroHabitsView.swift` |
| Command Dashboard | `Sources/ZoidLockInEconomy/CommandDashboardView.swift` |
| App wiring | `Sources/ZoidLockInApp/ZoidLockInApp.swift` |

**Supporting domain (not UI, but required for correctness of surface behavior):**

- `Sources/ZoidLockInCore/Economy/AmenityCatalog.swift`
- `Sources/ZoidLockInCore/Economy/MarketplaceSnapshot.swift`
- `Sources/ZoidLockInCore/Economy/LocalCivilClock.swift`
- `Sources/ZoidLockInCore/Economy/ExchangeEngine.swift`
- `Sources/ZoidLockInCore/Economy/MicroHabitCoordinator.swift` / `MicroHabitRecords.swift` / `MicroHabitsSnapshot.swift`
- `Sources/ZoidLockInCore/Economy/OfflineSessionCoordinator.swift` / `OfflineMeetingRecord.swift` / `OfflineMeetingAuditCoordinator.swift` / `GeminiAuditClient.swift`
- `Sources/ZoidLockInCore/Security/SecurityGatekeeper.swift` / `PasswordHasher.swift`
- `Sources/ZoidLockInCore/Economy/GovernanceLock.swift` / `GovernanceLockCoordinator.swift`
- `Sources/ZoidLockInCore/AlertMailService.swift`
- `Sources/ZoidLockInEconomy/SQLiteEconomicLedger.swift` / `SQLiteMicroHabits.swift`

**Audit date:** 2026-09-16  
**Mode:** Read-only (no code changes).  
**Verdict summary:** Core catalog prices, pass durations, 22:00 curfew, 1.5c micro-habit cap, offline triple-artifact + Gemini Flash/Pro appeal flows, and 48-hour + 2FA governance gating are largely implemented and wired through the menu-bar companion and command dashboard. Material gaps remain around password complexity, 10-minute admin session timeout, verbatim psychological email copy, Argon2id vs PBKDF2, seeded representative habit catalog, and dashboard coverage of marketplace / meeting / price-edit surfaces promised by PRODUCT §9 / §6.

---

## 1. Executive Matrix

| Requirement cluster | Spec source | Implementation status | Primary evidence |
| :--- | :--- | :--- | :--- |
| Marketplace catalog prices | PRODUCT §4.1 | **PASS** | `AmenityCatalog.intrinsicCost` matches table exactly |
| Pass durations | PRODUCT §4.1 | **PASS** (with naming nuance) | Food/gaming/rest = 30m; phone/streaming = 60m |
| 22:00 curfew lockout | PRODUCT §5.1, SPEC §4.2 | **PASS** (extended window) | Civil curfew `22:00–03:59`; UI LOCK + engine reject |
| Micro-habit 1.5c daily cap | PRODUCT §2.4, SPEC Slice 8 | **PASS** | `HabitCreditMinting.dailyCreditCap = 1.5` + UI CAP badge |
| Offline meeting triple artifacts | PRODUCT §2.3 | **PASS** | Notes / receipt / photo gates + submit disable |
| Gemini Flash audit + Pro appeal @ 3 | PRODUCT §2.3, SPEC §2.3 | **PASS** | UI retry/appeal; `rejectionsBeforeAppeal = 3` |
| 30-day artifact purge, hash retain | PRODUCT §2.3, SPEC Slice 6 | **PASS** | Retention caption + purge scheduler |
| 2FA password + TOTP admin gate | PRODUCT §6, SPEC §2.4 | **PARTIAL** | Length + TOTP yes; complexity + 10-min timeout missing |
| Psychological warning email | PRODUCT §6 | **PARTIAL** | Resend dispatch exists; copy ≠ PRODUCT verbatim |
| 48-hour config cooldown | PRODUCT §6, SPEC §2.4 / §4.2 | **PASS** | `172_800`s monotonic accrual; DEBUG bypass |
| Habit CRUD via Admin Dashboard | PRODUCT §2.4 / §9 | **PARTIAL** | CRUD in menu-bar Habit surface, gated by 2FA+48h; dashboard has no habit/price editor |
| Representative habit catalog | PRODUCT §2.4 | **GAP** | Proof snapshot only; no production seed |

**Legend:** PASS = matches intent and numbers · PARTIAL = core path present with material deviations · GAP = missing or contradicted by UI/domain wiring.

---

## 2. Catalog Prices (PRODUCT §4.1)

### 2.1 Spec table

| Amenity | Target cost |
| :--- | ---: |
| Sleeping in Bed | 3.0 |
| Food Delivery | 2.5 |
| 1 Hour Phone / Social | 1.5 |
| 1 Hour Streaming / Video | 1.5 |
| 30 Minutes Gaming | 1.5 |
| Going Out / Dinner Outing | 5.0 |
| 30-Minute Midday Break | 0.5 |

### 2.2 Implementation

`AmenityCatalog.intrinsicCost(of:)`:

| `AmenityKind` | Display name (UI) | Cost |
| :--- | :--- | ---: |
| `.bed` | Bed Comfort | 3.0 |
| `.food` | Food Pass | 2.5 |
| `.phone` | Phone Pass | 1.5 |
| `.streaming` | Streaming Pass | 1.5 |
| `.gaming` | Gaming Pass | 1.5 |
| `.outing` | Social Outings | 5.0 |
| `.rest` | Rest Break | 0.5 |

`MarketplacePopoverView` renders `snapshot.items` from `MarketplaceSnapshot.assemble`, which maps `AmenityKind.allCases` through the catalog. Buy rows show `formattedCost` and disable purchase when `isBlockedByCurfew` or `purchaseInFlight`.

`MenuBarSession.purchase` → `MarketplaceCoordinator.purchase` → `ExchangeEngine.purchaseAmenity` debits using the same catalog costs (Friday-adjusted).

### 2.3 Findings

| ID | Severity | Finding |
| :--- | :--- | :--- |
| P-01 | Info | **Numeric prices match PRODUCT §4.1 exactly.** |
| P-02 | Low | Display titles are shortened (“Bed Comfort”, “Food Pass”) vs PRODUCT long names (“Sleeping in Bed”, “Ordering Food Delivery…”). Subtitles recover delivery portals / process targets. Not a pricing defect. |
| P-03 | Info | Price overrides exist (`amenity_price_overrides` + `GovernanceLockCoordinator.setAmenityPrice`), but **Command Dashboard Settings has no amenity price editor UI**. Mutations are domain-capable; Wave 1 surfaces do not expose them. |

**Verdict:** Catalog prices **PASS**.

---

## 3. Pass Durations (PRODUCT §4.1 + SPEC Slice 4)

### 3.1 Spec

| Amenity | Duration |
| :--- | :--- |
| Food delivery | 30 min |
| Phone / social | 60 min |
| Streaming / video | 60 min |
| Gaming | 30 min |
| Midday rest | 30 min |
| Bed / outing | Day / milestone (non-timed) |

SPEC Slice 4 verification gate text says: *“Spending 1.5 credits unblocks the Network Extension for 30 minutes”* — that line is a coarse milestone shorthand and does **not** match the calibrated per-amenity schedule.

### 3.2 Implementation

`AmenityCatalog.durationSeconds(of:)`:

| Kind | Seconds | Caption |
| :--- | ---: | :--- |
| food, gaming, rest | 1800 | `30 min` |
| phone, streaming | 3600 | `60 min` |
| bed, outing | `nil` | `Day` |

UI: `MarketplaceCatalogRow` shows `durationCaption` / live `formattedRemaining`. Timed amenities with `passKind` mint HMAC vouchers redeemed over XPC; `.rest` uses a local timer in `MarketplaceCoordinator`.

### 3.3 Findings

| ID | Severity | Finding |
| :--- | :--- | :--- |
| D-01 | Info | **Durations match PRODUCT §4.1.** |
| D-02 | Medium (docs) | **SPEC Slice 4 gate text is inaccurate** relative to PRODUCT and `AmenityCatalog` (1.5c amenities are phone/streaming at **60** min or gaming at **30** min; food is **2.5**/30). Recommend correcting SPEC Slice 4 deliverable language. |
| D-03 | Low | Bed/outing show “Day” rather than PRODUCT’s behavioral language; acceptable for non-enforced / milestone items. |

**Verdict:** Pass durations **PASS** against PRODUCT; SPEC Slice 4 wording **PARTIAL / docs drift**.

---

## 4. 22:00 Curfew (PRODUCT §5.1, SPEC §4.2)

### 4.1 Spec

- PRODUCT §5.1: entertainment, gaming, social media, and food delivery purchases disabled at **22:00:00**.
- SPEC §4.2 Curfew Invariant: no `FOOD_PASS` / `GAMING_PASS` / `STREAMING_PASS` / `PHONE_PASS` insert between **22:00:00 and 04:00:00**.
- SPEC state machine: `DayActive → CurfewLocked` at 22:00.

### 4.2 Implementation

| Layer | Behavior |
| :--- | :--- |
| Civil clock | `LocalCivilClock.isCurfew` → `hour >= 22 \|\| hour < 4` |
| Catalog | `isBlockedByCurfew`: food, phone, streaming, gaming, **outing** = true; bed, rest = false |
| Snapshot / UI | `MarketplaceCatalogRow` shows **LOCK**, disables BUY when `ticker.isCurfew && isBlockedByCurfew` |
| Footer | `CURFEW ACTIVE · 22:00–03:59` / `OPEN · CURFEW 22:00–03:59` |
| Focus footer | Shows `CURFEW 22:00` when active (and not Friday rest) |
| Dashboard | Metric `CURFEW` LOCKED/OPEN + same caption |
| Engine | `purchaseAmenity` throws `.curfew` with message referencing 22:00–03:59 |
| Daemon | `PassKind.isCurfewSensitive` + `revokeCurfewSensitive()` for food/phone/streaming/gaming |

### 4.3 Findings

| ID | Severity | Finding |
| :--- | :--- | :--- |
| C-01 | Info | **22:00 start enforced** in UI and purchase path. |
| C-02 | Info | Overnight window through **03:59** matches SPEC invariant (PRODUCT only names the 22:00 cutoff; SPEC is stricter/clearer). |
| C-03 | Low | **Outing** is also curfew-blocked. PRODUCT §5.1 lists entertainment/gaming/social media/food, not “going out,” but treating outing as a night-sensitive amenity is consistent with anti-dumping intent. |
| C-04 | Info | Bed and rest remain purchasable during curfew (PRODUCT does not require locking them). |
| C-05 | Low | Focus surface shows curfew caption but does not itself gate focus minting (correct — curfew is a purchase rule). |

**Verdict:** Curfew **PASS** (SPEC-aligned; PRODUCT-aligned on 22:00 entertainment/food lock).

---

## 5. Micro-Habits & 1.5 Credit Cap (PRODUCT §2.4, SPEC Slice 8)

### 5.1 Spec

- Fractional rewards (representative: 0.25 / 0.25 / 0.25 / 0.50).
- Per-task daily frequency caps.
- **Hard daily ceiling: 1.5 credits** total from micro-habits.
- Customization (add / edit / value-scale / toggle) via **2FA Admin Dashboard**.
- 48-hour edit lockout with debug override (SPEC Slice 8 / PRODUCT §6).

### 5.2 UI (`MicroHabitsPopoverView`)

- Header + governance lock banner (`governance.bannerCaption`).
- Balance + **TODAY** earned + **CAP** (`1.5c LOCKED` / `1.5c OPEN`).
- Checklist rows with complete checkbox; disabled when `!habit.canComplete`.
- Habit editor: title field, reward chips **0.25 / 0.5**, frequency **1 / DAY · 2 / DAY**, ADD button.
- Editor disabled when `editorIsLocked` (48h lock, integrity fail, **or enrolled-but-locked 2FA**).

### 5.3 Domain wiring

| Constant / rule | Value |
| :--- | :--- |
| `HabitCreditMinting.dailyCreditCap` | **1.5** |
| `defaultReward` / `minReward` | 0.25 |
| `maxReward` | 1.5 |
| Frequency | 1…2 only |
| Complete path | per-habit frequency + remaining daily budget; engine clips/rejects at ceiling |
| Create/update | `governance.performMutation` → requires cooldown clear **and** `gatekeeper.requireUnlocked()` |

App wiring: `MenuBarSession.completeHabit` / `createHabit` → `MicroHabitCoordinator`.

### 5.4 Findings

| ID | Severity | Finding |
| :--- | :--- | :--- |
| H-01 | Info | **1.5c daily cap is enforced and surfaced** (metric + row status `CAP`). |
| H-02 | Info | Reward/frequency editor chips align with representative catalog values (0.25 / 0.50; max 2/day for dental-style tasks). |
| H-03 | Medium | **No production seed** of the PRODUCT representative catalog. `MicroHabitsSnapshot.proof` contains Brushing / Bed / Hydration / Stretching for screenshots only. Fresh installs start with **empty** habit list (“No micro-habits yet…”). |
| H-04 | Medium | PRODUCT §2.4 / §9 locate customization on the **Command Dashboard**. Actual CRUD UI lives in the **menu-bar HABIT** surface. Dashboard Settings shows 2FA unlock + 48h status but **no habit editor, toggle, or price/reward mutation controls**. |
| H-05 | Low | Editor allows only 0.25 and 0.5 chips (not arbitrary value-scale UI). Domain accepts any reward in `[0.25, 1.5]`; UI is a subset of “value-scale.” |
| H-06 | Info | 2FA gate on editor is correctly composed: enrolled + not unlocked ⇒ `editorIsLocked`, even if 48h cooldown has expired. |

**Verdict:** Cap and frequency safeguards **PASS**. Catalog seeding and Admin Dashboard placement **PARTIAL / GAP**.

---

## 6. Offline Meeting Artifact Gates (PRODUCT §2.3, SPEC Slices 6–7)

### 6.1 Spec Gate 1–2

1. Punch-in / punch-out time tracking.
2. Mandatory triple bundle:
   - Agenda & summary note
   - Physical/digital documentation (receipt / invoice / invite)
   - Contextual environment photo
3. Submit only when complete; hashes retained; binaries purge after 30 days.

### 6.2 UI (`OfflineMeetingPopoverView`)

- Punch toggle (`PUNCH IN` / `PUNCH OUT` / disabled when not allowed).
- **TRIPLE ARTIFACT GATE** rows: Agenda (記), Receipt (領), Photo (景).
- DROP/REPLACE via file importer + drag-drop; locked after submit.
- Allowed types:
  - Notes: `.md` / plain text
  - Receipt: JPEG / PNG / PDF
  - Photo: JPEG / HEIC / HEIF
- Submit disabled until `canSubmit` (phase awaiting evidence + no missing artifacts).
- Retention footer: `RAW ARTIFACTS PURGE 30 DAYS`.
- Abandon dialog mentions reboot / sessions longer than 240 minutes.

### 6.3 Domain enforcement (beyond UI)

| Gate | Policy |
| :--- | :--- |
| Duration | 15–240 minutes (`OfflineMeetingPolicy`) |
| Notes substance | ≥120 non-whitespace chars, ≥80 letters, ≥2 non-empty lines |
| Photo | Local EXIF / Apple camera signature / timestamp leeway (`MeetingPhotoValidator`) |
| Hashes | SHA-256 staged; unique indexes on receipt/photo; rehash on submit |
| Purge | `artifactRetention = 30 * 24 * 60 * 60`; `MeetingArtifactPurgeScheduler` from app tick |
| Immutability | SQLite triggers lock evidence after submit; terminal audit statuses sealed |

App: `importArtifact` → `meetings.attach`; `submitMeeting` → `submit` then `auditor.auditFlash`.

### 6.4 Findings

| ID | Severity | Finding |
| :--- | :--- | :--- |
| M-01 | Info | **Triple-artifact UI + submit gate match PRODUCT Gate 1–2.** |
| M-02 | Info | 30-day purge caption and scheduler match PRODUCT/SPEC retention. |
| M-03 | Low | Notes file importer allows `.plainText` UTType as well as markdown; domain still validates substance and prefers `notes.md` naming. |
| M-04 | Info | EXIF/camera validation is pre-network (SPEC §2.3 / Slice 6) — UI shows staging captions; hard fail occurs on attach/submit. |
| M-05 | Low | PRODUCT §9 claims Command Dashboard hosts offline meeting logging; live surface is menu-bar **MEET** tab (dashboard does not embed the dropzone). |

**Verdict:** Artifact gates **PASS**.

---

## 7. Gemini Audit Flows (PRODUCT §2.3, SPEC §2.3 / Slice 7)

### 7.1 Spec

- Dispatch multimodal bundle to Gemini (Keychain key).
- Models: **gemini-2.5-flash** initial; **gemini-2.5-pro** appeals.
- Auth via `x-goog-api-key` header only.
- Structured `APPROVED` / `REJECTED` + confidence + notes.
- Appeal only after **three consecutive rejections**; Pro arbitration; permanent seal on final reject.
- Prompt-injection sanitization of agenda/appeal text.

### 7.2 UI

After `phase == .submitted`, audit panel shows:

- Status caption + Gemini rationale + inconsistency bullets.
- **RETRY AUDIT** when `canRetryAudit`.
- **APPEAL TO GEMINI PRO** when `canAppeal` (denialCount == 3).
- Appeal sheet: sanitized statement warning; submit disabled if empty.

App wiring:

- `submitMeeting` → `auditFlash`
- `retryMeetingAudit` → `retryAudit`
- `appealMeeting` → `appealToPro`

### 7.3 Domain

| Item | Value / behavior |
| :--- | :--- |
| Flash / Pro enums | `gemini-2.5-flash`, `gemini-2.5-pro` |
| Appeal threshold | `GeminiAuditPolicy.rejectionsBeforeAppeal = 3` |
| Confidence floor | 0.7 |
| API key header | `x-goog-api-key` |
| Sanitizer | `PromptInjectionSanitizer` on agenda + appeal |
| Terminal states | `APPROVED`, `ARBITRATED_APPROVED`, `SEALED_REJECTED` |

### 7.4 Findings

| ID | Severity | Finding |
| :--- | :--- | :--- |
| G-01 | Info | **Flash → 3 rejects → Pro appeal UI/domain path matches PRODUCT.** |
| G-02 | Info | Instant approval / rejection rationale surfaced in popover. |
| G-03 | Low | UI does not expose model name strings; acceptable (behavior is correct). |
| G-04 | Info | Keychain-backed client + header auth match SPEC §2.3 (not visible in Economy UI; wired from app). |

**Verdict:** Gemini audit flows **PASS**.

---

## 8. 2FA Governance Gate (PRODUCT §6, SPEC §2.4)

### 8.1 Spec sequence

1. Password ≥12 chars with **uppercase, lowercase, numbers, symbols**.
2. Google Authenticator TOTP (RFC 6238).
3. Psychological warning email (PRODUCT verbatim “CRITICAL SECURITY & INTEGRITY ALERT…”).
4. Unlocks session with **10-minute timeout**.
5. Config edits start **48-hour read-only** lockdown (`172800` seconds).
6. DEBUG / staging bypass of cooldown; disabled in production.
7. SPEC: Argon2id password hash; Resend mail on admin auth.

### 8.2 Command Dashboard Settings UI

- Tabs: Overview / Ledger / Settings.
- Enrollment: password + confirm + generated TOTP secret + otpauth URL + test code.
- Unlock: password (≥12) + 6-digit TOTP → `onUnlock`.
- Unlocked: alert recipient, last alert kind, LOCK SETTINGS.
- Side cards: **48-HOUR GOVERNANCE** countdown + emergency valve status (display only).
- Copy states: twelve-character password + Google Authenticator TOTP; Resend warning on unlock.

App: `MenuBarSession.unlockSettings` / `enrollSettings` / `lockSettings` → `SecurityGatekeeper`; governance snapshot fed from `GovernanceLockCoordinator` (gatekeeper injected).

### 8.3 Habit surface coupling

`MicroHabitCoordinator.snapshot` sets:

```text
editorIsLocked =
  (48h locked && !bypass) || integrityFailed || (enrolled && !unlocked)
```

Create/update calls `governance.performMutation` → `requireSecurityUnlockedLocked()`.

### 8.4 Findings

| ID | Severity | Finding |
| :--- | :--- | :--- |
| S-01 | High | **Password complexity classes not enforced.** Only `password.count >= 12` (`PasswordHasher.validateLength`). PRODUCT requires upper/lower/number/symbol. |
| S-02 | High | **No 10-minute admin session timeout.** `unlocked` is a boolean cleared only by `lockSettings()`; no auto-expiry from `unlockedAt`. |
| S-03 | Medium | **Admin email copy diverges from PRODUCT.** Implementation sends `PSYCHOLOGICAL COMMITMENT ALERT` / `WARNING: Admin settings unlocked` — not the PRODUCT verbatim “CRITICAL SECURITY & INTEGRITY ALERT: You have authenticated into the Zoid 0 Trading Center Admin Settings…”. |
| S-04 | Medium | **SPEC §2.4 Argon2id vs implementation PBKDF2-HMAC-SHA256** (`pbkdf2-sha256$…`). Security intent present; algorithm mismatch vs SPEC. |
| S-05 | Info | TOTP RFC 6238 + replay window + Keychain storage **PASS**. |
| S-06 | Info | 48-hour cooldown = `172_800` seconds; remaining time from **monotonic accrual**; DEBUG env `ZOID_BYPASS_GOVERNANCE_COOLDOWN`; Release compile-time bypass disabled — **PASS**. |
| S-07 | Medium | Dashboard Settings unlocks the gate but **does not present mutation UIs** (prices, blocklist, habit CRUD). Mutations are reachable from menu-bar Habit editor (and domain APIs) after unlock — friction path is split across surfaces. |
| S-08 | Low | Emergency valve card is **status-only** on dashboard (no 5-second hold control here). Out of PRODUCT §6 scope but relevant to §7 / dashboard completeness. |
| S-09 | Info | Local audit mode when Resend key missing is disclosed in unlocked settings — good operational honesty. |

**Verdict:** 2FA + 48h governance **PARTIAL** — authentication and cooldown work; complexity, session timeout, mail copy, and Argon2id diverge from PRODUCT/SPEC.

---

## 9. Surface-by-Surface Coverage

### 9.1 `MarketplaceView` / `MarketplacePopoverView`

| Concern | Status |
| :--- | :--- |
| Full amenity catalog | Present |
| Live costs / Friday zero-cost display | Present (`isFridayZeroCost` → `"0"`) |
| Active pass timers | Present |
| Vault + streak metrics | Present |
| Curfew LOCK/BUY | Present |
| Purchase errors | Present |
| Mobile shield banner | Present |
| Price editing | Absent (by design for popover; also absent on dashboard) |

### 9.2 `FocusPopoverView`

| Concern | Status |
| :--- | :--- |
| Punch in / complete focus | Present |
| Grace / abandoned / completed states | Present |
| Next mint (+0.5c) + earned today + wallet | Present |
| Morning momentum 2.0× / 90m / noon copy | Present (PRODUCT §2.2 adjacent; consistent) |
| Curfew / Friday rest footer | Present |
| Marketplace purchases | N/A (separate tab) |

### 9.3 `OfflineMeetingView`

| Concern | Status |
| :--- | :--- |
| Punch in/out | Present |
| Triple artifact dropzone | Present |
| Submit gate | Present |
| Gemini rationale / retry / Pro appeal | Present |
| 30-day retention caption | Present |
| Agenda text editor in-popover | Absent — file import only (acceptable vs PRODUCT “attach”) |

### 9.4 `MicroHabitsView`

| Concern | Status |
| :--- | :--- |
| Checklist + complete | Present |
| 1.5c cap UI | Present |
| 48h lock banner | Present |
| Create habit editor | Present (gated) |
| Edit / toggle existing habits | **Absent in UI** (domain `updateHabit` / `setEnabled` exist; no row controls) |
| Representative seed catalog | Absent in runtime |

### 9.5 `CommandDashboardView`

| Concern | Status |
| :--- | :--- |
| Wallet / focus / emergency debt / curfew | Present |
| Lifetime Surplus Vault | Present |
| Victory streak + deficit strikes | Present |
| Ledger filter / search / pagination | Present |
| 2FA enroll / unlock / lock | Present |
| 48h governance display | Present |
| Marketplace browse / buy | **Absent** (PRODUCT §9 dual-surface claim) |
| Offline meeting logging | **Absent** |
| Habit CRUD / amenity price edit | **Absent** |
| Vault caption accuracy | **Bug:** copy says *“credits banked from **21:00** midnight rollovers”* — PRODUCT §5.2 is **23:59:59** midnight reconciliation |

### 9.6 `ZoidLockInApp` / `MenuBarSession`

Wiring completeness for Wave 1 surfaces: **PASS**.

- Menu bar companion hosts Focus / Market / Meet / Habit + dashboard launch.
- Dashboard window `command-dashboard` hosts `CommandDashboardView`.
- Coordinators bound: economy tick, marketplace, shield, meetings, Gemini auditor, purge, habits, governance, calibration, gatekeeper, XPC.
- Proof render CLI flags for each surface exist (engineering verification aids).

---

## 10. Cross-Cutting Doc / Schema Drift (SPEC vs code)

Relevant when UI claims depend on schema/modules named in SPEC:

| Topic | SPEC | Code | Impact on UI audit |
| :--- | :--- | :--- | :--- |
| Password hash | Argon2id | PBKDF2-SHA256 | Settings security posture |
| `system_state` single-row | SPEC §3.1 | Split across vault / governance / calibration tables | Transparent to UI |
| `micro_habit_logs` | SPEC name | `micro_habit_completions` | Transparent to UI |
| `active_amenity_passes` in SQLite | SPEC §3.1 | Passes live in daemon / vouchers more than ledger table | Marketplace timers from enforcement status |
| Slice 4 “1.5c / 30m” | Slice table | Catalog is multi-price / multi-duration | Docs only |
| Module names (`GeminiAuditService`, `CooldownManager`) | PRODUCT §9 | `GeminiAuditClient` + `OfflineMeetingAuditCoordinator`, `GovernanceLockCoordinator` | Naming drift |

---

## 11. Prioritized Gap List

### P0 — Spec/product security promises not met

1. **S-01** Enforce password character-class complexity (or amend PRODUCT §6).
2. **S-02** Implement 10-minute admin unlock timeout (or amend PRODUCT §6).

### P1 — User-visible / governance product gaps

3. **S-03** Align Resend admin alert body with PRODUCT psychological copy (or revise PRODUCT to match shipped text).
4. **H-03** Seed representative micro-habit catalog on first launch (or document empty-start as intentional).
5. **H-04 / S-07 / M-05** Resolve PRODUCT §9 placement: either move habit/price/meeting/marketplace admin editing onto Command Dashboard, or update PRODUCT to state menu-bar companion ownership.
6. **Vault caption** Fix “21:00 midnight” → midnight / 23:59:59 language in `CommandDashboardView`.

### P2 — Documentation & secondary UX

7. **D-02** Correct SPEC Slice 4 verification gate wording.
8. **S-04** Align SPEC Argon2id claim with PBKDF2 (or migrate hasher).
9. **H-05 / H-edit** Add edit/toggle controls for existing habits if PRODUCT “edit, value-scale, and toggle” remains binding.
10. **P-03** Expose amenity price mutation UI behind unlocked Settings if PRODUCT §6 “adjusting prices” is a Wave 1 deliverable.

---

## 12. Evidence Index (key symbols)

| Topic | Symbol / location |
| :--- | :--- |
| Prices | `AmenityCatalog.intrinsicCost` |
| Durations | `AmenityCatalog.durationSeconds` |
| Curfew civil | `LocalCivilClock.isCurfew` |
| Curfew purchase | `ExchangeEngine.purchaseAmenity` |
| Curfew UI | `MarketplaceCatalogRow` LOCK/BUY |
| Habit cap | `HabitCreditMinting.dailyCreditCap` |
| Habit UI cap | `MicroHabitsPopoverView` CAP metric |
| Habit 2FA+48h lock | `MicroHabitCoordinator.snapshot` `editorIsLocked` |
| Meeting artifacts | `OfflineMeetingPopoverView.dropzone`, `OfflineSessionCoordinator.submit` |
| Gemini models | `GeminiModel.flash/pro`, `GeminiAuditPolicy.rejectionsBeforeAppeal` |
| Appeal UI | `OfflineMeetingPopoverView` appeal sheet |
| 2FA UI | `CommandDashboardView.settingsPane` |
| Cooldown | `GovernanceLockPolicy.cooldownSeconds = 172_800` |
| Admin mail | `AlertMailService.makeAdminPayload` |
| App composition | `MenuBarSession` in `ZoidLockInApp.swift` |

---

## 13. Final Verdict

Wave 1 UI surfaces **faithfully present and drive** the calibrated marketplace prices, pass durations, 22:00 (through 03:59) curfew, micro-habit **1.5c** ceiling, offline triple-artifact submission, and Gemini Flash / three-strike Pro appeal loop. The app shell correctly binds Economy views to Core coordinators.

The largest product/SPEC deltas are concentrated in **admin governance hardening** (password complexity, 10-minute timeout, mail verbatim, Argon2id), **Admin Dashboard surface completeness** (no price/habit editors; marketplace & meeting live in the menu bar), and **missing seeded representative habits**. Until those are closed or the docs are updated, PRODUCT §§2.4 / 6 / 9 should be treated as only **partially** satisfied by the current UI matrix.
