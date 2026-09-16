# Wave 4 — Economic Edge-Case Remediation Audit

**Date:** 2026-09-16  
**Revision:** `5339d481635ae3945da2f3fe4297e3b1e809e7f1`  
**Mode:** Read-only product/code audit (no source changes)  
**Scope:** `SQLiteEconomicLedger`, `ExchangeEngine` midnight rollover (`reconcileLocked` / `reconcileIfNeededLocked`), and PRODUCT.md **§5.2** (with cross-cuts §2.2 Work Debt Priority, §2.5 Friday Rest, §5.3 Deficit Strikes, §7.2 Emergency Debt)  
**Prior art:** `.audit/wave2_balances_debt_audit.md` (W2-01…W2-05); Wave 3 focus/habits notes on streak simplification  

---

## 1. Executive Verdict

Wave-2 arithmetic for surplus vaulting, −1.0 deficit strikes, −2.0 emergency levies, and Friday deficit-skip remains **correct**. Wave-4 edge review finds that **PRODUCT §5.2 Victory Streak eligibility is still under-implemented**, **morning-momentum × carried-debt is net-correct but not end-of-block-gated**, **Friday rest transitions are solid with a few soft edges**, and **lifetime vault permanence is application-enforced only** (mutable single-row `UPDATE`).

| Concern | Verdict | Confidence |
| :--- | :--- | :--- |
| Victory streak: earned ≥ 3.0 | **PASS** | High |
| Victory streak: **zero outstanding deficit** (PRODUCT §5.2) | **FAIL** — increments with end-of-day negative wallet and after same-night emergency −2.0 | High |
| Victory streak: **baseline amenities paid** (PRODUCT §5.2) | **FAIL** — no spend/amenity gate | High |
| Debt repayment priority × Morning Momentum (§2.2) | **PASS (equivalent net)** / **PARTIAL (timing)** — signed wallet nets correctly; mid-block spend possible once balance ≥ 0 before complete | High |
| Friday rest mode transition edges (§2.5) | **PASS** with soft edges (streak pause; carried debt not cleared; `.rest` free) | High |
| Permanent lifetime vault durability (§5.2) | **PASS (behavior)** / **FAIL (schema permanence)** — reconcile only adds surplus; row is freely `UPDATE`able | High |
| Wave-2 remediation status | **Open** — W2-01 / W2-02 / W2-03 **not fixed** at this revision | High |

**Overall:** Ready for production on **balances and debt math**; not yet remediated against full **§5.2 streak wording** or **vault immutability**.

---

## 2. Product Rules Under Test

### 2.1 PRODUCT §5.2 — Midnight Expiration & Reconciliation

> At **23:59:59**, the active daily wallet balance is reconciled to **0.0**.  
> Surplus unspent credits are logged into a permanent **Lifetime Surplus Vault**.  
> Finishing the day with the daily target met (**all baseline amenities paid** and **zero deficit**) increments the consecutive **Victory Streak**.

### 2.2 Adjacent rules that bind the same rollover

| Section | Rule | Engine touchpoint |
| :--- | :--- | :--- |
| §2.2 | Morning 2.0× first; then subtract carried −1.0 / −2.0 debt | Progressive `.mint` + `applyMorningMomentumIfNeededLocked`; `CreditMath.spendable` |
| §2.5 | Friday: basics 0 cost; no deficit evaluation | `LocalCivilClock.isFriday` + `AmenityCatalog.cost` + reconcile `!friday` gate |
| §5.3 | Non-rest under 3.0 earned → Deficit Strike + next morning −1.0 | `reconcileLocked` penalty branch |
| §7.2 | Emergency → next-day −2.0 | Unlevied incidents levied **after** streak/deficit branch at close |

---

## 3. Midnight Rollover Control Flow (as implemented)

`tick` / `purchaseAmenity` / `reconcileIfNeeded` → `reconcileIfNeededLocked` closes every civil day from first unreconciled through **yesterday**. Each day runs `reconcileLocked` inside `ledger.performAtomically`:

