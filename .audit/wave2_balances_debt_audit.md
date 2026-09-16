# Wave 2 Balances & Debt Audit Report

**Audit date:** 2026-09-16  
**Repository revision:** `a5dfed0adb467546e42e9387ade9ccc0aa6add71` (`main`)  
**Scope (read-only):** `PRODUCT.md` §2.5 (Permanent Friday Rest) and §5 (Curfew, Expiration & The Permanent Vault), plus debt/momentum cross-cuts from §2.2 Work Debt Priority and §7.2 emergency −2.0 as levied by midnight reconciliation.  
**Primary subjects:** `SQLiteEconomicLedger`, `ExchangeEngine.reconcileLocked` / mint path, `FocusMinting`, `AmenityCatalog`, `LifetimeVaultRecord`, `PendingDebtRecord`.  
**Method:** Source-level mathematical and product-rule verification against constants, transaction ordering, SQLite DDL, and deterministic tests under `Tests/ZoidLockInTests/`. Tests were **not executed** in this pass (`swift test --filter ExchangeEngineTests` failed to compile: `no such module 'Testing'` in this environment). Assertions below cite written test expectations as design evidence only.

---

## 1. Executive Verdict

| Area | Verdict | Confidence |
| :--- | :--- | :--- |
| **Deficit strike −1.0c (PRODUCT §5.3)** | **PASS** — `FocusMinting.deficitStrikeCredits = -1.0`; levied as `.penalty` after surplus sweep | High |
| **Emergency debt −2.0c (PRODUCT §7.2 via §5 close)** | **PASS** — `PendingDebtRecord.emergencyPenaltyCredits = -2.0`; one levy per unlevied incident | High |
| **Morning momentum pays debt after 2.0× (PRODUCT §2.2)** | **PASS (equivalent model)** — signed wallet nets mints into negative balance; final net matches “3.0 then subtract debt” when the morning block completes without mid-session spends | High |
| **Friday rest: 0 amenity cost for basics (PRODUCT §2.5)** | **PASS** — hardcoded `LocalCivilClock.isFriday`; bed/food/phone/(rest) → 0 | High |
| **Friday rest: no deficit strike (PRODUCT §2.5)** | **PASS** — `!friday && earned < 3.0` gate | High |
| **Midnight wallet → 0.0 then vault (PRODUCT §5.2)** | **PASS** — positive balance swept via `.surplusTransfer`; vault accumulates additively | High |
| **Permanent lifetime surplus vault** | **PASS with soft permanence** — reconcile only *adds* surplus; `lifetime_vault` row is mutable UPDATE (no append-only trigger) | High |
| **Victory streak (PRODUCT §5.2)** | **PARTIAL** — increments on `earned ≥ 3.0` only; does **not** require baseline amenities paid or end-of-day zero deficit (emergency can leave −2.0 the same night) | High |

**Overall Wave-2 balances/debt core:** **mathematically aligned** with PRODUCT deficit (−1.0), emergency (−2.0), Friday rest, midnight reset, and lifetime vault accumulation. Debt is modeled as a **signed daily wallet** (no `active_debt` column). Material product drifts are victory-streak eligibility wording and continuous mid-session debt netting vs “subtract at end of block.”

---

## 2. Sources of Truth Mapped

### 2.1 PRODUCT requirements in scope

| ID | Requirement (condensed) | Primary implementation | Status |
| :--- | :--- | :--- | :--- |
| P2.5a | Every Friday is rest day | `LocalCivilClock.isFriday` (Gregorian weekday == 6) | **PASS** |
| P2.5b | Cannot edit / reschedule / toggle off (incl. admin) | No admin/governance flag for Friday; weekday check only | **PASS** |
| P2.5c | Baseline amenities 0 cost (bed, food, phone) | `AmenityCatalog.cost(..., fridayRestMode:)` + `isBasicComfort` | **PASS** (+ `.rest` also free) |
| P2.5d | No end-of-day deficit penalties on Friday | `reconcileLocked` skips deficit when `friday` | **PASS** |
| P2.2f | Morning 2.0× first, then debt subtracted | Signed balance + morning bonus mint on complete | **PASS (equiv.)** |
| P5.1 | 22:00 curfew locks entertainment/food purchases | `isCurfew` + `isBlockedByCurfew` in `purchaseAmenity` | **PASS** (adjacent) |
| P5.2a | At 23:59:59 wallet reconciled to 0.0 | `closeTimestamp` hour 23/59/59; surplus → 0 | **PASS** |
| P5.2b | Surplus → permanent Lifetime Surplus Vault | `vault.totalSurplusCredits += swept` + `saveVault` | **PASS** |
| P5.2c | Victory streak when target met (amenities paid, zero deficit) | Streak on `earned ≥ 3.0` only | **PARTIAL** |
| P5.3a | Deficit strike if non-rest day earnings &lt; 3.0 baseline | `earned < FocusMinting.dailyTargetCredits` | **PASS** |
| P5.3b | Next morning −1.0 disciplinary debt | `.penalty` amount −1.0 after close | **PASS** |
| P5.3c | 1 hour work to return to 0.0 before amenities | `CreditMath.spendable = max(0, balance)`; 1.0c/hr mint rate | **PASS** |
| P7.2 | Emergency next-day −2.0 (2-hour debt) | Unlevied incidents → −2.0 `.penalty` at reconcile | **PASS** |

