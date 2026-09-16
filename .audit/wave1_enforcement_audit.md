# Wave 1 Enforcement Audit Report

**Scope:** Read-only comparison of `SPEC.md` Sections **3** and **5** against:

| Requested path | Actual path audited |
| --- | --- |
| `Sources/ZoidLockInDaemon/` | `Sources/ZoidLockInDaemon/` |
| `Sources/ZoidLockInFilter/` | **`Sources/ZoidLockInFilterExtension/`** (no `ZoidLockInFilter` target exists) |
| `Sources/ZoidLockInEnforcer/` | `Sources/ZoidLockInEnforcer/` |
| `Sources/ZoidLockInIPC/` | `Sources/ZoidLockInIPC/` |

**Supporting context (read, not primary scope):** `Sources/ZoidLockInCore/` (policy, matcher, filter engine, identity, heartbeat), `Resources/com.mavoid.zoidlockin.helper.plist`, `Package.swift`, related unit tests, and user-space call sites in `Sources/ZoidLockInApp/` / `Sources/ZoidLockInEconomy/` where they affect Section 3↔enforcement coupling.

**Audit date:** 2026-09-16  
**Mode:** Read-only (no code changes)

---

## 1. Executive Verdict

Enforcement **logic** for the five Wave‑1 focus areas is largely implemented and aligned with the security intent of SPEC §1.1 / §2.5 / §5.2:

| Focus area | Verdict |
| --- | --- |
| SMAppService registration | **Partial** — plist + `DaemonServiceRegistrar` match SPEC; **app-side `register()` wiring is missing** |
| Process kill loop (`SIGSTOP` / `SIGKILL` / `killpg`) | **Compliant** |
| `NEFilterDataProvider` socket blocking | **Mostly compliant** — core verdict path correct; **live activation wiring incomplete**; pre‑macOS‑15 port extraction gap |
| Fail-closed behavior | **Compliant** (with documented nuances) |
| `audit_token_t` client verification | **Compliant** (stronger than SPEC §5.1 surface API) |

SPEC **§5.1** XPC method signatures have **intentionally diverged** into a richer, typed, fail-closed protocol (JSON snapshots, vouchers, heartbeat, incident levy). That is a **spec drift**, not an absence of enforcement IPC.

SPEC **§3** (`active_amenity_passes` and related SQLite DDL) is **not** the privileged source of truth for passes. The daemon owns passes via `DaemonPassController` + durable redemption journal under `/var/db/zoidlockin`. User-space SQLite deliberately stays out of the helper (`Package.swift`). This is an **architectural security improvement** relative to a naive reading of §3, but it is a **hard divergence** from the written schema.

Overall Wave‑1 readiness: **core enforcement machinery is present and test-backed**; **packaging / host activation / SMAppService call-site integration** are the primary residual gaps for a shippable Slice‑1/2 product surface.

---

## 2. Inventory of Audited Artifacts

### 2.1 Daemon (`Sources/ZoidLockInDaemon/`)

| File | Role |
| --- | --- |
| `ZoidLockInDaemonMain.swift` | `@main` LaunchDaemon entry: fail-closed boot policy, sentinel + Mach listener, `dispatchMain()` |

### 2.2 Enforcer (`Sources/ZoidLockInEnforcer/`)

| File | Role |
| --- | --- |
| `EnforcementDaemon.swift` | Policy, passes, heartbeat watchdog, incident/journal restore, filter status publish, XPC servicing |
| `ProcessSentinel.swift` | 1.5s scan loop; `proc_*` enumerate; `SIGSTOP`→`SIGKILL` + `killpg` |
| `DaemonServiceRegistrar.swift` | `SMAppService.daemon(plistName:)` register/unregister |
| `EnforcementXPCListener.swift` | `audit_token_t` gate + `NSXPC` export bridge |

### 2.3 Filter (`Sources/ZoidLockInFilterExtension/`)

| File | Role |
| --- | --- |
| `ContentFilterProvider.swift` | `NEFilterDataProvider` principal class; socket flow → verdict |
| `ContentFilterActivation.swift` | Host-side `NEFilterManager` / encrypted-DNS defeat helpers |
| `Resources/Info.plist` | Sysex bundle `com.mavoid.zoidlockin.filter`; `filter-data` provider class |
| `Resources/*.entitlements` | `content-filter-provider-systemextension` |

### 2.4 IPC (`Sources/ZoidLockInIPC/`)

