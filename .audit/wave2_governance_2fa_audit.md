# Wave 2 Governance & 2FA Audit Report

**Audit date:** 2026-09-16  
**Repository revision:** `a5dfed0adb467546e42e9387ade9ccc0aa6add71` (`feat(ui): add native Focus work session tab in menu bar and fix reboot tamper lock`)  
**Mode:** Read-only source audit (no remediations, no test execution, no dependency changes)  
**Primary standard:** `PRODUCT.md` §6 — High-Friction Anti-Cheating Protocol (Admin Gateway)  
**Secondary references:** `SPEC.md` §2.4 / §3.1 (`admin_audit_events`), PRODUCT §9 module names  

---

## 1. Executive Verdict

| Focus area (user-requested) | Verdict | Confidence |
| :--- | :--- | :--- |
| **Password complexity enforcement** | **FAIL** — length ≥12 only; no upper/lower/digit/symbol classes | High |
| **Google Authenticator TOTP verification** | **PASS** — RFC 6238 HMAC-SHA1, 30s, 6 digits, otpauth URL, replay window | High |
| **48-hour monotonic cooldown** on habit / price / blocklist mutations | **PASS** — `172_800`s accrued from monotonic clock; wall jumps do not expire | High |
| **Read-only locks** during cooldown / integrity failure / locked 2FA | **PASS** — `ensureMutable` / `performMutation` fail-closed; habit editor `editorIsLocked` | High |
| **Local audit when Resend API key unconfigured** | **PASS with durability gap** — in-process `AdminAuditRecord` + UI banner; not SQLite `admin_audit_events` | High |

**Overall PRODUCT §6 alignment:** **PARTIAL**. Authentication factors and the 48-hour configuration rate-limit are implemented and test-backed. Material gaps remain on **character-class password complexity**, **10-minute admin session timeout** (PRODUCT sequence diagram), **verbatim psychological email copy**, and **durable SQLite admin audit** (SPEC §3.1). SPEC’s Argon2id claim also diverges from the PBKDF2-HMAC-SHA256 hasher.

---

## 2. Scope & Artifacts

### 2.1 Components under audit

| Component | Path | Role vs PRODUCT §6 |
| :--- | :--- | :--- |
| `PasswordHasher` | `Sources/ZoidLockInCore/Security/PasswordHasher.swift` | Password barrier hashing / length gate |
| `SecurityGatekeeper` | `Sources/ZoidLockInCore/Security/SecurityGatekeeper.swift` | Password + TOTP unlock, alert dispatch, local audit buffer |
| `GovernanceLockCoordinator` | `Sources/ZoidLockInCore/Economy/GovernanceLockCoordinator.swift` (+ `GovernanceLock.swift`) | 48h cooldown, mutation gate, read-only enforcement |
| `AlertMailService` | `Sources/ZoidLockInCore/AlertMailService.swift` | Resend POST; throws `missingAPIKey` when unconfigured |

### 2.2 Closely coupled (evidence only)

| Artifact | Why included |
| :--- | :--- |
| `TOTPEngine.swift` | Google Authenticator–compatible RFC 6238 engine used by gatekeeper |
| `MicroHabitCoordinator.swift` | Habit CRUD mutations go through `governance.performMutation` |
| `CommandDashboardView.swift` | Settings UI: unlock, local-audit banner |
| `ZoidLockInApp.swift` | Wires `AlertMailService` into `SecurityGatekeeper` + gatekeeper into governance |
| Tests: `Slice8MicroHabitsTests`, `Slice8AdversarialHardeningTests`, `Slice9AdversarialHardeningTests`, `Slice9DesktopDashboardTests`, `AlertMailServiceTests` | Behavioral evidence (read, not executed this pass) |

### 2.3 Exclusions

- Emergency safety valve (PRODUCT §7) except where `AlertMailService` emergency payload overlaps mail plumbing  
- UI completeness of price/blocklist editors on the Command Dashboard (covered in Wave 1 UI audit)  
- Full Keychain / FileSecureDataStore threat model beyond credential storage call sites  
- Live Resend API or network calls  

---

## 3. PRODUCT.md §6 Requirement Checklist