### 2.2 Key constants

| Constant | Value | Location |
| :--- | ---: | :--- |
| `FocusMinting.dailyTargetCredits` | **3.0** | `FocusMinting.swift` |
| `FocusMinting.deficitStrikeCredits` | **−1.0** | `FocusMinting.swift` |
| `PendingDebtRecord.emergencyPenaltyCredits` | **−2.0** | `PendingDebtStore.swift` |
| Morning block | 5400s → base 1.5 × 2.0 = **3.0** | `FocusMinting` + `applyMorningMomentumIfNeededLocked` |
| Bed amenity (baseline comfort) | **3.0** | `AmenityCatalog.intrinsicCost` |

---

## 3. Debt Model: Signed Wallet (Not a Separate Debt Column)

There is **no** `active_debt` field. Disciplinary and emergency debts are ordinary `.penalty` rows that drive `wallet_transactions.balance_after` negative. Spend gates use:

```swift
CreditMath.spendable(balance) // max(0, normalize(balance))
```

| Concept | Implementation |
| :--- | :--- |
| Carry-over deficit | Balance opens next civil day at −1.0 (or more if stacked) |
| Carry-over emergency | Balance opens at −2.0 per levied incident |
| Repayment | Positive `.mint` / `.earnedMeeting` / `.earnedHabit` add into the signed balance until ≥ 0 |
| Amenities | Debit only against `spendable` (≥ 0) |

**SQLite evidence** (`SQLiteEconomicLedger.installSchema`):

- `wallet_transactions` — append-only (UPDATE/DELETE triggers abort).
- `daily_reconciliations` — append-only; stores `deficit_strike_applied`, `friday_rest_mode`, `swept_to_vault`.
- `lifetime_vault` — single-row `id = 1`; **mutable UPDATE** via `saveVault` (no append-only trigger).

Nested writes during reconciliation are safe: `SQLiteDatabase.beginImmediate` uses `transactionDepth` so `reconcileLocked` → `appendTransaction` → nested `performAtomically` shares one `BEGIN IMMEDIATE`.

---

## 4. Mathematical Correctness: Deficit (−1.0) & Emergency (−2.0)

### 4.1 Midnight ordering (`ExchangeEngine.reconcileLocked`)

Atomic close sequence for local day `D` at timestamp `D 23:59:59`:

1. Finalize any open same-day focus session (mint unpaid + morning momentum if qualified).
2. Compute `earned` = sum of txs with `countsAsDailyEarned` (`.mint`, `.earnedMeeting`, `.earnedHabit`).
3. Compute net `spent` = spend − refund.
4. **If `balance > 0`:** append `.surplusTransfer` of `−balance`, set balance 0, add `swept` to vault.  
   **Else if `balance == 0`:** append `.reset` of 0.  
   **Else (`balance < 0`):** leave negative balance in place (no reset row).
5. **Deficit:** if `!friday && earned < 3.0` → streak = 0, append `.penalty` amount **−1.0**, `referenceID = "deficit:D"`.  
   Else if `earned ≥ 3.0` → `currentStreak += 1`, update `highestStreak`.
6. **Emergency:** for each unlevied incident → append `.penalty` amount **−2.0**, mark levied.
7. Insert `DailyReconciliationRecord`, `saveVault`.

### 4.2 Worked examples (engine math)