| File | Role |
| --- | --- |
| `ZoidLockInEnforcementProtocol.swift` | Swift async service protocol |
| `ZoidLockInEnforcementXPC.swift` | `@objc` NSXPC wire protocol |
| `XPCEnforcementClient.swift` | User-space client + heartbeat loop |
| `XPCAuditTokenGatekeeper.swift` | `SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` |
| `AuditTokenExtraction.swift` | `audit_token_t` ↔ `Data` / KVC from `NSXPCConnection` |
| `ZoidLockInIPCIdentity.swift` | Identity re-exports |

### 2.5 Bundled LaunchDaemon plist

`Resources/com.mavoid.zoidlockin.helper.plist` — Label, BundleProgram, KeepAlive, RunAtLoad, ThrottleInterval=1, MachServices.

---

## 3. SPEC §5.2 — Network Extension Content Filter

### 3.1 Spec requirements (quoted intent)

From SPEC §5.2:

1. Unprivileged app configures filter via `NEFilterManager`; provider in `com.mavoid.zoidlockin.filter`.
2. Provider: `ContentFilterProvider` subclass of `NEFilterDataProvider`, packaged as Network System Extension (`content-filter-provider-systemextension`).
3. Intercept outbound **TCP and UDP** on ports **80, 443, 8080, 1080** (including UDP/443 / HTTP/3).
4. Hostname from `NEFilterSocketFlow.remoteHostname` or `flow.url`; normalize; IP literals unverified.
5. On inspected ports, **nil / empty / unverified hostnames fail closed** (`drop`).
6. Compare verified hostnames to blacklisted suffixes; drop if match and no active pass; allow if pass valid.

### 3.2 Implementation mapping

| Requirement | Location | Status |
| --- | --- | --- |
| Separate sysex, not in daemon | `Package.swift` (FilterExtension not a Daemon dependency); `ZoidLockInDaemonMain` comments; `ContentFilterProvider` docs | **Met** |
| Bundle ID `com.mavoid.zoidlockin.filter` | Filter `Info.plist`; `ZoidLockInIdentity.filterSystemExtensionBundleIdentifier` | **Met** |
| Principal class `ContentFilterProvider` | `Info.plist` → `$(PRODUCT_MODULE_NAME).ContentFilterProvider` | **Met** |
| Entitlement `content-filter-provider-systemextension` | `ZoidLockInFilterExtension.entitlements` | **Met** |
| TCP + UDP | `ContentFilterProvider.handleNewFlow` + `transport(from:)`; `FilterFlowEvaluator` treats `.tcp`/`.udp` | **Met** |
| Ports 80/443/8080/1080 | `EnforcementPolicy.defaultInspectedPorts` | **Met** |
| Hostname sources | `ContentFilterProvider.hostname(from:)` — `remoteHostname`, `url?.host`, macOS 15+ `remoteFlowEndpoint` name | **Met** (plus macOS 15 endpoint path) |
| Normalize / strip dots / case-fold | `DomainFilterRules.normalize` | **Met** |
| IP literals unverified | `DomainFilterRules.isIPLiteral` / `verifiedHostname` | **Met** |
| Fail-closed nil/empty/IP | `DomainFilterRules.verdict` → `.drop`; tests in `ContentFilterAndSentinelTests` | **Met** |
| Blacklist suffixes | `DomainFilterRules.defaultBlacklist` (superset of SPEC examples) | **Met / extended** |
| Pass relaxes block | Kind-scoped whitelist overlay via snapshot / `PassKind.relaxedDomainSuffixes` | **Met** (richer than single token) |
| `disableEncryptedDNSSettings` (macOS 15+) | `ContentFilterActivation.applyDisableEncryptedDNSSettings` | **Helper exists; app does not call it** |
| Host activation via `NEFilterManager` | `ContentFilterActivation.makeProviderConfiguration` | **Helper exists; no production call site in `ZoidLockInApp`** |

### 3.3 Socket-blocking path (detail)

```
NEFilterSocketFlow
  → transport (IPPROTO_TCP/UDP → .tcp/.udp; else .other → allow)
  → remotePort (macOS 15+ remoteFlowEndpoint only)
  → hostname (remoteHostname → url.host → endpoint name)
  → ContentFilterEngine.verdict
       → FilterFlowEvaluator(snapshot from FileFilterStatusStore or fallback)
       → DomainFilterRules
  → NEFilterNewFlowVerdict.drop/allow
```

**Non-socket flows** (`handleNewFlow` non-`NEFilterSocketFlow`) are **allowed**. SPEC scopes interception to socket flows; this is acceptable relative to §5.2.

**Port nil behavior:** If port cannot be resolved (notably **pre‑macOS 15**, where `remotePort` always returns `nil`), `FilterFlowEvaluator` does **not** early-allow; it proceeds to hostname rules. That means:

