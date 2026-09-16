# Wave 2 Time-Travel / Clock Logic Audit

**Audit date:** 2026-09-16  
**Repository revision:** `a5dfed0adb467546e42e9387ade9ccc0aa6add71`  
**Commit under review:** `a5dfed0` — *feat(ui): add native Focus work session tab in menu bar and fix reboot tamper lock*  
**Scope (read-only):** `TimeTravelGuard`, `CalibrationCoordinator`, `ExchangeEngine` clock paths; supporting `BootSession`, `MachContinuousTimeClock` / `MachUptimeClock`, `LocalCivilClock`, shared wiring in `ZoidLockInApp`, and adjacent consumers (`GovernanceLockCoordinator`, offline meetings).  
**Method:** Source-level architectural review, git history of the `bootSessionUUID` tamper-marking removal, cross-check against SPEC §2.1 anti-time-travel intent, and scenario analysis for quit/relaunch, OS reboot, sleep, NTP, and timezone change. Tests cited as evidence only (not executed in this pass).  
**Artifact convention:** Written to `.audit/wave2_timetravel_audit.md` per request; no source, config, or Git state modified beyond this report.

---

## 1. Executive Verdict

| Question | Verdict | Confidence |
| :--- | :--- | :--- |
| **`bootSessionUUID` tamper-marking removal is correct** | **PASS** — reboot identity change must not sticky-lock the economy | High |
| **120s wall↔monotonic skew constraint is enforced** | **PASS** — `abs(skew) > 120` sticky-locks writes | High |
| **Timezone change does not false-positive TT lock** | **PASS** — TT uses absolute `Date`; civil TZ is pinned | High |
| **Normal app quit/relaunch never false-locks** | **PASS** (honest clocks) — same-boot origin restore + skew≈0 | High |
| **OS reboot never false-locks** | **PASS after `a5dfed0`** — boot UUID change skips origin restore and no longer calls `markTampered()` | High |
| **SPEC NTP ±120s baseline** | **GAP** — local wall↔mono only; no remote NTP client / incident log | High |
| **Regression tests for reboot false-positive** | **GAP** — no calibration/economy test asserts “reboot ≠ tamper” | Medium |

**Overall:** After `a5dfed0`, the TimeTravel / Calibration / Exchange clock architecture correctly separates **boot-session identity** (expected to change on reboot) from **wall↔monotonic divergence** (the only legitimate sticky tamper signal). Normal quit/relaunch and OS reboot should **not** trigger false-positive clock locks when `kern.bootsessionuuid` is available and wall/monotonic clocks remain honest within 120 seconds of each other.

---

## 2. Architecture Map

### 2.1 Component roles

```
┌──────────────────────────────────────────────────────────────────┐
│ ZoidLockInApp (single shared TimeTravelGuard)                    │
│   ├─ GovernanceLockCoordinator  (restore origin iff same boot)   │
│   ├─ ExchangeEngine             (observe + gate credit writes)   │
│   ├─ CalibrationCoordinator     (restore / accrue / sticky bit)  │
│   └─ OfflineSessionCoordinator  (observe + gate punch in/out)    │
└──────────────────────────────────────────────────────────────────┘
                │                           │
                ▼                           ▼
     MachContinuousTimeClock        SystemWallClock (Date)
     (CLOCK_MONOTONIC)              absolute UTC-based instant
                │
                └──────────► TimeTravelGuard.observe(wall, mono)
                               skew = Δwall − Δmono
                               lock iff abs(skew) > 120
```

| Type | Clock inputs | Tamper effect |
| :--- | :--- | :--- |
| `TimeTravelGuard` | Wall `Date` + continuous monotonic seconds | Sticky `tampered`; `ensureWritable()` throws |
| `CalibrationCoordinator` | Same TT guard + sealed `isTampered` bit | Soft-mode switches to monotonic backstop; persists sticky bit |
| `ExchangeEngine` | TT via `clock` (continuous); focus via `focusClock` (uptime) | Blocks mint/spend/reconcile/focus writes; UI still snapshots |
| `LocalCivilClock` | Pinned `TimeZone` (from governance) | Day keys, curfew, Friday, calibration civil days — **not** TT |

