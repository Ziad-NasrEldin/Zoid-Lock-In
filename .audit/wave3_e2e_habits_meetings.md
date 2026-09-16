# Wave 3 E2E Audit — Micro-Habits & Offline Meeting Triple-Gate

**Audit date:** 2026-09-16  
**Repository revision:** `a5dfed0adb467546e42e9387ade9ccc0aa6add71`  
**Commit under review:** `a5dfed0` — *feat(ui): add native Focus work session tab in menu bar and fix reboot tamper lock*  
**Scope (read-only):** End-to-end Micro-Habits lifecycle (1.5c daily cap, per-habit frequency limits, contribution to victory streak) and Offline Meeting Triple-Gate (punch in/out, Gemini Flash evaluation, Gemini Pro human-in-the-loop appeal).  
**Method:** Source-level lifecycle walkthrough against PRODUCT/SPEC requirements; cross-check of SQLite DDL, UI wiring in `ZoidLockInApp`, and Slice 6–8 tests (cited as evidence only — not executed in this pass).  
**Artifact convention:** Written to `.audit/wave3_e2e_habits_meetings.md` per request; no source, config, or Git state modified beyond this report.

---

## 0. Spec Citation Correction

The audit request cited **PRODUCT.md §3 / §3.5** and **SPEC.md §2.5 / §2.6**. Those headings map to:

| Cited | Actual content | Relevance to habits / meetings |
| :--- | :--- | :--- |
| PRODUCT §3 | Hard Digital Enforcement Matrix (daemon, NE, iOS shield) | Adjacent only (punch-in pauses digital focus; habits do not drive enforcement) |
| PRODUCT §3.5 | **Does not exist** | — |
| SPEC §2.5 | `EnforcementDaemon` & `ContentFilterProvider` | Out of scope for credit minting |
| SPEC §2.6 | `SyncManager` (Cross-Device Mobile Shield) | Out of scope for habits / meetings |

**Authoritative sections for this audit:**

| Domain | PRODUCT | SPEC |
| :--- | :--- | :--- |
| Offline Meeting Triple-Gate | **§2.3** (+ architecture §9 Gemini / OfflineSession) | **§2.3** `GeminiAuditService`; schema `offline_meetings`; Slices **6–7** |
| Micro-Habits | **§2.4** | Schema `micro_habits` / logs; Slice **8**; cooldown invariant §4.2.4 |
| Victory Streak | **§5.2** (midnight reconciliation) | ExchangeEngine streak / vault; Slice 3 reconciliation tests |

Enforcement / Sync (§3, SPEC §2.5–§2.6) are noted only where they touch meeting focus mutex or share clocks.

---

## 1. Executive Verdict

| Lifecycle question | Verdict | Confidence |
| :--- | :--- | :--- |
| **Micro-habit 1.5c / day hard ceiling** | **PASS** — dual civil-day + rolling 24h monotonic budget; engine + coordinator double-gate | High |
| **Per-habit daily frequency limits (1–2)** | **PASS** — validated on CRUD; enforced on complete | High |
| **Habit mint → wallet (`EARNED_HABIT`) → streak eligibility** | **PASS** — habits count as daily earned; streak increments at midnight when earned ≥ 3.0 | High |
| **Gate 1: punch-in / punch-out** | **PASS** — monotonic + uptime, boot UUID, sleep/awake gates, TT lock | High |
| **Gate 2: triple-artifact bundle** | **PASS** — notes + receipt + photo; EXIF Apple camera gate; SHA-256 immutability | High |
| **Gate 3: Gemini Flash evaluation** | **PASS** — auto on submit; Flash model; confidence floor 0.7; denial counter | High |
| **“Flash 30s evaluation” framing** | **GAP / nuance** — no PRODUCT/SPEC 30s SLA; code uses **20s** `requestTimeout` × up to 3 attempts | High |
| **Gemini Pro human-in-the-loop appeal** | **PASS** — unlocks at exactly 3 consecutive Flash rejections; user statement required; Pro reject → sealed | High |
| **30-day artifact purge, hashes retained** | **PASS** | High |
| **DDL vs SPEC §3 naming** | **DRIFT** — functional tables present under evolved names/columns | High |