- Missing hostname on TCP/UDP with nil port → **drop** (fail-closed).
- Verified non-blacklisted hostname with nil port → **allow**.
- Verified blacklisted hostname with nil port → **drop**.

So unknown-port TCP/UDP is treated as **inspect-by-default**, which is stricter than “only these four ports,” and is covered by unit tests (`unknownPortFailClosed`). On macOS 15+, known non-inspected ports (e.g. 22) correctly allow even with blacklisted hostnames.

### 3.4 Pass token / “privileged cache”

SPEC §5.2: “no active pass token is verified in the **privileged cache**.”

Implementation:

- Daemon publishes `FilterEnforcementSnapshot` via `FilterPolicyHub` and **`FileFilterStatusStore`** (`/var/db/zoidlockin/filter_status.json`, mode `0600`).
- Filter attaches `FileFilterStatusStore` in `startFilter` when no injected reader is present.
- Missing/unreadable file → `.lockedDown` snapshot (**fail-closed**).
- Comments forbid UI writes and control RPCs from the filter.

This is a **cross-process privileged file cache**, not an in-memory cache shared with the sysex. Functionally correct for fail-closed; residual risk is **file-system permission / path isolation** between root daemon and Network Extension sandbox (must be validated on a real signed install). Not a SPEC logic miss, but an integration hazard.

### 3.5 Findings — Filter

| ID | Severity | Finding |
| --- | --- | --- |
| F-1 | **High (integration)** | `ContentFilterActivation` is not invoked from `ZoidLockInApp`. Socket blocking cannot engage in a shipped UI flow until activation is wired. |
| F-2 | **Medium** | `remotePort` requires macOS 15+. On macOS 14 (package minimum), port is always nil → inspect-by-default for all TCP/UDP, not only {80,443,8080,1080}. |
| F-3 | **Low** | Directory is named `ZoidLockInFilterExtension`, not `ZoidLockInFilter` as in the audit request / some docs. |
| F-4 | **Info** | Blacklist is richer than SPEC examples (CDNs, WhatsApp/Telegram, etc.) — intentional hardening, not a regression. |

---

## 4. SPEC §5.1 — XPC Protocol Interface

### 4.1 Spec surface vs implemented surface

| SPEC §5.1 method | Implemented equivalent | Match |
| --- | --- | --- |
| `applyPolicy(domains:processSignatures:withReply:(Bool))` | `applyPolicy(_ snapshotJSON: Data, withReply:(NSError?))` → `EnforcementPolicySnapshot` | **Drift** — structured snapshot (domains + process matcher + mode + ports), errors instead of Bool |
| `openTemporaryPass(target:durationSeconds:withReply:(Bool))` | `openPassWithKind(_:durationSeconds:nonce:)` + **`redeemAmenityVoucher`** | **Drift** — amenity requires HMAC voucher; bare open is emergency-only / voucher-gated |
| `revokePass(target:withReply:(Bool))` | `revokePassWithKind(_:)` | **Drift** — `PassKind` enum, not free-form target string |
| `queryEnforcementStatus(withReply:(EnforcementState))` | `queryStatus(withReply:(Data?, NSError?))` → `EnforcementStatus` JSON | **Semantic match**, type/wire drift |
| `engageEmergencySafetyValve(withReply:(Bool))` | `engageEmergencySafetyValve(withReply:(NSError?))` | **Semantic match** |
| *(not in SPEC)* | `heartbeat` | **Extension** (required by §2.5 / Slice 2 fail-closed) |
| *(not in SPEC)* | `queryUnleviedEmergencyIncidents` / `markEmergencyIncidentLeviedWithUUID` | **Extension** (ledger coupling) |

Protocol naming:

- Swift service: `ZoidLockInEnforcementServicing` (SPEC name `ZoidLockInEnforcementProtocol` is close; ObjC wire type is `ZoidLockInEnforcementXPC`).

### 4.2 Client / server pairing

- **Server:** `EnforcementXPCListener` + `EnforcementXPCExporter` in Enforcer, started from `ZoidLockInDaemonMain.startMachServiceListener()` on Mach service `com.mavoid.zoidlockin.enforcement`.
- **Client:** `XPCEnforcementClient` used by `ZoidLockInApp` (`resume()` + `startHeartbeatLoop()` at 1.0s).

Mutual code-signing pins:

- Daemon admits clients with Team-ID-pinned requirement for `com.mavoid.zoidlockin`.
- Client sets daemon requirement for `com.mavoid.zoidlockin.helper`.

### 4.3 Findings — IPC API