### 2.2 Shared guard wiring (production)

`MenuBarEconomyController.init` constructs **one** `TimeTravelGuard` and injects it into governance, exchange, calibration, and offline meetings (`Sources/ZoidLockInApp/ZoidLockInApp.swift`). That sharing is load-bearing:

1. On reboot, governance and calibration **both** refuse to restore a pre-reboot monotonic origin when boot UUID mismatches.
2. ExchangeEngine itself does **not** store `bootSessionUUID`; it inherits correct reboot behavior only because the shared guard’s origin is left unset until the first post-boot `observe()`.

### 2.3 Dual monotonic clocks in `ExchangeEngine`

| Purpose | Implementation | Sleep behavior |
| :--- | :--- | :--- |
| Anti-time-travel baseline | `MachContinuousTimeClock` (`CLOCK_MONOTONIC`) | Continues during sleep |
| Focus elapsed / minting | `MachUptimeClock` (`CLOCK_UPTIME_RAW`) | Pauses during sleep |

This split is intentional: sleep must not look like wall/mono divergence (continuous tracks wall through lid-close), and focus credits must not farm while asleep.

---

## 3. Deep Dive: `TimeTravelGuard`

**File:** `Sources/ZoidLockInCore/Economy/TimeTravelGuard.swift`

### 3.1 Skew math

On first observation (or after a cold start with no restored origin):

- Stores `originWall`, `originMonotonic`
- Returns skew `0`

On subsequent observations:

```
wallDelta = nowWall − originWall
monoDelta = nowMono − originMonotonic
skew      = wallDelta − monoDelta
```

If `abs(skew) > TimeTravelGuard.maxSkewSeconds` (`120`), sets sticky `tampered = true`.

### 3.2 Tolerance semantics

| Skew | Result |
| ---: | :--- |
| `\|skew\| ≤ 120` | Allowed (inclusive boundary) |
| `\|skew\| > 120` | Sticky lock |

Both forward jumps (wall ahead of mono) and backward jumps (wall behind mono) are covered via `abs`.

### 3.3 Persistence seams

| API | Behavior |
| :--- | :--- |
| `restoreOriginIfNeeded(wall:monotonic:)` | Sets origin **once** if unset; used after quit/relaunch **same boot** |
| `markTampered()` | Forces sticky bit; **never clears** |
| `ensureWritable()` | Throws `TimeTravelError.clockTampered` when sticky |

Once locked, there is no auto-heal path in-process or across relaunch except replacing the guard instance **and** clearing persisted `CalibrationState.isTampered` (sealed). Sticky-by-design.

### 3.4 What TT does *not* measure

- Absolute correctness vs UTC/NTP (SPEC gap).
- Timezone identifier changes (irrelevant to `Date` instants).
- Boot identity (callers must gate origin restore themselves).

---

## 4. Deep Dive: Recent Fix — Removing `bootSessionUUID` Tamper Marking

### 4.1 Bug (pre-`a5dfed0`)

Commit `e117be1` (slice-9 HMAC hardening) treated a boot-session UUID mismatch as clock tamper in **three** places inside `CalibrationCoordinator`:

1. `restoreTimeTravelOrigin()` — `timeTravel.markTampered()` on UUID mismatch  
2. `loadOrStartLocked` — `existing.isTampered = true` + `markTampered()`  
3. `accrueLocked` — `next.isTampered = true` + `markTampered()`

`kern.bootsessionuuid` **always** changes across a true OS reboot while monotonic counters reset. Equating that identity change with wall↔mono skew produced a **guaranteed false-positive sticky lock** after every reboot (shared guard → ExchangeEngine purchases/mints also fail-closed).

### 4.2 Fix (`a5dfed0`, CalibrationCoordinator only)

Removed all three `markTampered` / `isTampered = true` assignments on boot UUID mismatch. Retained:

| Path | Post-fix behavior |
| :--- | :--- |
| `restoreTimeTravelOrigin` | On UUID mismatch: **return without restoring origin** (and without marking tamper). Still re-applies sticky bit if `state.isTampered` was already true. |
| `loadOrStartLocked` | On UUID mismatch: rewrite `bootSessionUUID`, refresh `lastObserved*` to now; **do not** set tamper. |
| `accrueLocked` | On UUID mismatch: rewrite boot + lastObserved and **return without accruing** (prevents bogus mono deltas across reboot). |

### 4.3 Why this is architecturally correct

Boot UUID is an **epoch boundary** for monotonic samples, not evidence of wall-clock fraud.

Correct reboot sequence with shared guard:

1. Governance restore: `lastObservedBootSessionUUID != current` → skip origin restore.  
2. Calibration restore: persisted `bootSessionUUID != current` → skip origin restore; **no** `markTampered()`.  
3. First `observe()` (engine tick / calibration snapshot) establishes a **fresh** origin at post-boot wall+mono.  
4. Skew starts at 0; economy remains writable.

True prior tamper still survives reboot because `state.isTampered` is restored via `markTampered()` **before** the boot UUID guard return.

### 4.4 Residual concern from the same commit

The fix landed in a UI-focused commit without a dedicated regression test asserting:

> “Calibration / Exchange remain non-tampered across boot UUID change with honest wall/mono.”

Governance already has a related but **different** test (`rebootAndWallAdvanceFailClosed`) that asserts cooldown cannot be expired by reboot+wall jump — it does **not** assert TT stays clean on reboot alone.

---

## 5. `CalibrationCoordinator` Clock Logic

**File:** `Sources/ZoidLockInCore/Economy/CalibrationCoordinator.swift`

### 5.1 Soft → hard transition

| Condition | Trusted wall | Untrusted / tampered |
| :--- | :--- | :--- |
| Complete soft window | `nowWall ≥ transitionToHardAt` **or** accrued mono ≥ 72h | **Only** accrued mono ≥ 72h |
| Remaining seconds | Wall delta to `transitionToHardAt` | `72h − accruedMonotonic` |
| Day 1–3 phase | Civil midnights via pinned `LocalCivilClock` | Floored mono / 24h (capped at day 3) |

`transitionToHardAt` is computed once at first launch as local midnight + 3 civil days (`softCivilDays`). It is an absolute `Date`, so later OS timezone changes do not slide the hard-lock instant.

### 5.2 Accrual across boot

After the fix, reboot does **not** add a huge (or negative) mono delta:

- `loadOrStartLocked` rewrites `lastObservedMonotonic` to current before accrue when UUID changed, **or**
- `accrueLocked` short-circuits on UUID mismatch.

Either way, accrued soft-mode progress is preserved in `accruedMonotonicElapsed` without inventing elapsed time from reset counters.

### 5.3 Fail-closed integrity path

Missing/corrupt/HMAC-mismatched calibration still calls `failClosedSnapshotLocked` → `markTampered()` + hard lockdown. That is integrity fail-closed, not a reboot false positive.

### 5.4 Interaction with shared TT

Calibration evaluation always `observe`s before accrue. If ExchangeEngine already locked the shared guard, calibration will persist `isTampered = true` on the sealed row — sticky across future launches. Conversely, calibration-detected skew locks the shared guard for the economy.

---

## 6. `ExchangeEngine` Clock Logic

**File:** `Sources/ZoidLockInCore/Economy/ExchangeEngine.swift`

### 6.1 Write gate

Almost all mutating entry points call `observeClocksLocked()` → `timeTravel.observe` + `ensureWritableLocked()`, mapping `TimeTravelError` → `ExchangeEngineError.clockTampered`.

Covered surfaces include: focus start/complete/tick sync, amenity purchase/refund, daily reconcile, meeting/habit mints, `ensureEconomyWritable()`.

### 6.2 Read / UI path

`snapshot()` observes skew (so the sticky bit can latch) but does **not** throw — menu bar can still render `"Clock Tamper"` via `isClockTampered` / `dayStateCaption`.

### 6.3 Civil-time features vs TT

Curfew, Friday rest, morning momentum noon cutoff, and reconciliation day keys use `LocalCivilClock` with the **pinned** timezone from governance. Those rules are orthogonal to TT:

- Manipulating System Settings timezone does not, by itself, trip `TimeTravelGuard`.
- Advancing the wall clock without mono advance **does** trip TT (tested in `ExchangeEngineTests.antiTimeTravel`).

### 6.4 No boot UUID of its own

`ExchangeEngine` trusts the injected guard’s lifecycle. Production safety depends on app wiring sharing one guard and on calibration/governance refusing to restore cross-boot origins. A future refactor that gives ExchangeEngine a private guard **and** restores stale mono samples without a boot check would reintroduce reboot false positives.

---

## 7. Scenario Matrix (False-Positive Analysis)

| Scenario | Expected product behavior | Mechanism | False-positive lock? |
| :--- | :--- | :--- | :--- |
| **App quit → relaunch, same boot, honest clocks** | Economy writable | Same boot UUID → restore lastObserved as TT origin → skew≈0 | **No** |
| **App quit for many hours, same boot, honest clocks** | Writable | Wall and continuous mono advance together while quit | **No** |
| **OS sleep / lid close** | Writable; focus pauses | TT uses continuous (sleep-aware); focus uses uptime | **No** |
| **OS reboot, honest clocks** | Writable; soft calibration continues via accrued mono | UUID mismatch → no origin restore, no `markTampered`; fresh origin | **No (fixed in `a5dfed0`)** |
| **Wall jump >120s vs mono (manual or large step)** | Sticky lock | `abs(skew) > 120` | **No — true positive** |
| **Wall jump ≤120s** | Writable | Inclusive tolerance | **No** |
| **OS timezone change (Settings)** | No TT lock; civil day keys stay on pinned TZ | `Date` absolute; `LocalCivilClock` pinned at launch via governance | **No TT false lock** |
| **Timezone hop to farm a second civil day budget** | Blocked elsewhere | Habit rolling mono window + pinned TZ (Slice 8 tests) | N/A to TT |
| **NTP/step correction >120s while app quit** | Sticky lock on relaunch | Same math as wall jump | **Possible true/false depending on ops** — by local-skew policy |
| **`kern.bootsessionuuid` unavailable → `"unknown"` on consecutive boots** | Risk | Same UUID string → may restore pre-reboot mono origin → large skew | **Residual risk** (see finding TT-R1) |
| **Prior true tamper then reboot** | Stay locked | `state.isTampered` → `markTampered()` before UUID return | Intended |

---

## 8. Timezone Change Behavior (Detailed)

1. **`TimeTravelGuard`:** Compares absolute instants. Changing `TimeZone.current` does not alter `Date.timeIntervalSince` deltas. **No TT latch from TZ alone.**

2. **Pinned civil timezone:** `GovernanceLockCoordinator.ensurePinnedTimeZone()` persists `pinnedTimeZoneIdentifier` on first successful state write. App passes `habitGovernance.pinnedTimeZone` into `ExchangeEngine` and `CalibrationCoordinator`. Mid-flight OS TZ changes do not rebind those calendars until process restart **and** only if the pinned identifier is absent/unreadable (otherwise the stored pin wins).

3. **Calibration civil days:** Soft day phase uses pinned `civilDaysElapsed`. Hard deadline uses the absolute `transitionToHardAt` captured at start. Traveling across zones cannot shorten the sealed deadline via TT; it also cannot extend it by TZ games once pinned.

4. **User-visible nuance (not a TT bug):** After an OS TZ change, UI day captions / curfew may disagree with the user’s new local clock until/unless product policy repins — but that is civil-semantics drift, not a false Clock Tamper lock.

---

## 9. Findings

### TT-1 — Reboot false-positive from boot UUID tamper marking (FIXED)

- **Severity:** Critical (pre-fix) / Informational (post-fix)  
- **Confidence:** High  
- **Evidence:** `git show a5dfed0` removes `markTampered()` / `isTampered = true` from three CalibrationCoordinator boot-mismatch paths.  
- **Impact (before):** Every OS reboot sticky-locked calibration + shared economy writes.  
- **Status:** Remediated in `a5dfed0`.  
- **Verification:** Manual reboot smoke + recommended automated test (TT-T1 below).