| ID | Requirement (condensed) | Implementation | Status |
| :--- | :--- | :--- | :--- |
| P6.1 | Password ≥**12** chars with **uppercase, lowercase, numbers, and symbols** | `PasswordHasher.validateLength` / `minimumLength = 12` only | **FAIL** (length OK; classes missing) |
| P6.2 | Standard TOTP via **Google Authenticator** | `TOTPEngine`: SHA1, 30s, 6 digits, 160-bit secret, `otpauth://totp/…` | **PASS** |
| P6.3 | Instant psychological warning email on admin auth | `SecurityGatekeeper.unlock` → `mail.dispatchAdminAlert`; app injects `AlertMailService` | **PARTIAL** (dispatch yes; copy ≠ PRODUCT verbatim) |
| P6.4a | Any config edit (amenity price, micro-task reward, blocklist) starts **48h read-only** | Habit/price/blocklist paths call `performMutation` → `recordMutationLocked` resets accrual to 0 | **PASS** |
| P6.4b | No further mods until 48h fully expires | `ensureMutableLocked` throws `.cooldownActive` while `remaining > 0` | **PASS** |
| P6.4c | Dev/staging bypass; **permanently disabled in production** | `ZOID_BYPASS_GOVERNANCE_COOLDOWN` + `#if DEBUG`; Release always `false` | **PASS** |
| P6.5 | Sequence: unlock session with **10-minute timeout** | `unlocked` boolean; cleared only by `lockSettings()` — no wall/monotonic expiry | **FAIL** |
| P6.6 | Local audit when Resend key missing (operational honesty) | `missingAPIKey` → `AdminAuditRecord(emailDispatched: false)` + Settings banner | **PASS** (in-memory) |

---

## 4. Deep Dive: `PasswordHasher` — Complexity Enforcement

### 4.1 PRODUCT rule

> Minimum 12 characters requiring uppercase, lowercase, numbers, and symbols.

### 4.2 Implementation

```19:23:Sources/ZoidLockInCore/Security/PasswordHasher.swift
    public static func validateLength(_ password: String) throws {
        if password.count < minimumLength {
            throw PasswordHashingError.tooShort(minimum: minimumLength)
        }
    }
```

- `minimumLength = 12`  
- `hash(_:)` calls `validateLength` then PBKDF2-HMAC-SHA256 (`100_000` iterations default, 16-byte salt, 32-byte key)  
- Stored format: `pbkdf2-sha256$iterations$saltB64$hashB64`  
- Verify uses timing-safe compare  

**No** character-class checks (`isUppercase` / `isLowercase` / `isNumber` / symbol / `CharacterSet`) exist anywhere in the hasher or gatekeeper.

### 4.3 Enrollment / unlock path

`SecurityGatekeeper.enroll` only maps hasher length failures to `.passwordTooShort`.  
`verifyPassword` rejects `password.count < 12` then verifies the hash — still no class rules.

### 4.4 Evidence that weak-class passwords are accepted

Unit/adversarial tests enroll and unlock with passwords that fail PRODUCT class rules:

| Test password | Length | Classes present | PRODUCT-compliant? |
| :--- | ---: | :--- | :--- |
| `"twelve chars+"` | 13 | lower, space, `+` | **No** (no upper, no digit) |
| `"correct-horse"` | 13 | lower, hyphen | **No** (no upper, no digit; symbol ambiguous) |

Sources: `Slice9DesktopDashboardTests.passwordValidation` / `gatekeeperAndAlertMail`; `Slice9AdversarialHardeningTests`.

### 4.5 SPEC drift (related)

`SPEC.md` §2.4 / `PRD.md` claim **Argon2id**. Implementation is **PBKDF2-HMAC-SHA256**. Salted slow hash intent is present; algorithm name does not match SPEC.

### 4.6 Finding

| ID | Severity | Confidence | Title |
| :--- | :--- | :--- | :--- |
| **G2-01** | **High** | High | Password complexity classes not enforced |

**Reachable path:** Settings enroll / unlock → `PasswordHasher.validateLength` / `hash`  
**Impact:** Admin barrier reduces to “any 12+ Unicode scalar string,” including all-lowercase phrases without digits/symbols — weaker than PRODUCT §6.1.  
**Recommended action:** Add explicit class validation (upper + lower + digit + symbol) in `PasswordHasher` (or a shared validator called from enroll); reject enrollment and document UI requirements. Align SPEC Argon2id vs PBKDF2 separately.  
**Verify:** Unit tests that `"twelve chars+"` and `"aaaaaaaaaaaa"` fail; `"Aa1!bbbbbbbb"` succeeds.