| Scenario | Pre-close balance | Earned | Friday? | Post-close balance | Vault Δ | Notes |
| :--- | ---: | ---: | :---: | ---: | ---: | :--- |
| Target met, unspent 3.0 | 3.0 | 3.0 | N | 0.0 | +3.0 | Streak +1 |
| Under-target 0.5 | 0.5 | 0.5 | N | **−1.0** | +0.5 | Sweep then −1.0 (test: `deficitStrike`) |
| Target met + 1 emergency | 3.0 | 3.0 | N | **−2.0** | +3.0 | Streak +1 *then* −2.0 (test: `emergencyIncidentNetting`) |
| Under-target + 1 emergency | 0.5 | 0.5 | N | **−3.0** | +0.5 | −1.0 then −2.0 stack |
| Friday, earn 0 | 0 | 0 | Y | 0.0 | 0 | No deficit (test: `fridayRestMode`) |
| Prior −1 unpaid, earn 0.5 | −0.5 | 0.5 | N | **−1.5** | 0 | Prior remainder + new −1.0 |

**Verdict:** −1.0 and −2.0 magnitudes and levy sites match PRODUCT. Stacking unpaid prior debt with a new deficit strike is coherent economically (PRODUCT does not forbid it); next-morning balance is “at least −1.0,” not always exactly −1.0.

### 4.3 Repayment constraint (§5.3 / §7.2)

- Deficit −1.0 requires **1.0 credit** of verified earnings → **1 hour** at 1.0c/hr.  
- Emergency −2.0 requires **2.0 credits** → **2 hours**.  
- Until balance ≥ 0, `spendable` stays 0 → amenities cannot be bought.  

Matches PRODUCT repayment language.

---

## 5. Morning Momentum Priority Over Debt (PRODUCT §2.2)

### 5.1 Spec rule

> If carried-over deficit (−1.0) or emergency (−2.0) exists, morning earnings multiply first to 3.0, **then** debt is subtracted at end of block, releasing remaining net credits.

### 5.2 Implementation

1. Base milestones mint into the signed wallet during the session (`mintUnpaidLocked`).
2. On `completeFocus` / midnight finalize, `applyMorningMomentumIfNeededLocked` mints an **additional** `.mint` equal to current `session.creditsEarned` (description `"Morning Momentum 2.0×"`), doubling session yield.
3. Debt is **not** a deferred end-of-block clawback; it is already present as a negative opening balance.

**Equivalence for a clean 90-minute morning completion (no mid-session purchases):**

| Opening debt | Base mint | Momentum bonus | Final balance | PRODUCT net (3.0 − debt) |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 1.5 | 1.5 | 3.0 | 3.0 |
| −1.0 | 1.5 | 1.5 | **2.0** | 2.0 |
| −2.0 | 1.5 | 1.5 | **1.0** | 1.0 |
| −3.0 (−1 & −2) | 1.5 | 1.5 | **0.0** | 0.0 |

**Verdict: PASS (mathematically equivalent)** for the PRODUCT example path.

### 5.3 Nuance / residual risk

Debt nets **continuously**. After ~60 minutes into a morning session with −1.0 opening debt, balance reaches 0 and further base mints become spendable **before** completion-time momentum. `purchaseAmenity` does not block while focus is active. A mid-session purchase could spend credits that PRODUCT’s “subtract debt at end of block” wording would still treat as reserved. Final completed-block net without mid-session spends remains correct.

**Coverage gap:** no dedicated `ExchangeEngine` test seeds −1.0/−2.0 then asserts morning completion nets to 2.0/1.0.

---

## 6. Friday Rest Enforcement (PRODUCT §2.5)

### 6.1 Hardcoded cadence

```swift
// LocalCivilClock.swift
public func isFriday(_ date: Date) -> Bool {
    calendar.component(.weekday, from: date) == 6  // Foundation: Sunday=1 … Friday=6
}
```

No governance/admin setting, price override, or feature flag disables Friday rest. Amenity **price** overrides cannot grant a non-Friday rest day or cancel Friday zero-cost basics when `fridayRestMode` is true (`cost` short-circuits to 0 before `standardCost`).

### 6.2 Zero amenity costs

`AmenityCatalog.isBasicComfort`: `.bed`, `.food`, `.phone`, `.rest` → **0** on Friday.  
Still charged: `.streaming`, `.gaming`, `.outing` (outing remains 5.0 — covered by `fridayRestMode` test).