1. **`finalizeOpenSessionLocked`** — complete same-day live focus at `23:59:59`; mint unpaid; apply morning momentum if qualified.  
2. **Aggregate** day txs: `earned` (`countsAsDailyEarned`: mint / EARNED_MEETING / EARNED_HABIT), `spent` (spend − refund).  
3. **Surplus / zero close**  
   - `balance > 0` → `.surplusTransfer` to 0, `vault.totalSurplusCredits += swept`  
   - `balance == 0` → `.reset` amount 0  
   - `balance < 0` → **no close row**; negative debt carries silently  
4. **Streak / deficit**  
   - `!friday && earned < 3.0` → streak **0**, append −1.0 `.penalty` (`deficit:<day>`)  
   - `else if earned >= 3.0` → `currentStreak += 1`, bump `highestStreak`  
   - else (Friday + earned &lt; 3.0) → **neither** reset nor increment  
5. **Emergency levies** — every unlevied incident → −2.0 `.penalty` (incident UUID), mark levied.  
6. **`insertReconciliation` + `saveVault`**.

Close wall time: `LocalCivilClock.date(fromDayKey:day, hour:23, minute:59, second:59)`. Catch-up after multi-day absence is covered by `Slice3AdversarialHardeningTests.multiDayCatchUp`.

---

## 4. Victory Streak Increments (PRODUCT §5.2)

### 4.1 Implemented predicate

```747:750:Sources/ZoidLockInCore/Economy/ExchangeEngine.swift
            } else if earned >= FocusMinting.dailyTargetCredits {
                vault.currentStreak += 1
                vault.highestStreak = max(vault.highestStreak, vault.currentStreak)
            }
```

Only **`earned >= FocusMinting.dailyTargetCredits` (3.0)** gates a streak increment. Deficit days force `currentStreak = 0`. Friday under-target **preserves** the prior streak (see §6).

### 4.2 Requirement: zero outstanding deficit — **FAIL**

| Edge | Expected (PRODUCT §5.2) | Actual | Evidence |
| :--- | :--- | :--- | :--- |
| Earn ≥ 3.0, surplus swept to 0, no emergency | Increment; end wallet 0 | **Match** | `midnightSurplusAndStreak` |
| Earn ≥ 3.0, same-night emergency −2.0 | **No** increment (outstanding deficit) | **Increments, then** wallet −2.0 | `emergencyIncidentNetting` expects `victoryStreakCount == 1` with balance −2.0 |
| Earn ≥ 3.0, end-of-day wallet still &lt; 0 (opening debt not fully repaid / overspend) | **No** increment | **Increments** — negative path skips reset; streak branch ignores `balance` | Code path `balance < 0` + `earned >= 3` |
| Earn ≥ 3.0 after paying down −1.0 to positive surplus | Increment OK | **Match** (net model) | Arithmetic only; no dedicated test |
| Under-target non-Friday | Reset streak | **Match** | `deficitStrike`, `streakProgression` companion |

**Root cause:** Streak is decided **before** emergency levies and **without reading** signed end-of-day balance (or “would-be deficit after levy”). PRODUCT’s “zero deficit” is not a code predicate.

**Finding W4-01 (Medium, confirmed):** Victory streak can increment while outstanding signed debt remains (same-night emergency or unrepaid carry).

### 4.3 Requirement: baseline amenities paid — **FAIL**

PRODUCT requires **all baseline amenities paid**. Catalog baselines for living comfort are bed (3.0), food (2.5), phone (1.5); §2.5 names bed / food / phone as Friday basics. Reconcile never inspects `.spend` rows or `referenceID` amenity kinds.

| Check | Implemented? |
| :--- | :--- |
| `earned >= 3.0` | Yes |
| At least `.bed` purchased that civil day | **No** |
| Bed + food + phone all purchased | **No** |
| Spend ≥ intrinsic baseline basket | **No** |

Tests encode the simplified rule: `midnightSurplusAndStreak` / `streakProgression` never purchase bed.

