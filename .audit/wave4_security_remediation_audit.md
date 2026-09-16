# Wave 4 Security Remediation — Gap-Closing Verification Report

**Audit date:** 2026-09-16  
**Repository revision (committed HEAD):** `5339d481635ae3945da2f3fe4297e3b1e809e7f1` (`main`)  
**Working tree under review:** HEAD **plus uncommitted** edits to:

| Path | Diff role |
| :--- | :--- |
| `Sources/ZoidLockInCore/Security/PasswordHasher.swift` | Adds `validateComplexity` |
| `Sources/ZoidLockInCore/Security/SecurityGatekeeper.swift` | Adds 600s session timeout; hardens TOTP replay to `window <= last` |
| `Sources/ZoidLockInEconomy/CommandDashboardView.swift` | UI complexity hint + enroll button gate |

**Mode:** Read-only gap-closing verification (no remediations, no test execution, no dependency changes)  
**Baseline:** `.audit/wave2_governance_2fa_audit.md` (findings **G2-01**, **G2-09**, **G2-07**, **G2-02**)  
**Primary standards:** `PRODUCT.md` §6 — High-Friction Anti-Cheating Protocol; `SPEC.md` §2.4 — `SecurityGatekeeper`; `SPEC.md` §3.1 — `admin_audit_events`  
**Method:** Source walk of Security / ledger / Settings UI against PRODUCT/SPEC text and Wave 2 recommended verify steps. Tests under `Tests/ZoidLockInTests/` were **read, not executed**.

**Legend:** **CLOSED** = Wave 2 gap remediated to PRODUCT/SPEC intent · **PARTIAL** = remediation present but bypassable, incomplete, or untested · **OPEN** = gap unchanged · **PASS** = was already compliant / remains compliant.

---

## 1. Executive Verdict

| Focus area (user-requested) | Wave 2 baseline | Wave 4 verification | Confidence |
| :--- | :--- | :--- | :--- |
| **Password complexity** (PRODUCT §6.1) | **FAIL** (G2-01) | **PARTIAL** — helper + UI gate added; **domain enroll/`hash` still length-only**; tests still enroll `"twelve chars+"` | High |
| **10-minute admin session expiration** (PRODUCT §6 sequence) | **FAIL** (G2-09) | **PARTIAL** — `sessionTimeoutSeconds = 600` on `isUnlocked` / `requireUnlocked`; **`snapshot()` ignores timeout** (UI can stay UNLOCKED); wall-clock only; **uncommitted**; **no tests** | High |
| **Durable SQLite `admin_audit_events`** (SPEC §3.1) | **OPEN** (G2-07) | **OPEN** — still in-memory `auditEvents` only; table absent from `SQLiteEconomicLedger` DDL | High |
| **TOTP replay defenses** (SPEC §2.4 / RFC 6238 ops) | **PASS** (G2-02) | **PASS (+ hardening)** — Keychain-backed last window remains; working tree rejects `window <= lastUsed` (not just `==`) | High |

**Overall gap-closing status vs Wave 2 Batch A/B security items:** **NOT CLOSED.** Two High findings are only **partially** addressed in an **uncommitted** working tree; durable audit logging is **unchanged OPEN**; TOTP replay remains a **PASS** with a small hardening delta.

**Ship-readiness implication:** Do not treat PRODUCT §6 / SPEC §2.4 security remediation as complete until (1) complexity is enforced in `enroll`/`hash`, (2) session expiry is applied on every unlock observation including `snapshot()`, (3) `admin_audit_events` is created and written, and (4) regression tests cover the three Wave 2 verify recipes.

---

## 2. Scope & Artifacts

### 2.1 Components under verification