---

## 5. Deep Dive: Google Authenticator TOTP (`SecurityGatekeeper` + `TOTPEngine`)

### 5.1 PRODUCT rule

Standard TOTP verified via Google Authenticator; sequence prompts a 6-digit code after password.

### 5.2 Implementation summary

| Property | Value | Google Authenticator alignment |
| :--- | :--- | :--- |
| Algorithm | HMAC-SHA1 (`Insecure.SHA1`) | Yes (GA default) |
| Digits | 6 | Yes |
| Period | 30 seconds | Yes |
| Secret size | 20 bytes (160-bit) | Yes |
| Encoding | RFC 4648 Base32 (GA alphabet) | Yes |
| Provisioning | `otpauth://totp/Zoid%20Lock%20In:admin?secret=…&period=30&digits=6&algorithm=SHA1` | Yes |
| Clock skew | `allowedWindows = 1` (±1 step) | Reasonable |
| Replay | `TOTPReplayWindow` persists last used counter in Keychain | Stronger than bare RFC |

Unlock path (`SecurityGatekeeper.unlock`):

1. Require enrolled password hash + TOTP secret in Keychain  
2. `verifyPassword`  
3. `consumeTOTPWindow` → `matchingCounter` + replay consume  
4. Mark unlocked; dispatch admin alert; return `SecuritySession`

### 5.3 Evidence

- RFC 6238 published vector check: `Slice9DesktopDashboardTests.rfc6238TOTP` (`94287082` / `287082` / `07081804`)  
- Bad password / bad TOTP rejected: `gatekeeperAndAlertMail`  
- Same-window replay rejected: `Slice9AdversarialHardeningTests.totpReplayWithinWindowIsRejected`  
- Enrolled+locked 2FA blocks habit/price mutations: `enrolledTwoFactorBlocksConfigurationMutations`

### 5.4 Finding

| ID | Severity | Confidence | Title |
| :--- | :--- | :--- | :--- |
| **G2-02** | Info | High | TOTP / Google Authenticator verification **PASS** |

No material gap against PRODUCT §6 item 2.

---

## 6. Deep Dive: 48-Hour Monotonic Cooldown & Read-Only Locks

### 6.1 PRODUCT rule

Any amenity price, micro-task reward, or blocklist commit starts a **48-hour read-only lockdown**. Dev override allowed in staging; disabled in production.

### 6.2 Policy constants

```4:29:Sources/ZoidLockInCore/Economy/GovernanceLock.swift
public enum GovernanceLockPolicy: Sendable {
    public static let cooldownSeconds: TimeInterval = 172_800
    public static let bypassEnvironmentKey = "ZOID_BYPASS_GOVERNANCE_COOLDOWN"
    // ...
    public static func isEnvironmentBypassEnabled(_ environment: [String: String]) -> Bool {
        #if DEBUG
        // accepts "1" / "true" / "yes"
        #else
        return false
        #endif
    }
}
```

`172_800` seconds = **exactly 48 hours**.

### 6.3 Monotonic accrual (anti time-travel)

`GovernanceLockCoordinator.accrueLocked`:

- Observes wall + monotonic via `TimeTravelGuard`  
- Remaining = `cooldownSeconds - accruedMonotonicElapsed` (plus positive mono deltas within the same boot session)  
- On clock tamper: remaining forced to at least `1` (fail-closed)  
- `recordMutationLocked` sets `accruedMonotonicElapsed = 0` and stamps wall/mono mutation fields  

Comment on the type is accurate: *“Remaining time uses monotonic accrual so advancing System Settings cannot expire the lock.”*

### 6.4 Mutation entry points (all three PRODUCT categories)

| Mutation | API | Goes through `performMutation`? |
| :--- | :--- | :--- |
| Amenity price | `setAmenityPrice` | **Yes** |
| Blocklist add/remove | `addBlocklistSuffix` / `removeBlocklistSuffix` | **Yes** |
| Habit create/update/enable | `MicroHabitCoordinator` → `governance.performMutation` | **Yes** |

`performMutation` sequence:

1. `ensureMutableLocked()` — cooldown / tamper / bypass  
2. `requireSecurityUnlockedLocked()` — if gatekeeper enrolled, must be unlocked  
3. Run body  
4. `recordMutationLocked()` — start/refresh 48h  
5. Publish live settings; `gatekeeper?.noteConfigurationMutation()`  

Habit **completions** intentionally bypass governance mutation (minting is not a config edit) — matches PRODUCT intent and is covered by `completionsAreNotMutations`.

### 6.5 Read-only lock surfaces

| Layer | Behavior |
| :--- | :--- |
| Domain | `ensureMutable` / `performMutation` throw `.cooldownActive` or `.clockTampered`; integrity failure → `GovernanceLockSnapshot.failClosed` (`isLocked: true`, full 48h remaining) |
| Habit UI | `editorIsLocked = (48h locked && !bypass) \|\| integrityFailed \|\| (enrolled && !unlocked)` → fields disabled, opacity 0.55, caption `READ-ONLY · CONFIGURATION LOCKED` |
| 2FA | Enrolled + locked gatekeeper → `SecurityGatekeeperError.notUnlocked` on mutation |

### 6.6 Production bypass disablement

| Build | `isEnvironmentBypassEnabled` | Coordinator `isCooldownBypassEnabled` |
| :--- | :--- | :--- |
| DEBUG | Honors `ZOID_BYPASS_GOVERNANCE_COOLDOWN` | Env OR injected test config |
| Release (`#else`) | Always `false` | Only injected test config (`internal`); production public init cannot enable env bypass |

Matches PRODUCT “permanently disabled upon production release.”

### 6.7 Evidence

| Test | Asserts |
| :--- | :--- |
| `mutationLockActivates` | First habit create locks; remaining ≈ 172800 |
| `cooldownRejectsEdits` | Second create / update / disable fail closed |
| `configMutationsStartLock` | Price then blocklist blocked |
| `monotonicTimeTravelResistance` | Wall-only +48h does **not** unlock |
| `honestCooldownExpiry` | Honest mono advance unlocks |
| `productionBuildsRejectEnvironmentBypass` | Release ignores env bypass |
| `sqliteTamperingFailsClosed` | Seal/integrity fail → locked |

### 6.8 Findings

| ID | Severity | Confidence | Title |
| :--- | :--- | :--- | :--- |
| **G2-03** | Info | High | 48h monotonic cooldown on habit/price/blocklist **PASS** |
| **G2-04** | Info | High | Read-only lockdown (domain + habit editor + 2FA) **PASS** |
| **G2-05** | Info | High | DEBUG-only cooldown bypass; Release disabled **PASS** |

**Naming note:** PRODUCT §9 names `CooldownManager`; code uses `GovernanceLockCoordinator` / `GovernanceLockPolicy`. Behavioral equivalent; naming drift only.

---

## 7. Deep Dive: `AlertMailService` + Local Audit (Unconfigured Resend Key)

### 7.1 PRODUCT / operational expectation

On successful admin authentication, dispatch a warning email. When Resend cannot send (no API key), the unlock must still succeed and the event must be **recorded locally** (Settings UI copy: “Local audit mode”).

### 7.2 Key resolution

`ResendAPIKeyResolver.resolve()` order:

1. `configuration.apiKey`  
2. Env `ZOID_LOCK_IN_RESEND_API_KEY`  
3. Keychain `com.mavoid.zoidlockin.resend` / `api-key`  

If all empty → `nil`.

### 7.3 Dispatch behavior

```268:277:Sources/ZoidLockInCore/AlertMailService.swift
    public func dispatchAdminAlert(_ event: AdminAlertEvent) async throws {
        guard let apiKey = keyResolver.resolve() else {
            throw AlertMailError.missingAPIKey
        }
        // POST https://api.resend.com/emails …
    }
```

App wiring (`ZoidLockInApp`):

```264:268:Sources/ZoidLockInApp/ZoidLockInApp.swift
        let gatekeeper = SecurityGatekeeper(
            keychain: FileSecureDataStore.shared,
            mail: AlertMailService(
                configuration: AlertMailConfiguration(recipient: SecurityGatekeeper.defaultRecipient)
            )
        )
```

Production path uses real `AlertMailService` (not `NoOpAdminAlertDispatcher`).

### 7.4 Local audit recording path

`SecurityGatekeeper.dispatchAlertRecordingFailure`:

- Success → `AdminAuditRecord(…, emailDispatched: true)`  
- Any throw (including `.missingAPIKey`) → `emailDispatched: false` + `errorDescription`  
- Snapshot: `mailDispatchFailed`, `lastAuditEmailDispatched`  
- UI (`CommandDashboardView.unlockedSettings`): when `mailDispatchFailed`, shows *“Local audit mode (no Resend API key configured). The session is recorded locally.”*

Unlock still completes (`isUnlocked` remains true) — confirmed by `alertMailFailureIsAudited`.

### 7.5 Durability gap vs SPEC

| Store | Present? |
| :--- | :--- |
| In-memory `auditEvents: [AdminAuditRecord]` on gatekeeper | **Yes** |
| SPEC §3.1 SQLite `admin_audit_events` | **Not implemented** in `SQLiteEconomicLedger` DDL (Wave 1 enforcement audit also noted this) |

Local audit **survives the process session** for UI honesty, but **does not survive app restart** and is not queryable as a durable ledger.

### 7.6 Email copy vs PRODUCT verbatim

PRODUCT §6 psychological warning:

> *“CRITICAL SECURITY & INTEGRITY ALERT: You have authenticated into the Zoid 0 Trading Center Admin Settings. Remember why you erected these walls…”*

Implementation (`makeAdminPayload`):

- Subject: `WARNING: Admin settings unlocked` / `WARNING: Administrative configuration mutated`  
- Body headline: `PSYCHOLOGICAL COMMITMENT ALERT: …`  
- Mentions 48-hour governance cooldown  

Dispatch channel and intent match; **verbatim PRODUCT copy does not**.

### 7.7 Findings

| ID | Severity | Confidence | Title |
| :--- | :--- | :--- | :--- |
| **G2-06** | Info | High | Missing Resend key → throw + local in-memory audit + UI banner **PASS** |
| **G2-07** | Medium | High | Admin audit not persisted to SPEC `admin_audit_events` SQLite table |
| **G2-08** | Medium | High | Admin warning email copy diverges from PRODUCT §6 verbatim |

**Recommended action (G2-07):** Persist `AdminAuditRecord` (or equivalent) to SQLite on every unlock/mutation attempt, including `email_dispatched = 0` when key missing.  
**Recommended action (G2-08):** Align subject/body with PRODUCT wording (or amend PRODUCT if current copy is intentional).

---

## 8. Adjacent PRODUCT §6 Gap: 10-Minute Session Timeout

PRODUCT sequence diagram ends with:

> `Dash->>User: Unlocks Session (10-Minute Timeout)`

### 8.1 Implementation

- `SecuritySession.unlockedAt` is returned but **not** used for expiry  
- Gatekeeper holds `private var unlocked = false`  
- `lockSettings()` is the only clear path (manual UI “LOCK SETTINGS”)  
- No timer, wall-clock delta, or monotonic check against `unlockedAt`

### 8.2 Finding

| ID | Severity | Confidence | Title |
| :--- | :--- | :--- | :--- |
| **G2-09** | **High** | High | No 10-minute admin unlock timeout |

**Impact:** After one successful 2FA unlock, configuration mutation capability remains until explicit lock or process death — weaker impulse friction than PRODUCT §6 sequence.  
**Recommended action:** Auto-lock when `wallClock.now() - unlockedAt >= 600` (and/or monotonic), checked in `requireUnlocked` / mutation path.  
**Verify:** Unlock, advance clock 601s, assert `requireUnlocked` / habit create throws `.notUnlocked`.

---

## 9. Findings Summary (by severity)

| ID | Severity | Confidence | Component | Summary |
| :--- | :--- | :--- | :--- | :--- |
| **G2-01** | High | High | `PasswordHasher` / `SecurityGatekeeper` | No upper/lower/digit/symbol complexity — length-only |
| **G2-09** | High | High | `SecurityGatekeeper` | No 10-minute session timeout |
| **G2-07** | Medium | High | `SecurityGatekeeper` / ledger | Local audit is in-memory only; SPEC `admin_audit_events` absent |
| **G2-08** | Medium | High | `AlertMailService` | Admin email copy ≠ PRODUCT verbatim |
| **G2-10** | Medium | High | `PasswordHasher` vs SPEC | Argon2id specified; PBKDF2-SHA256 implemented |
| **G2-02** | Info | High | `TOTPEngine` | Google Authenticator TOTP **PASS** |
| **G2-03** | Info | High | `GovernanceLockCoordinator` | 48h monotonic cooldown **PASS** |
| **G2-04** | Info | High | Governance + habits UI | Read-only locks **PASS** |
| **G2-05** | Info | High | `GovernanceLockPolicy` | Production bypass disabled **PASS** |
| **G2-06** | Info | High | `AlertMailService` + gatekeeper | Unconfigured Resend → local audit path **PASS** |