### TT-2 — 120s skew gate is correctly absolute and sticky

- **Severity:** Informational (positive control)  
- **Confidence:** High  
- **Evidence:** `TimeTravelGuard.observe` lines using `abs(skew) > maxSkewSeconds`; `ExchangeEngineTests.antiTimeTravel` advances wall by 3h without mono and expects `clockTampered`.  
- **Impact:** Matches the local half of SPEC’s “more than 120 seconds” lock intent.

### TT-3 — SPEC remote NTP baseline missing

- **Severity:** Medium (spec drift / defense-in-depth gap)  
- **Confidence:** High  
- **Evidence:** SPEC §2.1 requires authenticated remote NTP at startup and Clock Tamper Incident logging; implementation is local wall↔`CLOCK_MONOTONIC` only (`TimeTravelGuard`, `MachContinuousTimeClock`). Wave 1 economy audit already flagged this.  
- **Impact:** A user who moves **both** wall and a hypothetical mono-unrelated source cannot be caught by NTP; conversely, large legitimate NTP steps can look identical to tamper.  
- **Recommended action:** Either implement NTP anchor + incident record, or amend SPEC to the implemented local-skew model.

### TT-4 — No automated regression that reboot ≠ calibration/economy tamper

- **Severity:** Medium (test gap)  
- **Confidence:** High  
- **Evidence:** Slice 9 tests cover integrity fail-closed and seals; Slice 6 covers meeting `bootSessionChanged`; Slice 8 covers governance reboot+wall fail-closed; **none** assert `CalibrationCoordinator` / `ExchangeEngine.isClockTampered == false` after boot UUID rotation with lockstep clocks.  
- **Recommended action:** Add TT-T1 (below).

### TT-R1 — `BootSession.currentUUID()` fallback `"unknown"`

- **Severity:** Low–Medium (residual)  
- **Confidence:** Medium  
- **Evidence:** `BootSession.currentUUID()` returns `"unknown"` when `sysctlbyname("kern.bootsessionuuid")` fails. Two boots both yielding `"unknown"` would look like same-boot relaunch and restore a stale mono origin → likely `abs(skew) > 120`.  
- **Preconditions:** sysctl failure on Darwin (unusual on healthy macOS).  
- **Recommended action:** Treat `"unknown"` as non-restorable (skip origin restore; optionally treat as reboot boundary).

### TT-R2 — Large NTP step while quit can lock honestly

- **Severity:** Low (policy tradeoff)  
- **Confidence:** High  
- **Evidence:** Same-boot origin restore + 120s absolute threshold.  
- **Impact:** Rare multi-minute NTP corrections during quit/relaunch latch sticky tamper until sealed state is cleared. Acceptable if product wants fail-closed; document for support.

### TT-OK1 — Quit/relaunch path is sound

- **Severity:** Informational  
- **Confidence:** High  
- **Evidence:** Same-boot restore of `lastObservedWall` / `lastObservedMonotonic`; skew measures subsequent divergence only. Honest lockstep advance yields ~0 skew indefinitely.

### TT-OK2 — Timezone change does not false-lock TT

- **Severity:** Informational  
- **Confidence:** High  
- **Evidence:** Absolute `Date` skew math; pinned `LocalCivilClock` for civil rules.

---

## 10. Recommended Verification / Tests

### TT-T1 — Calibration reboot does not sticky-tamper (missing)

Pseudocode intent:

1. Start `CalibrationCoordinator` with boot `"A"`, lockstep wall/mono; take snapshot (day1, not tampered).  
2. Construct a **new** coordinator on the same store with boot `"B"`, mono reset near 0, wall advanced only by real elapsed (or identical wall if testing pure UUID change).  
3. Expect: `timeTravel.isTampered == false`, `state.isTampered == false`, phase still soft, accrued mono preserved (not zeroed, not exploded).  
4. Share a `TimeTravelGuard` with an `ExchangeEngine` and expect `purchase` / `tick` still writable.

### TT-T2 — Boundary at exactly 120s

Assert `skew == 120` stays writable; `120 + ε` locks.