| ID | Severity | Finding |
| --- | --- | --- |
| X-1 | **Medium (spec drift)** | SPEC §5.1 is stale relative to the voucher/heartbeat/incident API. Docs should be updated to the ObjC/`ZoidLockInEnforcementXPC` surface. |
| X-2 | **Positive** | Amenity `openPass` without voucher throws `amenityPassRequiresVoucher` — stronger than SPEC’s simple `openTemporaryPass`. |
| X-3 | **Info** | Reply channel uses `NSError?` / JSON `Data` rather than Bool/`EnforcementState` named types from SPEC. |

---

## 5. Focus Area: SMAppService Registration

### 5.1 Spec requirements

From SPEC §1.1 / §2.5 (referenced by Wave‑1) and §5 packaging context:

- Register via `SMAppService.daemon(plistName:)` (macOS 13+).
- Label `com.mavoid.zoidlockin.helper`.
- `KeepAlive: true`, `ThrottleInterval: 1`.
- `MachServices` advertises `com.mavoid.zoidlockin.enforcement`.
- Does **not** use obsolete `SMJobBless`.

### 5.2 Evidence of compliance

**`DaemonServiceRegistrar`** (`Sources/ZoidLockInEnforcer/DaemonServiceRegistrar.swift`):

- Explicitly documents modern `SMAppService.daemon` and rejects SMJobBless.
- `makeService()` → `SMAppService.daemon(plistName:)`.
- `register()` / `unregister()` / `status` / `validateForRegistration()`.

**`DaemonConfiguration`** (`Sources/ZoidLockInCore/DaemonConfiguration.swift`):

- Defaults: KeepAlive true, ThrottleInterval 1, MachServices enable enforcement Mach name.
- `validate()` fails if KeepAlive false, ThrottleInterval ≠ 1, or MachServices missing.

**Bundled plist** (`Resources/com.mavoid.zoidlockin.helper.plist`):

```xml
Label = com.mavoid.zoidlockin.helper
BundleProgram = Contents/MacOS/ZoidLockInDaemon
KeepAlive = true
RunAtLoad = true
ThrottleInterval = 1
MachServices.com.mavoid.zoidlockin.enforcement = true
```

Matches SPEC and `DaemonConfiguration` defaults. Unit tests assert plist ↔ configuration parity (`DaemonConfigurationTests`).

**Daemon boot** (`ZoidLockInDaemonMain`): applies `.lockedDown`, starts sentinel + Mach listener, logs KeepAlive/ThrottleInterval/MachService — consistent with fail-closed respawn model.

### 5.3 Gaps

| ID | Severity | Finding |
| --- | --- | --- |
| S-1 | **High (integration)** | No production call site invokes `DaemonServiceRegistrar.register()`. `ZoidLockInApp` depends on Core/Economy/IPC only — **not** Enforcer — so it cannot call the registrar without a new dependency or shared registration helper. `EnforcementDaemon` holds a `registrar` instance but never calls `register()`. |
| S-2 | **Medium (packaging)** | SMAppService requires the plist at `App.app/Contents/Library/LaunchDaemons/<plistName>`. This audit confirmed the plist exists under `Resources/`; **app-bundle packaging layout** for a real `.app` was not verified as a built product in this pass. |
| S-3 | **Low** | Registration is available and validated; tests cover invalid config rejection before register. |

### 5.4 Verdict

**Configuration and registrar API: compliant.**  
**End-to-end registration from the unprivileged app: not wired.** Treat as incomplete Slice‑1 product integration, not as missing SMAppService design.

---

## 6. Focus Area: Process Kill Loop (`SIGSTOP` / `SIGKILL` / `killpg`)

### 6.1 Spec requirements

From SPEC §2.5 (enforcement behavior that Wave‑1 must verify alongside §5):

- Scan every **1.5 seconds**.
- Match `proc_name` and `proc_pidpath` against launchers, helpers, Wine/GPTK wrappers.
- Without authorized pass: `SIGSTOP` then `SIGKILL` to process, and `killpg` to process group.

### 6.2 Implementation mapping

**Cadence:** `ProcessSentinel.defaultScanInterval = 1.5`; timer scheduled with 100ms leeway.

**Enumeration:** `DarwinProcessRuntimeController.listRunningProcesses()` uses `proc_listpids`, `proc_name`, `proc_pidpath`.

**Matching:** `ProcessTargetMatcher` — name equality / Electron helper prefixes / `.app/` path needles / `steamapps/common/` game paths. Default targets include Steam, Discord Canary/PTB helpers, Battle.net, Epic, Riot, Wine stack, CrossOver, Whisky, GPTK, major game binaries.

**Signal sequence** (`scanAndTerminate`):

1. Per matched PID: `SIGSTOP`, then `SIGKILL`.
2. Resolve `getpgid`; if `pgid > 1` and not sentinel’s own pgrp: `killpg(SIGSTOP)` then `killpg(SIGKILL)`.
3. Skips PID ≤ 1 and own PID.