| Component | Path | Wave 4 relevance |
| :--- | :--- | :--- |
| `PasswordHasher` | `Sources/ZoidLockInCore/Security/PasswordHasher.swift` | Complexity API |
| `SecurityGatekeeper` | `Sources/ZoidLockInCore/Security/SecurityGatekeeper.swift` | Enroll, unlock, session, audit buffer, TOTP consume |
| `TOTPEngine` / `TOTPReplayWindow` | `Sources/ZoidLockInCore/Security/TOTPEngine.swift` | RFC 6238 + replay struct |
| `CommandDashboardView` | `Sources/ZoidLockInEconomy/CommandDashboardView.swift` | Enrollment UI friction |
| `SQLiteEconomicLedger` | `Sources/ZoidLockInEconomy/SQLiteEconomicLedger.swift` | SPEC §3.1 DDL presence |
| App snapshot wiring | `Sources/ZoidLockInApp/ZoidLockInApp.swift` | `gatekeeper.snapshot()` on tick |

### 2.2 Wave 2 findings in scope

| ID | Title | Expected remediation (Wave 2 §11) |
| :--- | :--- | :--- |
| G2-01 | Password complexity classes not enforced | Enforce upper/lower/digit/symbol in hasher (+ UI) |
| G2-09 | No 10-minute admin unlock timeout | Auto-lock when elapsed ≥ 600s on unlock checks |
| G2-07 | Admin audit not persisted to SQLite | Persist to `admin_audit_events` |
| G2-02 | TOTP / GA verification PASS | Maintain; adversarial replay test remains |

### 2.3 Exclusions

- Verbatim psychological email copy (G2-08) — adjacent PRODUCT §6 item; not in the four requested focus areas  
- Argon2id vs PBKDF2 (G2-10 / SPEC §2.4 wording) — noted as residual SPEC drift only  
- 48-hour governance cooldown (already PASS in Wave 2) — not re-audited in depth  
- Live Resend / Keychain / network calls  

---

## 3. Requirement Matrix (PRODUCT §6 + SPEC §2.4 / §3.1)

| ID | Requirement | Evidence | Wave 4 status |
| :--- | :--- | :--- | :--- |
| P6.1 | Password ≥12 with **uppercase, lowercase, numbers, and symbols** | `validateComplexity` + UI disable; `enroll`/`hash` still `validateLength` only | **PARTIAL** |
| P6.2 | Google Authenticator–compatible TOTP | `TOTPEngine` SHA1 / 30s / 6 digits / otpauth | **PASS** |
| P6.5 | Unlock session with **10-minute timeout** | Working-tree `sessionTimeoutSeconds = 600` on `isUnlocked`; `snapshot()` raw `unlocked` | **PARTIAL** |
| S2.4a | Password auth vs salted hash in secure store | PBKDF2-HMAC-SHA256 in FileSecure/Keychain store (SPEC says Argon2id) | **PASS intent / SPEC drift** |
| S2.4b | RFC 6238 TOTP vs 160-bit secret | Implemented | **PASS** |
| S2.4c | Email on admin auth | `dispatchAlertRecordingFailure` | **PASS** (copy still ≠ PRODUCT verbatim) |
| S3.1 | `admin_audit_events` SQLite table | Not in ledger DDL; memory-only `AdminAuditRecord` | **OPEN** |
| Ops | TOTP replay defense | Keychain last window + `window <= last` (WT) | **PASS** |

---

## 4. Deep Dive A — Password Complexity (G2-01 → PARTIAL)

### 4.1 PRODUCT rule

> Minimum 12 characters requiring uppercase, lowercase, numbers, and symbols.

### 4.2 Remediation present (working tree)

```25:46:Sources/ZoidLockInCore/Security/PasswordHasher.swift
    /// Evaluates password complexity according to PRODUCT.md §6.1:
    /// minimum 12 characters with uppercase, lowercase, numbers, and symbols.
    public static func validateComplexity(_ password: String) -> (isValid: Bool, missing: [String]) {
        var missing: [String] = []
        if password.count < minimumLength {
            missing.append("At least \(minimumLength) characters")
        }
        if !password.contains(where: { $0.isUppercase }) {
            missing.append("Uppercase letter")
        }
        if !password.contains(where: { $0.isLowercase }) {
            missing.append("Lowercase letter")
        }
        if !password.contains(where: { $0.isNumber }) {
            missing.append("Number")
        }
        let symbols = CharacterSet.punctuationCharacters.union(.symbols)
        if password.unicodeScalars.first(where: { symbols.contains($0) }) == nil {
            missing.append("Symbol")
        }
        return (missing.isEmpty, missing)
    }
```