PRODUCT lists bed / food delivery / personal phone. Code also zeros **`.rest`** (extra leniency; not a violation).

Purchase path:

```swift
let friday = civilClock.isFriday(now)
let cost = catalogStorage.cost(of: kind, fridayRestMode: friday)
```

### 6.3 No deficit strike

```swift
if !friday && earned < FocusMinting.dailyTargetCredits {
    // apply −1.0, reset streak
} else if earned >= FocusMinting.dailyTargetCredits {
    // increment streak
}
```

Friday with `earned == 0`: no deficit, wallet stays 0 — matches test `fridayRestMode`.  
Emergency −2.0 levies are **outside** the Friday guard (PRODUCT §2.5 only exempts deficit penalties; §7.2 has no Friday carve-out) — **PASS**.

### 6.4 Streak behavior on Friday (informational)

If Friday earnings &lt; 3.0, streak is neither incremented nor reset. Streak can “bridge” across Friday. PRODUCT says work targets are relaxed; this is a reasonable reading, not a deficit bug.

---

## 7. Permanent Lifetime Surplus Vault (PRODUCT §5.2)

### 7.1 Accumulation path

On positive close balance:

```swift
swept = balance
balance = 0
// .surplusTransfer −swept
vault.totalSurplusCredits = CreditMath.normalize(vault.totalSurplusCredits + swept)
```

- Wallet returns to **0.0** for the next civil day (axiom: zero-baseline), modulo later deficit/emergency penalties on the same close.
- Vault total is **monotonic non-decreasing** along the only production write path (`reconcileLocked`).
- Dashboard reads `loadVault().totalSurplusCredits` / `MenuBarTickerSnapshot.lifetimeSurplus`.

### 7.2 Permanence assessment

| Property | Status |
| :--- | :--- |
| Surplus survives daily wallet reset | **PASS** |
| Multi-day additive accumulation | **PASS** (`+= swept`) |
| Wallet txs recording each sweep | **PASS** (`.surplusTransfer`, `referenceID = day`) |
| SQLite append-only protection on vault row | **FAIL / soft** — `UPDATE lifetime_vault` allowed; no trigger prevents decreasing `total_surplus_credits` |
| Production callers of `saveVault` besides reconcile | Only `ExchangeEngine.reconcileLocked` (+ test seams) |

**Verdict: PASS for product behavior**; permanence is **application-enforced**, not schema-enforced.

### 7.3 Deficit-day vaulting

Under-target days with unspent positive balance still sweep to vault **before** the −1.0 penalty (test expects `sweptToVault == 0.5` and balance −1.0). PRODUCT §5.2 allows banking unspent surplus; §5.3 debt is a separate next-morning init. Intentional and tested.

---

## 8. Victory Streak Drift (PRODUCT §5.2)

PRODUCT: finish with daily target met (**all baseline amenities paid** and **zero deficit**) → increment Victory Streak.

Code:

```swift
} else if earned >= FocusMinting.dailyTargetCredits {
    vault.currentStreak += 1
    vault.highestStreak = max(vault.highestStreak, vault.currentStreak)
}
```

| Check | Implemented? |
| :--- | :--- |
| `earned ≥ 3.0` | Yes |
| Bed / baseline amenities purchased that day | **No** |
| End-of-day balance free of deficit *before* emergency | Partially (surplus path zeros wallet before penalties) |
| Emergency −2.0 same night still “zero deficit” | **No** — test `emergencyIncidentNetting` expects streak 1 with wallet −2.0 |

**Finding W2-01 (Medium):** Victory streak under-implements PRODUCT §5.2 amenity-paid / zero-deficit clauses.

---

## 9. SQLiteEconomicLedger Responsibilities (Balances/Debt Surface)

| Concern | Mechanism | Verdict |
| :--- | :--- | :--- |
| Durable signed balance | Last `balance_after` by timestamp/rowid | **PASS** |
| Append-only wallet + reconciliations | BEFORE UPDATE/DELETE triggers → `.appendOnly` | **PASS** |
| Reconciliation uniqueness | `date` PRIMARY KEY / duplicate → `.duplicateReconciliation` | **PASS** |
| Vault + streak snapshot | `lifetime_vault` id=1 | **PASS** (mutable) |
| Deficit history API | `deficitStrikeRecords()` filters `deficitStrikeApplied` | **PASS** |
| Levied emergency detection | `.penalty` `referenceID` set ∩ incident UUIDs | **PASS** (deficit refs use `deficit:YYYY-MM-DD`, no collision) |
| WAL on disk | `PRAGMA journal_mode = WAL` | **PASS** (ledger tests) |