**Pass overlay:**

- If mode ≠ `.hard` **or** any active pass with `relaxesProcessTermination` (`.emergency`, `.gaming`) → **no kills**.
- Food/phone/streaming passes keep process kills hard while relaxing only their domain suffixes — matches product intent beyond raw SPEC wording.

### 6.3 Evidence from tests

`ContentFilterAndSentinelTests` / Slice adversarial suites assert:

- `sentSignals[pid] == [SIGSTOP, SIGKILL]`
- Process-group SIGKILL for launcher children
- Gaming/emergency overlays pause kills

### 6.4 Findings — Sentinel

| ID | Severity | Finding |
| --- | --- | --- |
| P-1 | **Compliant** | SIGSTOP→SIGKILL + killpg + 1.5s + proc_name/path matching implemented as specified. |
| P-2 | **Info** | Matching is name/path based, not code-signature based (documented as backstop). Outside SPEC Wave‑1 wording, but worth noting for evasion. |
| P-3 | **Info** | After SIGKILL, process group signaling may race with PID reuse; mitigated by pgid checks and short scan interval. |

### 6.5 Verdict

**Compliant** with SPEC process-sentinel requirements.

---

## 7. Focus Area: Fail-Closed Behavior

### 7.1 Spec requirements

- KeepAlive + ThrottleInterval=1 → auto-respawn.
- If communication with app lost **> 5 seconds** (Slice 2 heartbeat), reapply full lockdown.
- Filter: unverified hostnames on inspected ports → drop.
- Boot / lost state must not leave open amenities.

### 7.2 Implemented fail-closed controls

| Control | Mechanism | Status |
| --- | --- | --- |
| Boot lockdown | `ZoidLockInDaemonMain` → `daemon.applyPolicy(.lockedDown)` before start | **Met** |
| KeepAlive respawn | Plist + configuration validation | **Met** (config); registration wiring gap S-1 |
| Heartbeat timeout 5s | `HeartbeatMonitor.timeoutSeconds = 5.0`; client beats every 1.0s | **Met** |
| Connection death | `noteConnectionLost` sets `forceTimedOut` → immediate timeout | **Stricter than** “> 5 seconds” |
| Relock on timeout | If heartbeat timed out and no active pass → `basePolicy = .lockedDown` | **Met** |
| Pass preserves unlock during heartbeat loss | Emergency/amenity passes keep overlay until monotonic expiry | **Met** (intentional; tested) |
| Monotonic rollback | Observed clock going backwards → revoke passes + lockedDown | **Extra hardening** |
| Curfew | Civil clock revokes curfew-sensitive passes | **Extra** (ties to economy invariants) |
| Amenity XPC without voucher | Throws; cannot mint pass | **Met** |
| Filter missing status file | `.lockedDown` | **Met** |
| Filter default policy | `.lockedDown` | **Met** |
| Calibration mode | Verified blacklist → softInfraction allow+log; **unverified still drop** | **Met** fail-closed for identity |
| Emergency not restored across reboot | Incidents/cooldown restore; emergency pass itself does not resume | **Met** (main comments + journal restore rules) |

### 7.3 Findings — Fail-closed

| ID | Severity | Finding |
| --- | --- | --- |
| C-1 | **Compliant** | Heartbeat + boot + filter identity + voucher gates form a coherent fail-closed story. |
| C-2 | **Info** | Connection drop fails closed **immediately**, not after 5s. Safer than SPEC; document the difference. |
| C-3 | **Residual risk** | Filter status file must remain unwritable by the UI sandbox; design intends daemon-only writes — verify on device. |
| C-4 | **Residual risk** | If Team ID resolves to placeholder `TEAMID`, gatekeeper may reject all real clients or behave insecurely in unsigned-dev modes — `CodeRequirement` treats `TEAMID` as a special placeholder; production must supply a real Team ID. |

### 7.4 Verdict

**Compliant** with fail-closed intent; several controls exceed SPEC.

---

## 8. Focus Area: `audit_token_t` Client Verification

### 8.1 Spec requirements

From SPEC §1.1 (and Slice 2 gate referenced by §5 / roadmap):

- Mach-O XPC listener validates client identity using **`audit_token_t`** and **`SecCodeCheckValidity`**.
- Team-ID-pinned requirement of the form:  
  `anchor apple generic and certificate leaf[subject.OU] = TEAMID and identifier "com.mavoid.zoidlockin"`.
- `MachServices` advertises `com.mavoid.zoidlockin.enforcement` **together with** that validation.

### 8.2 Implementation mapping