UI (`CommandDashboardView.enrollmentSettings`):

- Placeholder documents upper/lower/number/symbol  
- Live “Requires: …” caption from `validateComplexity`  
- **ENROLL 2FA** disabled unless `validateComplexity(password).isValid`

### 4.3 Gap remaining — security boundary still length-only

| Call site | Calls `validateComplexity`? | Effect |
| :--- | :---: | :--- |
| `PasswordHasher.hash` | **No** — only `validateLength` | Weak passwords hash successfully |
| `SecurityGatekeeper.enroll` | **No** — only `validateLength` → `.passwordTooShort` | Programmatic enroll accepts `"twelve chars+"` |
| `SecurityGatekeeper.verifyPassword` | Length ≥12 + hash verify only | N/A for enrollment policy |
| Dashboard enroll button | **Yes** | Soft UI gate only |
| `MenuBarSession.enrollSettings` | Passes through to `gatekeeper.enroll` | No extra class check |

There is **no** `SecurityGatekeeperError` / `PasswordHashingError` case for missing character classes. Any caller that bypasses the SwiftUI button (tests, future API, alternate UI) can enroll a PRODUCT-noncompliant password.

### 4.4 Wave 2 verify recipe — still fails

Wave 2 §11.C.1: *Reject `"twelve chars+"` / accept a fully complex password.*

Current tests still succeed with the weak password:

| Test | Password used | Implication |
| :--- | :--- | :--- |
| `Slice9DesktopDashboardTests.gatekeeperAndAlertMail` | `"twelve chars+"` | Enroll + unlock succeed |
| `Slice9AdversarialHardeningTests.enrolledTwoFactorBlocksConfigurationMutations` | `"twelve chars+"` | Enroll succeeds |
| `…totpReplayWithinWindowIsRejected` | `"twelve chars+"` | Enroll succeeds |
| `…alertMailFailureIsAudited` | `"twelve chars+"` | Enroll succeeds |

Class analysis of `"twelve chars+"`: lowercase + space + `+`; **no uppercase, no digit** → PRODUCT-noncompliant. Domain layer accepts it.

### 4.5 Finding

| ID | Severity | Confidence | Title | Gap status |
| :--- | :--- | :--- | :--- | :--- |
| **W4-01** | **High** | High | Complexity helper/UI only; enroll/`hash` not fail-closed | **PARTIAL** (G2-01 not closed) |

**Recommended close-out:**

1. Call `validateComplexity` inside `PasswordHasher.hash` and/or `SecurityGatekeeper.enroll`; throw a dedicated error.  
2. Update Slice 9 tests to use a compliant password (e.g. `"Aa1!bbbbbbbb"`) and add negative cases for `"twelve chars+"` / `"aaaaaaaaaaaa"`.  
3. Commit the working-tree UI + helper only after domain enforcement lands (or accept UI-only as intentional doc change — currently docs still require classes).

---

## 5. Deep Dive B — 10-Minute Admin Session Expiration (G2-09 → PARTIAL)

### 5.1 PRODUCT rule

Sequence diagram: `Dash->>User: Unlocks Session (10-Minute Timeout)`.

### 5.2 Remediation present (working tree only — **not in HEAD**)

| Mechanism | Implementation |
| :--- | :--- |
| Constant | `SecurityGatekeeper.sessionTimeoutSeconds = 600` |
| Stamp | `markUnlocked` sets `unlockedAt = wallClock.now()` |
| Expiry check | `isUnlocked` clears `unlocked`/`unlockedAt` when `elapsed >= 600` |
| Mutation gate | `requireUnlocked()` → `isUnlocked` (Governance `performMutation`) |
| Manual lock | `lockSettings()` also clears `unlockedAt` |

Committed HEAD (`5339d48`) still matches Wave 2: boolean `unlocked` only, no auto-expiry.

### 5.3 Gaps remaining

#### 5.3.1 `snapshot()` does not apply timeout