**Finding W4-02 (Medium, confirmed):** Streak ignores “amenities paid.” Remediations: gate on required `AmenityKind` spends for the day, **or** amend PRODUCT §5.2 to “earned ≥ 3.0 target” only (matches current tests).

### 4.4 Wave-2 carry-forward

| Prior ID | Status at `5339d48` |
| :--- | :--- |
| **W2-01** Victory streak under-implements amenity / zero-deficit | **Still open** (= W4-01 + W4-02) |

---

## 5. Debt Repayment Priority with Morning Momentum (PRODUCT §2.2)

### 5.1 Model

Debt is **not** a separate `active_debt` column. Carried −1.0 / −2.0 lives as the signed daily wallet (`latestBalance`). Amenities use `CreditMath.spendable = max(0, balance)`, so negative balance cannot buy until repaid by mints.

Morning Momentum (`applyMorningMomentumIfNeededLocked`):

1. Progressive `.mint` each 30 continuous minutes into the live wallet.  
2. On complete (or midnight finalize), if first ≥90m block with start **and** end hour &lt; 12: append a second `.mint` equal to current `session.creditsEarned` (“Morning Momentum 2.0×”), doubling session yield.

### 5.2 Net equivalence vs PRODUCT wording

PRODUCT: multiply morning block to **3.0**, **then** subtract debt at end of block.

| Opening debt | 90m morning complete | Final balance | PRODUCT narrative |
| :--- | :--- | :--- | :--- |
| 0 | +3.0 | 3.0 | Match |
| −1.0 | +3.0 | **2.0** | 3.0 − 1.0 |
| −2.0 | +3.0 | **1.0** | 3.0 − 2.0 |

**Verdict: PASS on final net** when the morning block completes without intervening spends.

### 5.3 Timing edge — mid-block spend while “repaying”

Mints hit the wallet **during** the session, not only at completion. Momentum bonus applies only at complete/finalize.

| Edge | Behavior | Risk |
| :--- | :--- | :--- |
| Open −1.0; work 60m before noon | Balance 0.0; spendable 0 | Cannot buy yet |
| Open −1.0; work 90m **before** `completeFocus` | Balance **+0.5** (base 1.5 − 1.0); spendable 0.5 **before** 2.0× bonus | Can buy `.rest` (0.5) **before** momentum posts; final net ≠ “3.0 then subtract” |
| Open −2.0; work 90m before complete | Balance −0.5; spendable 0 | Safe until complete (+1.5 → 1.0) |
| Open −2.0; work 120m+ before complete | Balance ≥ 0 before momentum | Same early-spend window |

**Finding W4-03 (Low, confirmed):** Continuous mid-session netting can diverge from “subtract debt at end of block” if the user spends after crossing 0 but before morning complete. Same as open **W2-02**.

### 5.4 Test gap

No harness asserts `open −1 → morning 90m → balance 2.0` or `open −2 → balance 1.0`. Pieces exist separately (`morningMomentumVersusAfternoon`, `deficitStrike`, `emergencyIncidentNetting`).

**Finding W4-04 (Info):** Add momentum×debt integration tests (was W2-04).

---

## 6. Friday Rest Mode Transition Edges (PRODUCT §2.5)

### 6.1 Core enforcement — **PASS**

| Rule | Mechanism | Status |
| :--- | :--- | :--- |
| Hardcoded Friday | `LocalCivilClock.isFriday` → weekday == 6 | PASS |
| Not admin-toggleable | No governance flag flips rest | PASS |
| Basics 0 cost | `AmenityCatalog.cost(..., fridayRestMode:)` short-circuits before overrides | PASS |
| No deficit strike | `if !friday && earned < 3.0` | PASS (`fridayRestMode` test) |
| Premium still paid | `.outing` / streaming / gaming unchanged | PASS |

### 6.2 Transition edge matrix

