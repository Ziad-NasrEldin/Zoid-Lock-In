# Product Specification: Zoid Lock In ("The Trading Center")

## 1. System Vision & Behavioral Philosophy

The **Zoid Lock In** application (featuring **The Trading Center**) is an uncompromising, standalone local-first personal economy system engineered to permanently eliminate procrastination, eradicate digital distraction, and enforce daily high-output discipline.

### 1.1. Product Lineage & Scope
- **Independent Standalone Product:** Zoid Lock In is an entirely separate, standalone application with its own dedicated lifecycle and codebase, rather than a feature branch or submodule of Zoid 0.
- **Integrated Zoid 0 Technology:** While architecturally independent, Zoid Lock In directly integrates and builds upon the proven time-tracking engines, duration counters, workspace observation logic, and session timer mechanisms pioneered in Zoid 0. It connects those precise measurement primitives directly to credit minting and hard system lockdowns.

### 1.2. Core Axioms
1. **Zero-Baseline Daily Reset:** Every sunrise begins at **0 credits**. Past victories do not fund today's idleness.
2. **Artificial Scarcity:** Amenities, entertainment, non-essential screen time, food delivery, and basic living comforts must be actively purchased with earned credits.
3. **Hard Digital Enforcement:** Distractions are blocked at the operating system and network level by default. Willpower is replaced by automated system barriers.
4. **Permanent Anti-Cheating Governance:** Accessing configuration or price-tuning controls requires multi-factor authentication and triggers automatic accountability alerts.
5. **Recovery Protection:** Pacing and curfew guardrails prevent late-night binging and maintain circadian health.

---

## 2. The Economic Engine (Earning & Minting)

```mermaid
flowchart TD
    DayStart["00:00: Day Begins (0 Credits)"] --> MorningBlock["Morning 90-Min Focus Block"]
    MorningBlock --> MomentumBonus["Award Base (1.5) * 2.0x Multiplier = 3.0 Credits"]
    
    WorkSession["Standard Deep Work (Zoid 0 Auto-Track)"] --> RegularEarn["+1.0 Credit / Hour (0.5 / 30 min)"]
    OfflineMeeting["Offline Meeting (Punch-In/Out + Mandatory Evidence)"] --> MeetingEarn["Verified Duration Converted to Credits"]
    MicroTasks["Custom Micro-Tasks (e.g., Brushing Teeth = +0.25)"] --> MicroEarn["Instant Milestone Addition"]
    
    MomentumBonus --> DailyWallet["Active Daily Wallet"]
    RegularEarn --> DailyWallet
    MeetingEarn --> DailyWallet
    MicroEarn --> DailyWallet
    
    DailyWallet --> Buy["Purchase Amenities (Before 22:00 Curfew)"]
    Buy --> TimedUnlock["Temporary Hard Unlock Window"]
    TimedUnlock --> Relock["Auto-Relock upon Window Expiry"]
    
    DailyWallet --> Midnight["23:59:59 Midnight Reconciliation"]
    Midnight --> Vault["Surplus Credits Logged to Permanent Dashboard Vault"]
    Midnight --> Streak["Increment Daily Victory Streak Score"]
```

### 2.1. Standard Earning Model
- **Base Velocity:** 1 hour of verified deep work = **1.0 Credit**.
- **Fractional Milestones:** 30 minutes of continuous focus = **0.5 Credits**.
- **Daily Target Volume:** 6.0 to 10.0 Credits daily to afford full living amenities and recreation.

### 2.2. The 90-Minute Momentum Rule (Cold-Start Breaker)
To resolve the morning cold-start dilemma and create immediate forward momentum:
- **Condition:** Completing the day's first continuous, uninterrupted **90-minute focus block** (1.5 hours of work).
- **Reward:** Applies a multiplicative **2.0x multiplier** (double rate) to the session's earnings: 1.5 base credits × 2.0 = **3.0 credits** earned.
- **Impact:** Immediately accelerates early-day momentum, securing 3.0 credits which fully satisfies the daily bed amenity or multiple midday rest cycles right from the morning block.

### 2.3. Dual-Gate Offline Meeting Verification
For professional commitments occurring off-screen (in-person client meetings, physical strategy sessions, on-site tasks):
1. **Gate 1 (Time Tracking):**
   - User triggers **Punch-In** at the exact start time.
   - User triggers **Punch-Out** immediately upon conclusion.
2. **Gate 2 (Mandatory Verification Bundle):**
   - Credits remain in a **Pending Audit** state until the following three artifacts are attached:
     1. **Agenda & Summary Note:** Bulleted record of meeting objectives and outcomes.
     2. **Physical / Digital Documentation:** Formal receipt, invoice, signed memo, or calendar invite.
     3. **Contextual Photo:** Physical timestamped photo of the meeting location or environment.