| Step | Code | Status |
| --- | --- | --- |
| Extract token from connection | `AuditTokenExtraction.data(fromConnection:)` via KVC `"auditToken"` | **Met** |
| Reject missing/wrong-size token | Gatekeeper `missingAuditToken` | **Met** |
| Guest from audit token (not PID) | `SecCodeCopyGuestWithAttributes` + `kSecGuestAttributeAudit`; PID ignored in `evaluate` | **Met** |
| Signature validity | `SecCodeCheckValidity(guest, [], nil)` | **Met** |
| Requirement check | `SecRequirementCreateWithString` + `SecCodeCheckValidity(..., requirement)` | **Met** |
| Team ID + identifier equality | Explicit mismatch rejections after requirement | **Met** |
| Requirement string safety | Sanitization; reject `or` clauses; `isTeamIDPinned` | **Met** (stronger than SPEC) |
| NSXPC pinning | Listener `setCodeSigningRequirement` when pinned; client pins daemon | **Met** |
| Audit log | `XPCConnectionAuditLog` records accept/reject | **Met** |
| MachServices | Plist + DaemonConfiguration | **Met** |

### 8.3 Findings — Auth

| ID | Severity | Finding |
| --- | --- | --- |
| A-1 | **Compliant** | Full `audit_token_t` → SecCode guest → Team-ID-pinned requirement path is implemented and unit-tested. |
| A-2 | **Positive** | Explicit rejection of `anchor apple generic` without `subject.OU` (confused-deputy hole). |
| A-3 | **Medium (ops)** | Unsigned / placeholder Team ID path needs a clear production gate; otherwise admission fails closed (good) or uses placeholder (dev-only). |
| A-4 | **Info** | Filter is intentionally **not** on the control XPC protocol; it is query-only via status file. Aligns with protocol comments. |

### 8.4 Verdict

**Compliant** — this is one of the strongest areas relative to SPEC.

---

## 9. SPEC §3 — Database Schema vs Enforcement Authority

Section 3 is primarily the **user-space SQLite/GRDB** model. Wave‑1 enforcement must be checked for coupling: whether amenity passes / audit events in §3 drive or undermine privileged enforcement.

### 9.1 Spec §3 tables relevant to enforcement

| Table | Spec role | Enforcement relevance |
| --- | --- | --- |
| `active_amenity_passes` | ACTIVE/EXPIRED/REVOKED passes with `amenity_type`, `expires_at` | Would be a **user-writable** pass oracle if trusted by daemon/filter |
| `admin_audit_events` | ADMIN_LOGIN, EMERGENCY_OVERRIDE, etc. | Audit trail for safety valve |
| `wallet_transactions` / `system_state` | Economic state feeding purchases | Indirect (purchase → voucher → daemon) |
| Indexes on `active_amenity_passes(status)` | Fast pass queries | N/A if table absent |

### 9.2 What the codebase actually does

1. **`DaemonLocalPass` docs (authoritative):**  
   > “Amenity / emergency pass kind. Daemon-owned; user-space SQLite is not consulted.”  
   > “clients cannot supply `expires_at`.”

2. **Pass lifetime:** Monotonic continuous time in `DaemonPassController`; amenity mint via **`AmenityPassVoucher`** HMAC redemption over XPC; durable **`RedemptionJournal`** under `/var/db/zoidlockin`.

3. **Emergency:** Durable **`EmergencyIncidentRecord`** store in privileged directory; user-space ledger **consumes** incidents over authenticated XPC (`queryUnleviedEmergencyIncidents` / `markEmergencyIncidentLevied`) — reverse of trusting SQLite.

4. **`SQLiteEconomicLedger` DDL:** Implements wallet/focus/meetings/habits/governance/calibration tables. **Does not create** `active_amenity_passes`, `system_state` (as single-row SPEC DDL), or `admin_audit_events` exactly as written in §3.1. Amenity economics use catalog + ledger transactions + marketplace coordinator, not the SPEC pass table.

5. **Package boundary:** `ZoidLockInDaemon` must not depend on `ZoidLockInEconomy` / SQLite — enforced in `Package.swift`.

### 9.3 Mapping SPEC amenity types → `PassKind`

| SPEC `amenity_type` | Implementation `PassKind` / `AmenityKind` |
| --- | --- |
| `FOOD_PASS` | `.food` |
| `PHONE_PASS` | `.phone` |
| `STREAMING_PASS` | `.streaming` |
| `GAMING_PASS` | `.gaming` |
| `EMERGENCY_PASS` | `.emergency` (safety valve, not voucher amenity) |

Naming drifted from SCREAMING_SNAKE SQL enums to lower-case Swift enums — fine if documented.

### 9.4 Findings — Section 3 vs enforcement