**Overall:** Both E2E pipelines are **implemented and product-aligned**. Micro-habits correctly enforce frequency + 1.5c ceiling and feed the victory-streak earned total. Offline meetings implement the full triple-gate with Flash → 3-rejection → Pro appeal seal. Material gaps are **specification naming drift**, **victory-streak rule simplification** vs PRODUCT §5.2 wording, and **no documented 30-second Flash SLA** (implementation timeout is 20s).

---

## 2. Architecture Map

```
┌──────────────────────────────────────────────────────────────────────────┐
│ MenuBarEconomyController (ZoidLockInApp)                                 │
│   ├─ MicroHabitCoordinator ──► ExchangeEngine.mintEarnedHabitAndThen     │
│   │                              + GovernanceLockCoordinator (CRUD)      │
│   ├─ OfflineSessionCoordinator ──► SQLite offline_meetings + artifacts   │
│   │         punchIn/Out / attach / submit                                │
│   └─ OfflineMeetingAuditCoordinator ──► GeminiAuditClient                │
│            Flash (auto) / Pro (appeal) ──► mintEarnedMeetingAndThen      │
└──────────────────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
  micro_habits +                 offline_meetings +
  micro_habit_completions        ~/…/meetings/<id>/{notes,receipt,photo}
         │                              │
         └──────────► wallet_transactions (EARNED_HABIT | EARNED_MEETING)
                              │
                              ▼
                    midnight reconcile → lifetime_vault.currentStreak
```

| Component | File | Role |
| :--- | :--- | :--- |
| `MicroHabitCoordinator` | `Sources/ZoidLockInCore/Economy/MicroHabitCoordinator.swift` | CRUD (48h lock), complete, snapshot |
| `HabitCreditMinting` | `MicroHabitRecords.swift` | Cap 1.5, freq 1–2, clip math |
| `OfflineSessionCoordinator` | `OfflineSessionCoordinator.swift` | Punch + local triple gate |
| `OfflineMeetingAuditCoordinator` | `OfflineMeetingAuditCoordinator.swift` | Flash / Pro lifecycle + mint |
| `GeminiAuditClient` | `GeminiAuditClient.swift` | REST generateContent, sanitizer, timeout |
| `MeetingArtifactPurgeScheduler` | `MeetingArtifactPurgeScheduler.swift` | 30-day binary purge |
| SQLite adapters | `SQLiteMicroHabits.swift`, `SQLiteOfflineMeetings.swift`, `SQLiteEconomicLedger.swift` | Persistence |

Production wiring injects the same ledger as `habitWindow` into `ExchangeEngine` so rolling-window habit credits are engine-visible (`ZoidLockInApp.swift`).

---

## 3. Micro-Habits E2E Lifecycle

### 3.1 PRODUCT §2.4 requirements checklist

| ID | Requirement | Implementation | Status |
| :--- | :--- | :--- | :--- |
| H1 | Fractional credits (e.g. +0.25) | `defaultReward = 0.25`; range 0.25–1.5 | **PASS** |
| H2 | Customizable add/edit/toggle via Admin | `createHabit` / `updateHabit` / `setEnabled` through `governance.performMutation` | **PASS** |
| H3 | Catalog examples (teeth 2/day, bed/water 1/day, stretch 0.50) | Not auto-seeded; proof UI uses catalog titles; CRUD allows matching values | **PASS (engine)** / **N/A (no seed)** |
| H4 | Strict daily frequency caps per task | `completions(habitID:on:).count >= dailyFrequencyLimit` → `dailyFrequencyReached` | **PASS** |
| H5 | Overall micro-habit earnings ≤ **1.5c / day** | `HabitCreditMinting.dailyCreditCap = 1.5` + clip / refuse | **PASS** |
| H6 | Config edits under 48h cooldown | `GovernanceLockCoordinator.performMutation` | **PASS** (Slice 8) |