| Edge | Observed behavior | Product fit |
| :--- | :--- | :--- |
| Thu → Fri 00:00 | Next purchase uses `isFriday(now)`; costs flip without reconcile | Correct |
| Fri → Sat 00:00 | Saturday normal prices; under-target → deficit | Correct (`multiDayCatchUp`) |
| Multi-day catch-up spanning Friday | Fri `fridayRestMode=true`, no strike; Sat/Sun strike; vault keeps Thu surplus | Correct |
| Friday with **carried −1.0** from Thursday | Basics free; wallet stays negative; Friday does **not** clear debt | Allowed (PRODUCT only skips *new* deficit evaluation) |
| Friday earned &lt; 3.0 | Streak **neither** reset nor incremented (pause) | Soft / unspecified — reasonable anti-burnout reading |
| Friday earned ≥ 3.0 | Streak **increments** (still no amenity gate) | Inherits W4-01/02 |
| Friday + curfew (22:00–03:59) | Food/phone still **curfew-blocked** even at 0 cost | Intentional layering |
| `.rest` free on Friday | `isBasicComfort` includes `.rest` | Soft extension of “baseline” (W2-05) |

**Finding W4-05 (Info):** Document Friday streak-pause and “carried debt survives rest day” as intentional, or add PRODUCT language.

**Finding W4-06 (Info):** `.rest` at 0 on Friday remains an intentional catalog extension (W2-05).

### 6.3 Rollover interaction

`isFriday(dayKey:)` evaluates noon on that day key — stable for catch-up. Open Friday focus finalized at Fri 23:59:59 still sees Friday rest for any mid-finalize purchases; deficit skip uses the reconciled day’s Friday flag, not “now.”

---

## 7. Permanent Lifetime Vault Durability (PRODUCT §5.2)

### 7.1 Behavioral permanence — **PASS**

Production mutation path is solely `ExchangeEngine.reconcileLocked`:

```705:718:Sources/ZoidLockInCore/Economy/ExchangeEngine.swift
            if balance > 0 {
                swept = balance
                balance = 0
                try ledger.appendTransaction(
                    WalletTransaction(
                        timestamp: closeTime,
                        amount: -swept,
                        balanceAfter: 0,
                        transactionType: .surplusTransfer,
                        referenceID: day,
                        description: "Midnight surplus sweep \(day)"
                    )
                )
                vault.totalSurplusCredits = CreditMath.normalize(vault.totalSurplusCredits + swept)
```

- Surplus only **increases** via `+= swept` on reconcile.  
- Each sweep is journaled append-only on `wallet_transactions` (`.surplusTransfer`).  
- Under-target positive crumbs still vault **before** −1.0 penalty (`deficitStrike` expects `sweptToVault == 0.5`).  
- Multi-day: `multiDayCatchUp` keeps `totalSurplusCredits == 3.0` after weekend deficits.

File ledger hardening: directory `0700`, db file `0600`, WAL (`EconomicLedgerTests.fileLedgerWALAndVault`).

### 7.2 Schema permanence — **FAIL / soft**

```384:394:Sources/ZoidLockInEconomy/SQLiteEconomicLedger.swift
            CREATE TABLE IF NOT EXISTS lifetime_vault (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                total_surplus_credits REAL NOT NULL DEFAULT 0.0,
                current_streak INTEGER NOT NULL DEFAULT 0,
                highest_streak INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        try database.execute(
            "INSERT OR IGNORE INTO lifetime_vault (id, total_surplus_credits, current_streak, highest_streak) VALUES (1, 0, 0, 0);"
```

| Property | wallet_transactions / daily_reconciliations | lifetime_vault |
| :--- | :--- | :--- |
| BEFORE UPDATE/DELETE abort triggers | Yes (tested) | **No** |
| `saveVault` | N/A | Unrestricted `UPDATE` of surplus **and** streaks |
| Non-decreasing surplus CHECK/trigger | N/A | **Absent** |
| Append-only surplus journal table | Sweep txs only | Snapshot row only |