| ID | Severity | Finding |
| --- | --- | --- |
| D-1 | **High (spec drift)** | SPEC §3.1 `active_amenity_passes` is **not** implemented and **must not** become the filter/daemon source of truth. Implementation correctly uses privileged pass state. **Update SPEC §3** to describe ledger debit + voucher + daemon journal, or mark the table as user-space UI cache only. |
| D-2 | **Medium (spec drift)** | Broader §3.1 DDL (e.g. `system_state`, `admin_audit_events`, column names) diverges from `SQLiteEconomicLedger`. Out of Wave‑1 runtime risk if daemon ignores SQLite — which it does. |
| D-3 | **Positive** | Keeping SQLite out of the helper prevents a trivial “edit expires_at in db.sqlite” bypass. |
| D-4 | **Info** | Curfew invariant in §4.2 (no amenity insert 22:00–04:00) is enforced on the **daemon redeem path** (`curfewActive` / duration clip) in addition to any user-space checks. |

### 9.5 Verdict for §3

For Wave‑1 **enforcement security**, the divergence is **good**. For **spec fidelity**, Section 3 is **out of date** relative to the privileged pass architecture that §5 depends on.

---

## 10. Cross-Cutting Architecture Checks

### 10.1 Three-process separation

| Process | Identity | Hosts filter? | Hosts sentinel? | Hosts XPC server? |
| --- | --- | --- | --- | --- |
| App | `com.mavoid.zoidlockin` | Activates (intended) | No | Client |
| Helper daemon | `com.mavoid.zoidlockin.helper` | **No** | **Yes** | **Yes** |
| Filter sysex | `com.mavoid.zoidlockin.filter` | **Yes** | No | No (query-only status) |

Matches SPEC §1 topology and Package.swift comments. **PRD.md still incorrectly says the daemon hosts `NEFilterDataProvider`** — documentation debt outside SPEC §3/§5 but relevant to Wave‑1 clarity.

### 10.2 App wiring snapshot (affects §5.2 / SMAppService)

`ZoidLockInApp` **does**:

- Construct `XPCEnforcementClient`, `resume()`, `startHeartbeatLoop()`.
- Redeem vouchers via `MarketplaceCoordinator(redeemer: client)`.
- Push policy snapshots on blocklist changes (`applyPolicy`).

`ZoidLockInApp` **does not** (observed):

- Call `DaemonServiceRegistrar.register()`.
- Call `ContentFilterActivation` / `NEFilterManager` save-and-enable path.
- Depend on `ZoidLockInFilterExtension` or `ZoidLockInEnforcer` products.

### 10.3 Test coverage relevant to Wave‑1

Present and substantive:

- `ContentFilterAndSentinelTests` — drop/allow, UDP/443, fail-closed, SIGSTOP/SIGKILL/killpg  
- `XPCAuditTokenGatekeeperTests` — Team ID pin, admit/reject  
- `DaemonConfigurationTests` — SMAppService plist validity  
- Emergency/heartbeat suites — timeout relock, pass preservation  
- Slice adversarial suites — voucher / gaming overlay behavior  

Absent / limited in-repo:

- Live `NEFilterManager` activation integration test against a running sysex  
- Live `SMAppService.register()` end-to-end under a signed `.app`  

---

## 11. Consolidated Findings Table

| ID | Area | Severity | Spec ref | Summary |
| --- | --- | --- | --- | --- |
| S-1 | SMAppService | High | §1.1 / Slice 1 | Registrar exists; **no app `register()` wiring** |
| F-1 | Filter activation | High | §5.2 | **`ContentFilterActivation` unused by app** |
| D-1 | Schema vs authority | High (docs) | §3.1 | `active_amenity_passes` not used; daemon journal is SoT |
| X-1 | XPC API | Medium | §5.1 | Method signatures / types drifted; behavior richer |
| F-2 | Port extraction | Medium | §5.2 | Port only on macOS 15+; nil-port inspect-by-default on 14 |
| S-2 | Packaging | Medium | §1.1 | Confirm plist lands in `Contents/Library/LaunchDaemons/` in built app |
| A-3 | Team ID ops | Medium | §1.1 | Placeholder `TEAMID` must not ship |
| C-2 | Heartbeat | Info | §2.5 | Connection loss immediate fail-closed vs 5s wording |
| P-1 | Sentinel | OK | §2.5 | Kill loop compliant |
| A-1 | Audit token | OK | §1.1 / Slice 2 | Compliant |
| C-1 | Fail-closed | OK | §5.2 / §2.5 | Compliant |
| F-4 | Blacklist | Info | §5.2 | Superset of example domains |

---