### 3.2 Completion path (happy path)

1. UI calls `complete(habitID:)` (`MicroHabitsPopoverView` → `MenuBarEconomyController`).
2. `ensureEconomyWritable()` (time-travel gate).
3. Habit must exist and `isEnabled`.
4. Civil day key from **pinned** governance timezone (`LocalCivilClock`).
5. Frequency: prior completions that civil day vs `dailyFrequencyLimit`.
6. Cap: `cappedEarned(max(civilDayLedger, rolling24hMonotonic))`; refuse if remaining ≤ 0; else clip reward.
7. Atomic `mintEarnedHabitAndThen` → append `EARNED_HABIT` with `referenceID = habit:<completionID>` → `insertCompletion`.
8. Snapshot shows `CAP` / `DONE` / `n / limit` captions and daily `earned / 1.5`.

Evidence constants (`MicroHabitRecords.swift`):

```swift
public static let dailyCreditCap: Double = 1.5
public static let minDailyFrequency: Int = 1
public static let maxDailyFrequency: Int = 2
public static let rollingWindowSeconds: TimeInterval = 86_400
```

### 3.3 Anti-exploitation layers

| Layer | Mechanism | Evidence |
| :--- | :--- | :--- |
| Per-habit frequency | Count completions on civil day | Coordinator `complete`; Slice8 frequency test |
| Global 1.5 ceiling | Civil ledger + rolling monotonic max | `cappedEarned`; Slice8 ceiling + clip tests |
| TZ hop bypass | Pinned TZ + rolling 24h window | Slice8Adversarial `timezoneHoppingCannotBypassCreditCeiling` |
| Idempotency | Unique `habit:<uuid>` wallet reference | Slice8 idempotent mint test |
| Disabled habits | `habitDisabled` | Coordinator guard |
| Clock tamper | Maps `ExchangeEngineError.clockTampered` | Coordinator |

### 3.4 Streak increments (habits → victory streak)

There is **no separate habit streak**. PRODUCT §5.2 victory streak is evaluated at midnight reconciliation.

| Step | Behavior |
| :--- | :--- |
| During day | `EARNED_HABIT` amounts are wallet credits |
| `countsAsDailyEarned` | `.mint`, `.earnedMeeting`, `.earnedHabit` all count |
| Midnight | `earned = Σ countsAsDailyEarned`; if `earned >= 3.0` → `vault.currentStreak += 1`; if non-Friday and `earned < 3.0` → streak reset + −1.0 deficit |

**Nuance vs PRODUCT §5.2:** Product text requires “daily target met (**all baseline amenities paid** and zero deficit).” Implementation increments on **earned ≥ 3.0 only**, without checking that bed/baseline amenities were purchased. Habit credits can therefore contribute to a streak without amenity spend. Same nuance applies to meeting and focus mints.

**Friday:** Deficit / streak-break path skipped on Friday; streak does not auto-increment from “rest day zero work” unless earned still reaches 3.0.

### 3.5 Schema drift (habits)

| SPEC §3 | Implementation | Notes |
| :--- | :--- | :--- |
| `micro_habits.daily_limit` / `is_active` | `daily_frequency_limit` / `is_enabled` | Renamed |
| `micro_habit_logs (log_date)` | `micro_habit_completions (civil_date, credits_awarded, created_monotonic)` | Richer; rolling window needs monotonic |
| Transaction `EARNED_MICRO` | `EARNED_HABIT` | Vocabulary drift (consistent in code/tests) |

---

## 4. Offline Meeting Triple-Gate E2E Lifecycle

### 4.1 PRODUCT §2.3 / SPEC §2.3 checklist