- **Resolution:** Once both gates are fulfilled, duration is credited directly to the active daily balance.

### 2.4. Customizable Micro-Habits & Daily Discipline Tasks
To incentivize essential personal hygiene, wellness, and baseline discipline routines:
- **Concept:** Quick, non-work habits that anchor the day award small fractional credits (e.g., +0.25 credits).
- **Customization Engine:** The user can add, edit, value-scale, and toggle tasks directly via the 2FA Admin Dashboard.
- **Representative Catalog:**
  | Micro-Task | Reward Value | Daily Frequency Limit |
  | :--- | :--- | :--- |
  | **Brushing Teeth / Dental Routine** | +0.25 Credits | Max 2 / Day (Morning & Night) |
  | **Making Bed / Room Reset** | +0.25 Credits | Max 1 / Day |
  | **Daily Hydration Goal (2L Water)** | +0.25 Credits | Max 1 / Day |
  | **Physical Movement / Stretching (15m)** | +0.50 Credits | Max 1 / Day |
- **Anti-Exploitation Safeguards:**
  - Strict daily frequency caps per task prevent credit spamming.
  - Overall micro-habit earnings are capped at a maximum of **1.5 credits total per day**, ensuring that the remaining core credits must be produced through genuine deep work.

---

## 3. Hard Digital Enforcement Matrix

Distractions are disabled on macOS and paired iOS devices by default.

### 3.1. Desktop Process Lockdown (macOS)
- **Target Applications:** Steam, Discord, Battle.net, Epic Games Launcher, Riot Client, and standalone gaming executables.
- **Mechanism:** Background enforcement daemon continuously monitors running processes, immediately suspending or terminating unauthorized target instances unless an active purchase token is active.

### 3.2. Web Domain & Network Lockdown
- **Target Domains:** `youtube.com`, `reddit.com`, `facebook.com`, `instagram.com`, `x.com` (Twitter), `tiktok.com`, `twitch.tv`, `netflix.com`.
- **Mechanism:** System-level host/packet routing or Zoid 0 companion browser shield. Blocked destinations render a clean Zoid 0 "Trading Center: Access Locked" screen.

### 3.3. Cross-Device Closure (Apple Shortcuts & Focus Mode)
- **Problem:** Desktop locks cause subconscious redirection to mobile screens.
- **Solution:** Bi-directional Apple Shortcuts and native macOS/iOS Focus Filter automation.
- **Action:**
  - Initiating focus sessions in Zoid 0 triggers **Work Mode** across macOS and iOS via iCloud sync.
  - Silences all notifications and locks mobile social apps.
  - Purchasing mobile passes temporarily disengages the mobile focus shield for the exact purchased duration.

---

## 4. The Marketplace & Amenity Catalog

### 4.1. Calibrated Pricing Schedule

| Tier | Amenity Item | Target Cost | Enforcement Mechanism |
| :--- | :--- | :--- | :--- |
| **Baseline Comfort** | Sleeping in Bed | 3.0 Credits | Self-enforced behavioral contract (Alternative: floor / couch) |
| **Food & Convenience** | Ordering Food Delivery (Uber Eats, Talabat) | 2.5 Credits | Pass required before placing order |
| **Digital Distraction** | 1 Hour Phone / Social Browsing | 1.5 Credits | Apple Focus Mode temporary release (60 min) |
| **Streaming / Video** | 1 Hour YouTube / Entertainment Video | 1.5 Credits | Network domain unblock window (60 min) |
| **Gaming** | 30 Minutes Gaming Session | 1.5 Credits | macOS process barrier release (30 min) |
| **Social / Outings** | Going Out with Friends / Dinner Outing | 5.0 Credits | Major milestone unlock; requires substantial daily focus |
| **Guilt-Free Rest** | 30-Minute Midday Break | 0.5 Credits | Rest timer without screen distractions |

---

## 5. Curfew, Expiration & The Permanent Vault

### 5.1. 10:00 PM (22:00) Curfew Lockout
- All entertainment, gaming, social media, and food delivery purchases are strictly disabled at **22:00:00**.
- Eliminates late-night credit dumping, binge-gaming, and disordered sleep patterns.

### 5.2. Midnight Expiration & Reconciliation
- At **23:59:59**, the active daily wallet balance is reconciled to **0.0**.
- **The Permanent Surplus Vault:** Surplus unspent credits do not disappear into a void; they are logged into a permanent **"Lifetime Surplus Vault"** displayed on the Zoid 0 dashboard. This creates long-term pride of discipline and reserves optionality for future long-term expansions.
- **Daily Victory Streak Score:** Finishing the day with the daily target met (all baseline amenities paid and zero deficit) increments the consecutive **Victory Streak**.

---

## 6. High-Friction Anti-Cheating Protocol (Admin Gateway)