`saveVault` is a public ledger API; dashboard tests write vault rows directly (`Slice9DesktopDashboardTests.vaultAndStreakAssemble`). Any caller (or raw SQL) can decrease `total_surplus_credits` or rewrite streaks without touching the append-only wallet.

**Finding W4-07 (Low, confirmed):** Lifetime vault is not schema-durable; permanence is application convention only (**W2-03** still open).

**Remediation options (recommended order):**

1. SQL `BEFORE UPDATE` trigger: abort if `NEW.total_surplus_credits < OLD.total_surplus_credits`.  
2. Optional: abort decreases to `highest_streak`; allow `current_streak` resets (deficit path).  
3. Stronger: append-only `vault_surplus_entries(day, amount)` and derive totals; keep snapshot as cache.  
4. Narrow `saveVault` to package-internal / reconcile-only if API surface allows.

---

## 8. Additional Rollover / Ledger Edges

| Edge | Behavior | Severity |
| :--- | :--- | :--- |
| Reconcile runs on first tick **after** local midnight, not exactly 23:59:59 | Close txs stamped 23:59:59 of closed day | Info — matches “at midnight” product intent |
| `balance < 0` at close writes no `.reset` | Debt carries by leaving last `balance_after` | OK |
| Deficit + emergency same night | −1 then −2 → −3 when under-target | OK arithmetically; streak already 0 |
| Target met + emergency | Streak++ then −2 | **W4-01** |
| Idempotent re-reconcile | `alreadyReconciled` / `reconcileIfNeeded` no-op | PASS |
| Emergency double-levy | `leviedIncidentIDs` ∪ `markLevied` | PASS |
| InMemory `latestBalance` = last append; SQLite = `timestamp DESC, rowid DESC` | Same-timestamp close chain OK if append order preserved | Low residual |
| Nested `performAtomically` (engine inside ledger) | SQLite uses recursive lock + BEGIN IMMEDIATE | Covered by double-spend test |

---

## 9. Test Evidence Matrix

| Test | Asserts | § mapping | Gap vs full §5.2 |
| :--- | :--- | :--- | :--- |
| `midnightSurplusAndStreak` | Sweep 3.0; streak 1; wallet 0 | §5.2 earned/vault | No amenity / deficit checks |
| `streakProgression` | 1 → 2 across target days | §5.2 earned-only | Same |
| `deficitStrike` | −1.0; streak 0; vault +0.5 crumb | §5.3 | — |
| `emergencyIncidentNetting` | −2.0; streak **1**; idempotent | §7.2 | **Contradicts** zero-deficit streak rule |
| `fridayRestMode` | 0-cost basics; no deficit | §2.5 | — |
| `multiDayCatchUp` | Fri rest + weekend deficits; vault durable | §2.5 / §5.2 vault | Streak pause implicit |
| `morningMomentumVersusAfternoon` | 3.0 vs 1.5 | §2.2 reward | No opening debt |
| `EconomicLedgerTests.appendOnlyTriggers` | Wallet/recon immutable | Ledger | **Vault not covered** |
| *(missing)* | Morning × −1 / −2 net balances | §2.2 priority | **W4-04** |
| *(missing)* | Streak blocked if no bed / if balance &lt; 0 / if emergency | §5.2 full | **W4-01/02** |
| *(missing)* | `UPDATE lifetime_vault` decreasing surplus rejected | Vault permanence | **W4-07** |

Static coverage review only; suite not re-executed in this audit pass.

---

## 10. Findings Summary (Wave 4)