| ID | Requirement | Implementation | Status |
| :--- | :--- | :--- | :--- |
| M1 | Punch-in at start | `OfflineSessionCoordinator.punchIn` | **PASS** |
| M2 | Punch-out at end | Duration 15–240 min; sleep ≤ 20%; awake ≥ 15 min; same boot UUID | **PASS** |
| M3 | Agenda & summary notes | `MeetingArtifactKind.notes` + substance policy (≥120 non-ws, ≥80 letters, ≥2 lines) | **PASS** |
| M4 | Receipt / document | jpg/png/pdf; unique SHA-256 across meetings | **PASS** |
| M5 | Contextual photo | EXIF Apple camera, timestamp in window (+15m leeway), size ≥1000px edge | **PASS** |
| M6 | Gemini multimodal audit | Flash `gemini-2.5-flash`; Keychain key; `x-goog-api-key` header | **PASS** |
| M7 | Instant approve → credits | `persistApproval` → `mintEarnedMeetingAndThen` | **PASS** |
| M8 | Reject → rationale | `aiReasoning` + denialCount | **PASS** |
| M9 | Appeal after **3 consecutive** rejections | `rejectionsBeforeAppeal = 3`; `canAppealToPro` | **PASS** |
| M10 | Gemini Pro arbitration | `gemini-2.5-pro`; user appeal statement | **PASS** |
| M11 | Pro reject → permanent seal | `SEALED_REJECTED` + SQLite trigger lock | **PASS** |
| M12 | Purge binaries after 30 days; keep hashes | `artifactRetention = 30d`; purge scheduler | **PASS** |
| M13 | Prompt injection defense | `PromptInjectionSanitizer` + visual injection system text | **PASS** |
| M14 | EXIF gate before network | `MeetingPhotoValidator` on attach + submit rehash | **PASS** |
| M15 | Structured JSON verdict | `decision`, `confidence_score`, `rationale`, `detected_inconsistencies` | **PASS** |

### 4.2 Gate 1 — Punch in / out

```
punchIn → upsert IN_PROGRESS, bind focus mutex (conclude digital focus)
   │
   │  wall + CLOCK_MONOTONIC + CLOCK_UPTIME_RAW + bootSessionUUID
   ▼
punchOut → duration / sleep / awake / TT / boot checks → punched timestamps
```

- Punch-in refuses double-record; ends digital focus via `beginOfflineMeeting`.
- Punch-out refuses cross-reboot sessions (`bootSessionChanged`).
- Time-travel observe on both edges.
- UI: `punchToggle()` / meeting popover.

### 4.3 Gate 2 — Triple artifacts

| Artifact | Local checks |
| :--- | :--- |
| Notes | UTF-8 markdown; `MeetingNotesPolicy` substance |
| Receipt | Extension allowlist; unique `receipt_image_sha256` |
| Photo | Extension allowlist; EXIF Apple + timestamp window; unique `photo_image_sha256` |

`submit()` requires punch-out + all three artifacts, rehashes disk vs stored digests, sets `PENDING`, schedules `artifactsPurgeDate = punchOut + 30d`.

SQLite triggers freeze evidence after submit and freeze audit fields on terminal statuses.

### 4.4 Gate 3a — Gemini Flash evaluation

**App path** (`ZoidLockInApp.submitMeeting`):

```
submit() → auditFlash(meetingID) → verdict → APPROVED mint | REJECTED denial++
```

| Policy constant | Value | Role |
| :--- | :--- | :--- |
| Model | `gemini-2.5-flash` | Initial audit |
| `approvalConfidenceFloor` | **0.7** | Low-confidence APPROVED treated as rejection |
| `rejectionsBeforeAppeal` | **3** | Pro unlock |
| `requestTimeout` | **20** seconds | Per HTTP attempt |
| `maxAttempts` | **3** | Retry on 429/503/timeout/network |

**“Flash 30s evaluation”:** Neither PRODUCT §2.3 nor SPEC §2.3 defines a 30-second evaluation SLA. The shipped client uses a **20-second** `URLRequest.timeoutInterval`. With retries, wall-clock wait can exceed 30s. Treat “30s” as an unverified external framing, not a coded invariant.

Flash denial path:

- Status → `REJECTED`, `denialCount = min(prior+1, 3)`.
- At denialCount &lt; 3: retry Flash allowed.
- At denialCount == 3: Flash retry locked (`appealLocked`); UI shows “READY FOR PRO ARBITRATION”.