### TT-T3 — `"unknown"` boot UUID does not restore origin

Force `bootSessionUUID: "unknown"` across two coordinator lifetimes with discontinuous mono samples; expect no restore / no false lock (after implementing TT-R1 hardening).

### Manual smoke (post-`a5dfed0`)

1. Launch app, confirm economy writable.  
2. Quit app normally → relaunch → confirm no Clock Tamper.  
3. Reboot Mac → relaunch → confirm no Clock Tamper; calibration day progresses via accrued mono.  
4. Set system clock +3 hours → confirm sticky Clock Tamper on next tick/purchase.  
5. Change System Settings timezone only → confirm no Clock Tamper.

---

## 11. Comparison to SPEC §2.1

| SPEC requirement | Implementation | Status |
| :--- | :--- | :--- |
| Do not trust raw mutable local time alone | Wall compared to monotonic baseline | **PASS** |
| Hardware monotonic for elapsed | `CLOCK_MONOTONIC` for TT / continuous; uptime for focus | **PASS** (naming: SPEC says `mach_absolute_time`; code uses `clock_gettime_nsec_np`) |
| Authenticated remote NTP at startup | Absent | **FAIL / GAP** |
| Lock credit transactions if skew > 120s | `ExchangeEngine` write gate | **PASS** (local skew, not NTP) |
| Log Clock Tamper Incident | Menu caption / errors only; no dedicated incident record found in this pass | **PARTIAL / GAP** |

---

## 12. Remediation Batches (Proposed Only — Not Applied)

### Batch A — Regression hardening (product correctness)

1. Add TT-T1 reboot≠tamper test for Calibration + shared ExchangeEngine.  
2. Harden `BootSession` / origin restore when UUID is `"unknown"` (TT-R1).  
3. Optional: TT-T2 inclusive boundary test.

### Batch B — Spec alignment (separate from A)

1. Decide: implement NTP anchor + Clock Tamper incident, **or** update SPEC §2.1 / Slice 3 notes to document local wall↔mono policy.  
2. If NTP is added, keep boot UUID **out** of the tamper bit (do not regress `a5dfed0`).

### Batch C — Do **not** mix

Integrity fail-closed (`CalibrationIntegrity`), governance cooldown, and offline-meeting `bootSessionChanged` are separate concerns. Do not reintroduce boot UUID → `isTampered` coupling.

---

## 13. Completion Evidence

| Item | Value |
| :--- | :--- |
| Scope | TimeTravelGuard, CalibrationCoordinator, ExchangeEngine (+ BootSession, civil/monotonic clocks, app wiring, adjacent restore sites) |
| Exclusions | Full NTP product design; daemon pass expiry beyond boot UUID comments; mobile shield timestamp skew (`EncryptedStateStore` uses one-sided `skew > 120` for incoming cloud timestamps — related constant, different semantics) |
| Revision | `a5dfed0adb467546e42e9387ade9ccc0aa6add71` |
| Primary fix reviewed | Removal of bootSessionUUID → `markTampered` / `isTampered` in CalibrationCoordinator |
| Tools | `git log` / `git show` / `git blame`, repository Grep/Read (read-only) |
| Tests executed | None in this pass |
| Confirmed critical bug | Pre-fix reboot false lock — **fixed** |
| Residual risks | `"unknown"` boot UUID; large NTP steps; missing reboot regression test; SPEC NTP gap |
| Source changes | **None** (report artifact only) |

---

## 14. Bottom Line

**`a5dfed0` correctly fixes the reboot false-positive** by stopping CalibrationCoordinator from treating `bootSessionUUID` changes as clock tamper, while still refusing to restore cross-boot monotonic origins. **`TimeTravelGuard`’s 120-second absolute wall↔monotonic skew gate is properly constrained** (`abs(skew) > 120`, sticky). **Timezone changes do not trip the guard.** With honest clocks and a working `kern.bootsessionuuid`, **normal quit/relaunch and OS reboots should never sticky-lock** the shared economy. Remaining gaps are SPEC NTP absence, missing automated reboot regression coverage, and the `"unknown"` boot UUID fallback edge case.