To protect the user from impulsive mid-day weakness, adjusting prices, modifying credit balances, or disabling enforcement requires passing a three-tiered security barrier:

```mermaid
sequenceDiagram
    actor User as User
    participant Dash as Admin Config Dashboard
    participant Auth as Google Authenticator (TOTP)
    participant Mail as Transactional Mail Service

    User->>Dash: Requests Access to Settings / Ledger
    Dash->>User: Prompts 12+ Character High-Complexity Password
    User->>Dash: Submits Password
    Dash->>User: Prompts 6-Digit Time-Based TOTP Code
    User->>Auth: Retrieves Code from Google Authenticator
    User->>Dash: Submits 6-Digit Code
    Dash->>Mail: Dispatches Instant Warning Email
    Mail-->>User: "CRITICAL: You entered Admin Dashboard. Stand firm."
    Dash->>User: Unlocks Session (10-Minute Timeout)
```

1. **Password Barrier:** Minimum 12 characters requiring uppercase, lowercase, numbers, and symbols.
2. **Two-Factor Authentication (2FA):** Standard TOTP algorithm verified via **Google Authenticator**.
3. **Psychological Warning Dispatch:** An automated email is instantly sent to the user's personal inbox:
   > *"CRITICAL SECURITY & INTEGRITY ALERT: You have authenticated into the Zoid 0 Trading Center Admin Settings. Remember why you erected these walls: to conquer procrastination and realize your highest potential. Do not lower prices, grant unearned credits, or negotiate with weakness. Any unearned modification is a defeat."*
4. **48-Hour Cooldown Rate-Limit Lock:**
   - Whenever any configuration edit (amenity price, micro-task reward, blocklist rule) is committed, the dashboard enters a strict **48-Hour Read-Only Lockdown**.
   - No further modifications can be made until the 48-hour cooldown window fully expires, extinguishing impulse concessions and emotional bargaining.
   - **Testing & Staging Override:** During the development and pre-production phase, a dedicated developer override flag bypasses the 48-hour lock to allow rapid testing and iteration. This override is permanently disabled upon production release.

---

## 7. Emergency Safety Valve & Next-Day Debt

### 7.1. Zero-Friction Emergency Override
- For genuine crises (medical urgencies, family emergencies, urgent financial matters), an **Emergency Override** button is always accessible without passwords or 2FA.
- Immediately disables all blocks for **30 minutes**.

### 7.2. Accountability Recoil (The 2-Hour Work Debt)
- Triggering the emergency valve immediately dispatches an incident audit email.
- **Next-Day Work Debt:** The following morning begins with a mandatory **-2.0 Credit Deficit (2-Hour Debt)**.
- The user must complete 2 verified hours of deep work simply to return to 0.0 before any credits can be earned for daytime amenities or evening comforts.

---

## 8. Onboarding: The 3-Day Calibration Phase

To ensure sustainability and prevent psychological rejection of the system:
- **Days 1 to 3 (Audit & Calibration):**
  - All tracking, punch-in timers, and credit ledgers run actively on-screen.
  - Hard blockers operate in **Soft Warning Mode** (displaying warnings and tracking infractions without forcibly killing processes).
  - Validates that daily schedules reliably generate 6–10 hours of verified work.
- **Day 4 Onward (Full Hard Lockdown):**
  - Enforcement daemon engages absolute system-level process killing and domain blacklisting.

---

## 9. System Architecture & Zoid 0 Integration Map

- **Standalone Platform:** Native macOS desktop application (Swift 6, SwiftUI) packaged and versioned independently as **Zoid Lock In**.
- **Design Standard:** **SUMI-E Ink** visual aesthetic (paper/ink tones, restrained seal-red accents, serif headers).
- **Integrated Zoid 0 Technology:**
  1. *Screenwatch & Session Tracker:* Adopts Zoid 0's native workspace session tracking and application-level duration measurement primitives to verify deep work without manual timesheets.
  2. *Meeting Infrastructure:* Adopts Zoid 0's meeting verification logic for offline work logging and proof attachment.
- **Dedicated Zoid Lock In Modules:**
  1. `TradingCenterView`: Live wallet balance, active lock statuses, catalog grid, and purchase triggers.
  2. `EnforcementDaemon`: Background observer managing process termination and domain shield enforcement.
  3. `OfflineSessionCoordinator`: Punch-in/out timer with evidence file dropzone.
  4. `SecurityGatekeeper`: Password hashing, Google Authenticator TOTP verification, and automated alert email dispatcher.
  5. `CooldownManager`: Enforces the 48-hour configuration rate-limit lockout with development/testing bypass toggles.
  6. `ShortcutBridge`: System-level webhook and Apple Shortcuts sync for cross-device Focus Mode engagement.