```259:261:Sources/ZoidLockInCore/Security/SecurityGatekeeper.swift
            return SecuritySettingsSnapshot(
                isEnrolled: enrolled,
                isUnlocked: unlocked,
```

Tick / dashboard paths call `gatekeeper.snapshot()` (`ZoidLockInApp` assemble), **not** `isUnlocked`. After 10 minutes of idle unlocked UI:

- Settings can continue to render **UNLOCKED · 2FA PROTECTION ACTIVE**  
- `unlocked` flag remains `true` until something reads `isUnlocked` (mutation / habit lock check)  
- PRODUCT “session timeout” is therefore only **partially** enforced: **write path** expires; **session presentation** may not

#### 5.3.2 Wall clock only (not monotonic)

Expiry uses `wallClock.now().timeIntervalSince(unlockedAt)`. Advancing the system clock can expire early; rolling the clock backward can **extend** an unlocked session. Governance cooldown uses monotonic accrual + `TimeTravelGuard`; admin session timeout does not.

#### 5.3.3 No regression tests

Wave 2 verify: *Unlock, advance clock 601s, assert `requireUnlocked` / habit create throws `.notUnlocked`.*  
No such test exists in `Slice9*` / elsewhere (grep over Tests).

#### 5.3.4 Uncommitted

Until committed, production builds from HEAD retain G2-09 fully OPEN.

### 5.4 Finding

| ID | Severity | Confidence | Title | Gap status |
| :--- | :--- | :--- | :--- | :--- |
| **W4-02** | **High** | High | 600s timeout on `isUnlocked` only; snapshot/UI + mono + tests incomplete | **PARTIAL** (G2-09 not closed) |

**Recommended close-out:**

1. Have `snapshot()` compute unlock via the same expiry logic as `isUnlocked` (or call into a shared `evaluateUnlockLocked()`).  
2. Prefer monotonic elapsed (or fail-closed on time-travel) consistent with governance.  
3. Add ManualWallClock test: unlock → +601s → `isUnlocked == false`, `requireUnlocked` throws, snapshot `isUnlocked == false`.  
4. Commit SecurityGatekeeper session changes with the test.

---

## 6. Deep Dive C — Durable SQLite `admin_audit_events` (G2-07 → OPEN)

### 6.1 SPEC §3.1 requirement