### 4.5 Gate 3b — Gemini Pro human-in-the-loop appeal

```
User opens appeal sheet → enters justification → sanitizeAppeal
  → auditStatus APPEALED → gemini-2.5-pro generateContent
  → APPROVED (≥0.7) → ARBITRATED_APPROVED + mint
  → REJECTED → SEALED_REJECTED (no further appeal / Flash)
```

Human-in-the-loop properties verified:

- Appeal blocked until exactly three Flash rejections.
- Empty / fully-stripped statement → `appealStatementEmpty`.
- UI requires non-empty editor text before “SUBMIT TO GEMINI PRO”.
- Transient Pro failures leave `APPEALED` + `canRetryAudit` (Slice7 adversarial).

### 4.6 Credit minting on approval

- Rate: same as focus — 0.5c / 30 continuous minutes (`MeetingCreditMinting` → `FocusMinting.baseCredits`).
- Daily `EARNED_MEETING` cap: **4.0** (anti-spam; not in PRODUCT text but enforced).
- Idempotent `meeting:<uuid>` reference.
- Meetings **15–29 minutes** can be APPROVED with **0 credits** (below half-credit chunk) — intentional per Slice7 test.

Habit/meeting credits both feed midnight streak math via `countsAsDailyEarned`.

### 4.7 Schema drift (meetings)

| SPEC §3 | Implementation | Notes |
| :--- | :--- | :--- |
| `punch_out_time TEXT NOT NULL` | Nullable until punch-out | Correct for in-progress rows |
| Statuses include `APPEAL_APPROVED` | `ARBITRATED_APPROVED` | Rename |
| Minimal columns | Extra: monotonic/uptime, denial, appeal, purge, audit attempt fields | Superset |

---

## 5. Cross-Cutting Concerns

### 5.1 Shared time-travel / clocks

Meetings and habits share the app’s single `TimeTravelGuard`. Habit completes and meeting punch/submit/audit all call `ensureEconomyWritable` / observe skew. Rolling habit window uses continuous monotonic seconds from governance/engine clocks.

### 5.2 Focus mutex

Punch-in concludes an active digital focus session so the same elapsed wall time cannot mint as both focus and meeting (`bindFocusEngine` / `beginOfflineMeeting`).

### 5.3 Keychain / API auth (SPEC §2.3)

| Spec | Code |
| :--- | :--- |
| Service `com.mavoid.zoidlockin.gemini` | `ZoidLockInKeychain.geminiService` — **match** |
| Header `x-goog-api-key` only | Set on request; no `?key=` — **match** |
| Dev fallback | `GEMINI_API_KEY` env after Keychain |

### 5.4 PRODUCT §3 / SPEC §2.5–§2.6 intersection

| Touchpoint | Finding |
| :--- | :--- |
| Enforcement daemon / NE | No habit or meeting credit path depends on them |
| SyncManager / iCloud | Meeting/habit state is local SQLite; not synced to mobile shield in this revision |
| Process scan 1.5s (SPEC §2.5) | Unrelated constant; do not confuse with habit 1.5c cap |

---

## 6. Test Evidence Map (not executed this pass)

| Area | Primary tests |
| :--- | :--- |
| Habit frequency + 1.5 ceiling + clip + civil reset | `Slice8MicroHabitsTests` |
| TZ hop / rolling window bypass | `Slice8AdversarialHardeningTests` |
| Local triple-gate, EXIF, purge | `Slice6OfflineMeetingTests`, `Slice6AdversarialHardeningTests` |
| Flash / Pro / appeal / seal / mint | `Slice7GeminiAuditTests`, `Slice7AdversarialHardeningTests` |
| Victory streak increment / reset | `ExchangeEngineTests` (“victory streak increments across two target days…”) |

---

## 7. Findings

### F1 — Citation / section mismatch in audit brief  
**Severity:** Informational · **Confidence:** High  
Requested PRODUCT §3/§3.5 and SPEC §2.5/§2.6 are enforcement/sync, not habits/meetings. Audit executed against PRODUCT §2.3–§2.4 / §5.2 and SPEC §2.3 + schema + Slices 6–8.