## 12. Compliance Scorecard (Wave‑1 Focus)

| Focus | Score | Notes |
| --- | --- | --- |
| SMAppService registration | **60%** | Design + plist + API solid; call-site / packaging incomplete |
| Process kill loop | **98%** | Matches SPEC; extras for Wine/GPTK/path needles |
| NEFilter socket blocking | **75%** | Verdict engine compliant; activation wiring + port-on-14 gaps |
| Fail-closed behavior | **95%** | Boot, heartbeat, filter identity, vouchers |
| `audit_token_t` verification | **98%** | Full SecCode path + mutual pinning |
| SPEC §5.1 literal API match | **40%** | Semantic coverage high; literal signatures low |
| SPEC §3 pass-table match | **15%** | Intentionally replaced by privileged model |

**Weighted Wave‑1 enforcement readiness (logic):** ~**85–90%**.  
**Wave‑1 product integration readiness (register + activate filter):** ~**55–65%** until S-1 and F-1 are closed.

---

## 13. Recommended Remediation Order (advisory; not performed)

1. **Wire SMAppService registration** from the unprivileged app (or a thin host helper that can import ServiceManagement + Enforcer), including user approval UX and status surfacing.
2. **Wire `ContentFilterActivation`** + system-extension approval flow; set `disableEncryptedDNSSettings` on macOS 15+.
3. **Update SPEC §5.1** to the real `ZoidLockInEnforcementXPC` methods (voucher, heartbeat, incidents, JSON snapshots, `NSError` replies).
4. **Update SPEC §3** to remove or demote `active_amenity_passes` as enforcement SoT; document voucher + `/var/db/zoidlockin` journal.
5. **Port extraction fallback** for macOS 14 (or raise deployment target to 15 if endpoint APIs are mandatory).
6. **Production Team ID** gating — refuse to run enforcement admission with placeholder `TEAMID`.

---

## 14. File-Level Traceability Index

| Concern | Primary files |
| --- | --- |
| Daemon entry / boot fail-closed | `Sources/ZoidLockInDaemon/ZoidLockInDaemonMain.swift` |
| Policy / heartbeat / pass publish | `Sources/ZoidLockInEnforcer/EnforcementDaemon.swift` |
| SIGSTOP/SIGKILL/killpg | `Sources/ZoidLockInEnforcer/ProcessSentinel.swift` |
| SMAppService | `Sources/ZoidLockInEnforcer/DaemonServiceRegistrar.swift`, `Sources/ZoidLockInCore/DaemonConfiguration.swift`, `Resources/com.mavoid.zoidlockin.helper.plist` |
| XPC admit | `Sources/ZoidLockInEnforcer/EnforcementXPCListener.swift`, `Sources/ZoidLockInIPC/XPCAuditTokenGatekeeper.swift`, `Sources/ZoidLockInIPC/AuditTokenExtraction.swift` |
| XPC client | `Sources/ZoidLockInIPC/XPCEnforcementClient.swift` |
| Filter provider | `Sources/ZoidLockInFilterExtension/ContentFilterProvider.swift` |
| Filter activation helper | `Sources/ZoidLockInFilterExtension/ContentFilterActivation.swift` |
| Hostname / fail-closed rules | `Sources/ZoidLockInCore/DomainFilterRules.swift`, `Sources/ZoidLockInCore/FilterFlowEvaluator.swift` |
| Pass kinds / no SQLite SoT | `Sources/ZoidLockInCore/DaemonLocalPass.swift` |
| Filter status IPC (file) | `Sources/ZoidLockInCore/FilterEnforcementStatus.swift` |
| Identity / Mach / requirements | `Sources/ZoidLockInCore/ZoidLockInIdentity.swift`, `Sources/ZoidLockInCore/CodeRequirement.swift` |
| Heartbeat timeout | `Sources/ZoidLockInCore/HeartbeatMonitor.swift` |

---

## 15. Conclusion

Wave‑1’s **privileged enforcement core** — process sentinel signaling, Network Extension verdict engine (TCP/UDP, inspected ports, hostname fail-closed), heartbeat-driven lockdown, and `audit_token_t` + Team-ID-pinned XPC — is implemented in the audited modules and is broadly aligned with SPEC §5 security intent (and §2.5 operational requirements).

The largest gaps are **not** missing kill/filter algorithms, but:

1. **Host integration** (SMAppService `register()` and `NEFilterManager` activation unused by the app), and  
2. **Specification drift** (§5.1 method shapes; §3 amenity pass table vs daemon-owned vouchers/journal).

Closing S-1 and F-1, then refreshing SPEC §3/§5.1 to match the privileged model, would bring documentation and product wiring in line with an already strong enforcement engine.