`InMemoryEconomicLedger` mirrors the same protocol for engine unit tests; SQLite parity covered by `sqliteBackedMorningBlock`.

---

## 10. Test Evidence Matrix

| Test | Asserts | Maps to |
| :--- | :--- | :--- |
| `midnightSurplusAndStreak` | Sweep 3.0 → vault; streak 1; wallet 0 | §5.2 |
| `deficitStrike` | earned 0.5 → strike; vault +0.5; wallet −1.0 | §5.3 |
| `emergencyIncidentNetting` | wallet −2.0; idempotent re-reconcile | §7.2 / §5 close |
| `fridayRestMode` | food/bed/phone free; outing blocked; no deficit | §2.5 |
| `streakProgression` | streak 1 → 2 across target days | §5.2 (earned-only) |
| `morningMomentumVersusAfternoon` | 3.0 vs 1.5 (no debt) | §2.2 reward |
| `curfewBlocksPurchases` | 22:00 blocks food/streaming; bed ok | §5.1 |
| *(missing)* | Morning block with opening −1.0 / −2.0 | §2.2 debt priority |
| *(missing)* | Streak requires bed purchase | §5.2 full wording |

**Execution note:** `swift test --filter ExchangeEngineTests` did not run here (`import Testing` unavailable). Treat the table as static coverage evidence.

---

## 11. Findings Summary

| ID | Severity | Title | Evidence | Recommended action |
| :--- | :--- | :--- | :--- | :--- |
| **W2-01** | Medium | Victory streak ignores “amenities paid” and “zero deficit” | `reconcileLocked` earned-only branch; emergency test keeps streak with −2.0 | Gate streak on bed (or baseline set) paid + no deficit/emergency penalties that night, **or** amend PRODUCT §5.2 to match earned-only rule |
| **W2-02** | Low | Continuous debt netting vs end-of-block subtraction | Mid-session mint + unrestricted `purchaseAmenity` | Optionally defer spendable until morning block completes when opening debt &lt; 0; add harness test |
| **W2-03** | Low | Lifetime vault row not append-only | `saveVault` UPDATE; no SQL trigger | Add CHECK/trigger that `total_surplus_credits` is non-decreasing, or append-only surplus journal |
| **W2-04** | Info | No integration test for momentum×debt | Tests cover pieces separately | Add cases: open −1 → morning 90m → balance 2.0; open −2 → balance 1.0 |
| **W2-05** | Info | Friday also zeros `.rest` | `isBasicComfort` | Document as intentional extension of §2.5 basics |

No confirmed arithmetic bugs in −1.0 deficit, −2.0 emergency, Friday deficit skip, or vault `+= swept` accumulation.

---

## 12. Completion Evidence

| Item | Detail |
| :--- | :--- |
| **Scope** | PRODUCT §2.5, §5 (with §2.2 debt priority + §7.2 emergency levy as reconciliation inputs) |
| **Excluded** | Offline meeting minting, micro-habit caps, daemon enforcement, admin 2FA, UI copy (except vault permanence data path) |
| **Revision** | `a5dfed0adb467546e42e9387ade9ccc0aa6add71` |
| **Tools** | Source read/grep; `git rev-parse`; attempted `swift test --filter ExchangeEngineTests` (compile fail: missing `Testing` module) |
| **Confirmed findings** | W2-01 (streak eligibility), W2-02 (timing nuance), W2-03 (vault mutability) |
| **Unconfirmed / leads** | None material beyond listed info items |
| **Residual risk** | Streak inflation without buying bed; rare mid-morning spend-while-in-debt; vault decrease only via non-reconcile `saveVault` or raw SQL |

---

## 13. Bottom Line

`ExchangeEngine` + `SQLiteEconomicLedger` correctly implement the **balances and debt arithmetic** PRODUCT requires for Wave 2: midnight close to 0 with surplus vaulted, −1.0 deficit strikes on non-Friday under-target days, −2.0 emergency levies, Friday zero-cost basics with no deficit strike, and morning 2.0× yields that net against carried debt equivalently to “multiply then subtract.” Tighten victory-streak eligibility and add momentum×debt tests to close the remaining product/coverage gaps.