### F2 — Gemini request timeout is 20s, not 30s  
**Severity:** Low (spec silence) · **Confidence:** High  
`GeminiAuditPolicy.requestTimeout = 20`. No PRODUCT/SPEC 30-second Flash evaluation requirement found. If product intent is a hard 30s UX budget, document it and align timeout/retries; if “30s” meant 30-minute credit chunks, no code change needed.

### F3 — Victory streak omits “amenities paid” clause  
**Severity:** Medium (product semantics) · **Confidence:** High  
PRODUCT §5.2: target met = baseline amenities paid + zero deficit. Code: `earned >= 3.0`. Micro-habit (and meeting) credits can push streak without bed purchase. Recommend clarifying PRODUCT or adding spend checks.

### F4 — SPEC DDL / vocabulary drift  
**Severity:** Low (docs) · **Confidence:** High  
`EARNED_MICRO` vs `EARNED_HABIT`; `micro_habit_logs` vs `micro_habit_completions`; `APPEAL_APPROVED` vs `ARBITRATED_APPROVED`; column renames. Behavior is coherent; SPEC §3 should be updated to the live schema.

### F5 — Representative habit catalog not seeded  
**Severity:** Low · **Confidence:** High  
PRODUCT table is illustrative; empty DB until user/admin creates habits. Acceptable for “Customization Engine,” but onboarding may want a one-time seed of the four catalog rows.

### F6 — Approved meetings under 30 minutes mint 0 credits  
**Severity:** Informational · **Confidence:** High  
Aligned with half-credit chunking; can surprise users after a successful Flash approve of a 15–29m session.

---

## 8. Lifecycle Verdict Matrices

### 8.1 Micro-Habits

| Stage | Result |
| :--- | :--- |
| Create / edit (2FA + 48h lock) | **PASS** |
| Complete → frequency gate | **PASS** |
| Complete → 1.5c daily cap (+ rolling anti-TZ) | **PASS** |
| Ledger `EARNED_HABIT` | **PASS** |
| Contributes to midnight streak earned total | **PASS** |
| Streak increment semantics vs full PRODUCT §5.2 | **PARTIAL** (earned-only) |

### 8.2 Offline Meeting Triple-Gate

| Stage | Result |
| :--- | :--- |
| Punch-in / punch-out | **PASS** |
| Triple artifacts + EXIF | **PASS** |
| Submit → Flash auto-audit | **PASS** |
| Flash timeout / SLA “30s” | **UNSPECIFIED** (code: 20s) |
| 3 rejections → Pro appeal UI | **PASS** |
| Pro approve mint / Pro reject seal | **PASS** |
| 30-day purge | **PASS** |

---

## 9. Residual Risk & Exclusions

**Excluded from this pass:** Live Gemini API calls, Keychain contents, runtime UI screenshots, execution of XCTest suites, remediation patches.

**Residual risk:** Production Gemini latency/availability can leave meetings in `PENDING`/`APPEALED` with retry UX (covered by tests for 429 paths). Rolling habit window depends on `habitWindow` injection — production wires it; unit engines without `habitWindow` only enforce civil-day ledger half of the dual cap.

---

## 10. Completion Evidence

| Item | Value |
| :--- | :--- |
| Revision | `a5dfed0adb467546e42e9387ade9ccc0aa6add71` |
| Report path | `.audit/wave3_e2e_habits_meetings.md` |
| Tools | Read-only source inspection, ripgrep, prior wave audit format |
| Tests run | None (evidence-cited only) |
| Source changes | None (report artifact only) |

**Bottom line:** Micro-Habits and Offline Meeting Triple-Gate E2E lifecycles **match PRODUCT §2.3–§2.4 intent and SPEC Slice 6–8 / §2.3 Gemini rules**, with documented streak-semantics nuance, schema vocabulary drift, and Flash timeout = 20s (not a coded 30s evaluation window).