| ID | Severity | Title | Status vs Wave 2 | Recommended action |
| :--- | :--- | :--- | :--- | :--- |
| **W4-01** | Medium | Streak increments with outstanding deficit / same-night emergency | Open (**W2-01** partial) | Require `balance >= 0` after surplus close **and** defer streak until after emergency levies (or require no −2.0 levy that night) |
| **W4-02** | Medium | Streak ignores baseline amenities paid | Open (**W2-01** partial) | Gate on required amenity spends **or** amend PRODUCT §5.2 to earned-only |
| **W4-03** | Low | Mid-block spend before morning complete vs end-of-block debt subtract | Open (**W2-02**) | Optional: hold spendable at 0 while morning-qualifying session open and opening balance &lt; 0; or accept net equivalence and document |
| **W4-04** | Info | No momentum×debt integration tests | Open (**W2-04**) | Add −1→2.0 and −2→1.0 harness cases |
| **W4-05** | Info | Friday streak pause + carried debt survival undocumented | New soft edge | PRODUCT note or code comment |
| **W4-06** | Info | Friday zeros `.rest` | Open (**W2-05**) | Document intentional |
| **W4-07** | Low | `lifetime_vault` mutable; no non-decreasing surplus trigger | Open (**W2-03**) | Trigger / journal as in §7.2 |

No confirmed off-by-one in −1.0 / −2.0 magnitudes, Friday deficit skip, surplus `+=`, or morning 2.0× qualification math.

---

## 11. Proposed Remediation Batches

### Batch A — PRODUCT §5.2 streak fidelity (priority)

1. Decide product intent: **earned-only** vs **earned + amenities + zero deficit**.  
2. If full wording:  
   - After surplus/zero close and emergency levies, increment streak only if `earned >= 3.0` **and** final `balance >= 0` **and** no deficit strike **and** (chosen) baseline spends present.  
   - Update `emergencyIncidentNetting` expectations if streak must stay flat when −2.0 levies.  
3. If earned-only: amend PRODUCT §5.2 and close W4-01/02 as documentation.

### Batch B — Momentum × debt coverage

1. Tests: opening −1.0 / −2.0 + morning 90m → 2.0 / 1.0.  
2. Optional hardening for W4-03 early-spend window.

### Batch C — Vault durability

1. Non-decreasing `total_surplus_credits` trigger (+ tests via `executeUncheckedSQL`).  
2. Optionally restrict streak fields or add surplus journal.

Keep security/governance and UI copy (e.g. dashboard “21:00” vault caption from Wave 1) in separate batches.

---

## 12. Completion Evidence

| Item | Detail |
| :--- | :--- |
| **Scope** | SQLiteEconomicLedger vault/schema; ExchangeEngine reconcile, momentum, Friday, streak; PRODUCT §5.2 + §2.2/§2.5/§5.3/§7.2 cross-cuts |
| **Excluded** | Daemon enforcement, 2FA governance, offline meeting Gemini path, micro-habit cap internals (except earned contribution to streak total), UI chrome |
| **Revision** | `5339d481635ae3945da2f3fe4297e3b1e809e7f1` |
| **Methods** | Source read of `ExchangeEngine.swift`, `SQLiteEconomicLedger.swift`, `FocusMinting.swift`, `AmenityCatalog.swift`, `EconomicRecords.swift`, `LocalCivilClock.swift`, PRODUCT.md; test/grep cross-check; Wave 2/3 audit diff for remediation status |
| **Confirmed findings** | W4-01, W4-02, W4-03, W4-07 |
| **Info / soft** | W4-04, W4-05, W4-06 |
| **Remediated since Wave 2** | **None** of W2-01…W2-03 |
| **Residual risk** | Streak inflation without bed purchase or with overnight debt; rare pre-complete morning spend-in-debt; vault surplus decrease via non-reconcile `saveVault` or SQL |

---

## 13. Bottom Line

`ExchangeEngine` + `SQLiteEconomicLedger` still implement a coherent midnight economy: wallet → 0 (or carried negative debt), surplus into the lifetime vault, Friday without deficit strikes, and morning 2.0× yields that **net** against signed debt. Wave-4 remediation focus is unchanged from Wave 2’s core gaps: **encode full PRODUCT §5.2 streak gates (zero deficit + baseline amenities) or rewrite the product rule**, **prove momentum×debt with tests (and optionally end-of-block spend gating)**, and **harden `lifetime_vault` so “permanent” is enforced by SQLite, not convention.**