**Counts:** High 2 · Medium 3 · Info 5 · Confirmed failures against user checklist: **password complexity** · Confirmed passes: **TOTP**, **48h monotonic cooldown**, **read-only locks**, **local audit on missing Resend key** (with durability caveat).

---

## 10. False Positives / Non-Findings

| Lead | Resolution |
| :--- | :--- |
| Default `NoOpAdminAlertDispatcher` on gatekeeper init | App overrides with `AlertMailService`; tests inject recording/failing mail. Production path is wired. |
| Habit completions during cooldown | By design — not configuration mutations; PRODUCT targets price/reward/blocklist **edits**. |
| `CooldownManager` missing as a type | Renamed/merged into `GovernanceLockCoordinator`; behavior present. |
| Emergency mail “CRITICAL SECURITY…” prefix | Applies to emergency valve payload, not admin unlock — do not treat as satisfying §6 admin copy. |

---

## 11. Proposed Remediation Batches (do not implement in this audit)

### Batch A — PRODUCT §6 compliance (auth friction)

1. Enforce password character classes in `PasswordHasher` (+ enroll UI validation).  
2. Implement 10-minute auto-lock on admin session.  
3. Align admin Resend email copy with PRODUCT §6 (or amend PRODUCT).  

### Batch B — Audit durability / SPEC alignment

1. Persist admin events to SQLite `admin_audit_events` (or documented equivalent).  
2. Document or migrate Argon2id vs PBKDF2 in SPEC/PRD.  

### Batch C — Regression tests

1. Reject `"twelve chars+"` / accept a fully complex password.  
2. Unlock + advance 601s → mutations blocked.  
3. Missing API key → durable audit row with `email_dispatched = 0`.  

---

## 12. Residual Risk

Even with working TOTP and a sealed 48-hour monotonic cooldown, an attacker (or impulsive user) who once enrolls a low-complexity password and unlocks can:

1. Keep an open admin session indefinitely (no 10-minute timeout).  
2. Rely on passwords that do not meet PRODUCT’s stated complexity bar.  
3. Lose local mail-failure evidence across restarts (no durable admin audit table).

The **configuration rate-limit itself** remains the strongest implemented anti-cheating control for habit/price/blocklist edits and is correctly monotonic and fail-closed under clock tamper / seal integrity failure.

---

## 13. Evidence Index

| Topic | Primary symbols / lines |
| :--- | :--- |
| Length-only password gate | `PasswordHasher.minimumLength`, `validateLength` |
| PBKDF2 storage | `PasswordHasher.hash` → `pbkdf2-sha256$…` |
| Unlock + TOTP + replay | `SecurityGatekeeper.unlock`, `consumeTOTPWindow`, `TOTPReplayWindow` |
| RFC 6238 engine | `TOTPEngine` (`digits=6`, `timeStep=30`, HMAC-SHA1) |
| 48h policy | `GovernanceLockPolicy.cooldownSeconds = 172_800` |
| Monotonic accrue | `GovernanceLockCoordinator.accrueLocked` / `recordMutationLocked` |
| Mutation APIs | `setAmenityPrice`, `addBlocklistSuffix`, `MicroHabitCoordinator.createHabit/updateHabit` |
| Read-only UI | `MicroHabitsSnapshot.editorIsLocked`, `editorReadOnlyCaptionText` |
| Missing key | `AlertMailError.missingAPIKey`, `dispatchAlertRecordingFailure` |
| Local audit UI | `CommandDashboardView` “Local audit mode…” |
| App wiring | `ZoidLockInApp` → `SecurityGatekeeper(mail: AlertMailService(…))` |

**Tools / method:** Manual source review + cross-reference to PRODUCT §6 / SPEC §2.4 / existing unit tests. Tests were **not** re-executed in this pass. No scanners installed; no `.env` or secret values read.