```sql
CREATE TABLE IF NOT EXISTS admin_audit_events (
    id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL, -- 'ADMIN_LOGIN', 'CONFIG_MUTATION', 'EMERGENCY_OVERRIDE', 'PURGE_EXECUTION'
    metadata_json TEXT NOT NULL,
    email_dispatched INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

### 6.2 Current implementation

| Layer | Present? |
| :--- | :---: |
| In-memory `auditEvents: [AdminAuditRecord]` on `SecurityGatekeeper` | **Yes** |
| Persist on unlock / mail failure / config mutation alert | **Memory only** via `recordAudit` |
| `SQLiteEconomicLedger` DDL includes `admin_audit_events` | **No** |
| Insert/query API for admin audit rows | **No** |
| Survival across process restart | **No** |

Ledger `CREATE TABLE` list (wallet, focus, meetings, habits, governance, calibration, amenity overrides, blocklist, …) has **no** admin audit table — unchanged from Wave 1 / Wave 2.

`AdminAlertKind` raw values already match SPEC event names for login/mutation (`ADMIN_LOGIN`, `CONFIG_MUTATION`), but they never land in SQLite. `EMERGENCY_OVERRIDE` / `PURGE_EXECUTION` are also not written to this table (emergency uses `EmergencyIncidentStore` files — separate surface, not SPEC `admin_audit_events`).

### 6.3 Wave 2 verify recipe — fails

*Missing API key → durable audit row with `email_dispatched = 0`.*  
`alertMailFailureIsAudited` only asserts `gate.auditLog()` in-process.

### 6.4 Finding

| ID | Severity | Confidence | Title | Gap status |
| :--- | :--- | :--- | :--- | :--- |
| **W4-03** | **Medium** | High | SPEC `admin_audit_events` still unimplemented | **OPEN** (G2-07 unchanged) |

**Recommended close-out:**

1. Add SPEC-aligned DDL + indexes to `SQLiteEconomicLedger`.  
2. Inject ledger (or narrow `AdminAuditPersisting`) into `SecurityGatekeeper` / app wiring; write on every `recordAudit`.  
3. Map `AdminAlertKind` + metadata JSON + `email_dispatched`.  
4. Test: unlock with failing mail → row exists after new ledger open / process-equivalent reload.

---

## 7. Deep Dive D — TOTP Replay Defenses (G2-02 → PASS)

### 7.1 SPEC / operational expectation

RFC 6238 TOTP with Google Authenticator parameters; reject reuse of an already-accepted time-step window (anti-replay beyond bare RFC).

### 7.2 Committed baseline (already PASS in Wave 2)

| Property | Value |
| :--- | :--- |
| Algorithm / digits / step | HMAC-SHA1, 6 digits, 30s |
| Secret | 20 bytes (160-bit), Base32 |
| Skew | `allowedWindows = 1` |
| Replay store | `TOTPReplayWindow` + Keychain `totpLastWindowAccount` restored at init |
| Unlock path | `consumeTOTPWindow` before mark unlocked |
| Test | `Slice9AdversarialHardeningTests.totpReplayWithinWindowIsRejected` |

### 7.3 Working-tree hardening

HEAD used `replay.consume(window)` which rejects only **exact** `lastUsed == window` (a **lower** counter could still be accepted after clock skew / older window match).

Working tree:

```swift
if let last = replay.lastUsedTOTPWindow, window <= last {
    throw SecurityGatekeeperError.totpMismatch
}
replay.lastUsedTOTPWindow = window
// persist to keychain
```

This is **strictly stronger** (monotonic non-decreasing window counters). Unlock also still calls `persistReplayWindow` after consume.

Enrollment path that supplies `totpCode` still uses `replay.consume` (`==` only) inside `enroll` — narrower edge case than unlock replay.

### 7.4 Residual notes (non-blocking)

| Note | Severity |
| :--- | :--- |
| `consumeTOTPWindow` mutates `replay` outside `withMutex` in the working-tree edit (HEAD used `withMutex { replay.consume }`) — possible race under concurrent unlock attempts | Low–Medium residual |
| `verifyTOTP` does not consume (correct for non-destructive check) | Info |
| No change required for PRODUCT §6 item 2 | — |

### 7.5 Finding

| ID | Severity | Confidence | Title | Gap status |
| :--- | :--- | :--- | :--- | :--- |
| **W4-04** | Info | High | TOTP replay defenses remain effective; WT strengthens to `<=` | **PASS / CLOSED** vs Wave 2 |

---

## 8. Findings Summary

| ID | Maps to | Severity | Confidence | Status | Summary |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **W4-01** | G2-01 | High | High | **PARTIAL** | `validateComplexity` + UI; enroll/`hash` still length-only; weak-password tests still green |
| **W4-02** | G2-09 | High | High | **PARTIAL** | 600s on `isUnlocked` (uncommitted); `snapshot()` / UI / mono / tests incomplete |
| **W4-03** | G2-07 | Medium | High | **OPEN** | No `admin_audit_events` table or durable writes |
| **W4-04** | G2-02 | Info | High | **PASS** | Replay window + Keychain; WT `<=` hardening |

**Adjacent (out of requested foursome, still open from Wave 2):**

| ID | Severity | Status |
| :--- | :--- | :--- |
| G2-08 email copy ≠ PRODUCT verbatim | Medium | **OPEN** |
| G2-10 Argon2id SPEC vs PBKDF2 impl | Medium | **OPEN** (drift) |

**Counts (Wave 4 focus):** High PARTIAL **2** · Medium OPEN **1** · Info PASS **1**.

---

## 9. Gap-Closing Scorecard vs Wave 2 Remediation Batches

### Batch A — PRODUCT §6 auth friction

| Item | Closed? |
| :--- | :---: |
| A1 Character-class password enforcement | **No** (UI only) |
| A2 10-minute auto-lock | **No** (partial domain only; uncommitted) |
| A3 Verbatim admin email copy | **No** (out of scope; still open) |

### Batch B — Audit durability / SPEC

| Item | Closed? |
| :--- | :---: |
| B1 Persist `admin_audit_events` | **No** |
| B2 Document Argon2id vs PBKDF2 | **No** |

### Batch C — Regression tests

| Item | Closed? |
| :--- | :---: |
| C1 Reject weak / accept complex password | **No** (opposite: weak still accepted) |
| C2 Unlock + 601s → mutations blocked | **No** (no test; snapshot gap) |
| C3 Missing API key → durable `email_dispatched = 0` row | **No** |

---

## 10. False Positives / Clarifications

| Lead | Resolution |
| :--- | :--- |
| “Complexity is implemented because `validateComplexity` exists” | Helper alone does not close G2-01; fail-closed enroll is required. |
| “Session timeout is done because `sessionTimeoutSeconds = 600`” | Mutation path yes; dashboard `snapshot()` path no; change uncommitted. |
| “Local audit mode proves durable logging” | Proves in-memory honesty + UI banner only; SPEC SQLite durability still missing. |
| “TOTP needs remediation in Wave 4” | Already PASS; optional hardening is incremental, not a prior gap reopen. |

---

## 11. Residual Risk

Until W4-01 / W4-02 / W4-03 are fully closed:

1. An operator (or test/harness path) can enroll a low-complexity admin password that PRODUCT §6 forbids; UI friction is not a trust boundary.  
2. An unlocked admin session can remain presented as unlocked after 10 minutes if only `snapshot()` is observed; wall-clock rollback can stretch unlock lifetime.  
3. Admin unlock / mail-failure / config-mutation events vanish on process death — no durable forensic trail matching SPEC §3.1, including when Resend is unconfigured.

TOTP same-window replay remains rejected; working-tree `<=` further reduces older-window reuse. That control is the only requested focus area that is verification-**PASS**.

---

## 12. Evidence Index

| Claim | Location |
| :--- | :--- |
| Complexity helper (WT) | `PasswordHasher.validateComplexity` |
| hash still length-only | `PasswordHasher.hash` → `validateLength` |
| enroll still length-only | `SecurityGatekeeper.enroll` |
| UI complexity gate (WT) | `CommandDashboardView.enrollmentSettings` |
| Session timeout constant (WT) | `SecurityGatekeeper.sessionTimeoutSeconds` |
| Expiry on `isUnlocked` (WT) | `SecurityGatekeeper.isUnlocked` |
| Snapshot ignores timeout | `SecurityGatekeeper.snapshot` → `isUnlocked: unlocked` |
| Dashboard uses snapshot | `ZoidLockInApp` `CommandDashboardSnapshot.assemble(security: gatekeeper.snapshot())` |
| In-memory audit only | `SecurityGatekeeper.recordAudit` / `auditEvents` |
| No SQLite admin audit DDL | `SQLiteEconomicLedger` CREATE TABLE list |
| SPEC table definition | `SPEC.md` §3.1 `admin_audit_events` |
| TOTP replay test | `Slice9AdversarialHardeningTests.totpReplayWithinWindowIsRejected` |
| Weak password still enrolled in tests | `Slice9DesktopDashboardTests` / `Slice9AdversarialHardeningTests` (`"twelve chars+"`) |
| Wave 2 baseline | `.audit/wave2_governance_2fa_audit.md` |

---

## 13. Suggested Next Remediation Order (do not implement in this audit)

1. **Fail-closed password complexity** in `hash`/`enroll` + fix tests (closes W4-01 / G2-01).  
2. **Unify unlock evaluation** for `isUnlocked` + `snapshot` + add 601s test; commit session timeout (closes W4-02 / G2-09).  
3. **Add `admin_audit_events` DDL + writes** including `email_dispatched` (closes W4-03 / G2-07).  
4. Optionally restore mutex around TOTP replay mutation; keep `window <= last` hardening.  
5. Address G2-08 / G2-10 as separate SPEC/PRODUCT alignment batch.

---

*End of Wave 4 security remediation gap-closing verification report.*
