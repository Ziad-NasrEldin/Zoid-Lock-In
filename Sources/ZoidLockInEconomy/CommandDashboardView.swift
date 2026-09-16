import ServiceManagement
import SwiftUI
import ZoidLockInCore

/// Standalone SUMI-E Ink command dashboard: vault, ledger, 2FA settings.
public struct CommandDashboardView: View {
    public var snapshot: CommandDashboardSnapshot
    public var onUnlock: ((String, String) -> Void)?
    public var onLock: (() -> Void)?
    public var onEnroll: ((String, String, String, String) -> Void)?
    public var onTriggerEmergencyValve: (() -> Void)?

    @State private var tab: CommandDashboardTab
    @State private var filter: LedgerAuditKind
    @State private var search: String
    @State private var page: Int
    @State private var pageSize: Int
    @State private var password: String
    @State private var confirmPassword: String
    @State private var totp: String
    @State private var enrollSecret: String
    @State private var jumpPage: String
    @State private var showingEmergencyConfirmation: Bool = false

    public init(
        snapshot: CommandDashboardSnapshot,
        onUnlock: ((String, String) -> Void)? = nil,
        onLock: (() -> Void)? = nil,
        onEnroll: ((String, String, String, String) -> Void)? = nil,
        onTriggerEmergencyValve: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onUnlock = onUnlock
        self.onLock = onLock
        self.onEnroll = onEnroll
        self.onTriggerEmergencyValve = onTriggerEmergencyValve
        _tab = State(initialValue: snapshot.selectedTab)
        _filter = State(initialValue: snapshot.ledgerPage.filter)
        _search = State(initialValue: snapshot.ledgerPage.search)
        _page = State(initialValue: snapshot.ledgerPage.page)
        _pageSize = State(initialValue: snapshot.ledgerPage.pageSize)
        _password = State(initialValue: "")
        _confirmPassword = State(initialValue: "")
        _totp = State(initialValue: "")
        _enrollSecret = State(initialValue: "")
        _jumpPage = State(initialValue: "\(snapshot.ledgerPage.page)")
    }

    public var body: some View {
        VStack(spacing: 0) {
            commandBar
            statusBanner
            tabRail
            Group {
                switch tab {
                case .overview:
                    overviewPane
                case .ledger:
                    ledgerPane
                case .settings:
                    settingsPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 1200, height: 800, alignment: .topLeading)
        .background(MarketplacePaperBackground())
        .foregroundStyle(SumiInk.ink)
    }

    private var commandBar: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ZOID LOCK IN")
                    .font(SumiInk.caption(11))
                    .tracking(4)
                    .foregroundStyle(SumiInk.inkMuted)
                Text("Command Dashboard")
                    .font(SumiInk.display(28))
                    .foregroundStyle(SumiInk.ink)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(snapshot.clockCaption)
                    .font(SumiInk.body(13))
                    .monospacedDigit()
                    .foregroundStyle(SumiInk.ink)
                Text(snapshot.healthCaption)
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.seal)
            }
            VermilionSeal(text: "鎖", size: 44)
        }
        .padding(.horizontal, 36)
        .padding(.top, 26)
        .padding(.bottom, 16)
    }

    private var statusBanner: some View {
        HStack(spacing: 14) {
            Text("印")
                .font(.system(size: 13, weight: .bold, design: .serif))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(SumiInk.seal)
            Text(snapshot.bannerCaption)
                .font(SumiInk.caption(13))
                .tracking(1.6)
                .foregroundStyle(SumiInk.seal)
            Spacer()
            if snapshot.calibration.isSoftModeActive {
                Text("REMAINING \(snapshot.calibration.remainingCaption)")
                    .font(SumiInk.caption(10))
                    .tracking(1.4)
                    .monospacedDigit()
                    .foregroundStyle(SumiInk.inkMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(SumiInk.sealWash)
        .overlay(Rectangle().stroke(SumiInk.seal.opacity(0.55), lineWidth: 1))
        .padding(.horizontal, 36)
        .padding(.bottom, 14)
    }

    private var tabRail: some View {
        HStack(spacing: 0) {
            ForEach(CommandDashboardTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.caption)
                        .font(SumiInk.caption(11))
                        .tracking(1.8)
                        .foregroundStyle(tab == item ? Color.white : SumiInk.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(tab == item ? SumiInk.ink : SumiInk.paperSoft)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
        .padding(.horizontal, 36)
        .padding(.bottom, 18)
    }

    private var overviewPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                metricBlock(label: "WALLET", value: snapshot.ticker.formattedBalance, unit: "credits")
                metricBlock(label: "FOCUS TODAY", value: "\(snapshot.todayFocusMinutes)", unit: "minutes")
                metricBlock(label: "EMERGENCY DEBT", value: snapshot.formattedEmergencyDebt, unit: "")
                metricBlock(label: "CURFEW", value: snapshot.ticker.isCurfew ? "LOCKED" : "OPEN", unit: snapshot.curfewCaption)
            }

            HStack(alignment: .top, spacing: 18) {
                vaultCard
                streakCard
                strikeCard
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack {
                Text(snapshot.ticker.dayStateCaption.uppercased())
                    .font(SumiInk.caption(10))
                    .tracking(1.6)
                    .foregroundStyle(SumiInk.seal)
                Spacer()
                Text(snapshot.ticker.focusStatusCaption)
                    .font(SumiInk.body(13))
                    .foregroundStyle(SumiInk.inkMuted)
            }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
    }

    private var vaultCard: some View {
        auditCard(title: "Lifetime Surplus Vault", seal: "蔵") {
            Text(snapshot.formattedVault)
                .font(SumiInk.display(42))
                .monospacedDigit()
                .foregroundStyle(SumiInk.ink)
            Text("credits banked from 21:00 midnight rollovers")
                .font(SumiInk.body(12))
                .foregroundStyle(SumiInk.inkMuted)
        }
    }

    private var streakCard: some View {
        auditCard(title: "Victory Streak Records", seal: "勝") {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("\(snapshot.vault.currentStreak)")
                    .font(SumiInk.display(42))
                    .monospacedDigit()
                Text("current")
                    .font(SumiInk.caption(11))
                    .foregroundStyle(SumiInk.inkMuted)
            }
            Text("Highest unbroken target days  \(snapshot.vault.highestStreak)")
                .font(SumiInk.body(13))
                .foregroundStyle(SumiInk.ink)
        }
    }

    private var strikeCard: some View {
        auditCard(title: "Deficit Strike History", seal: "欠") {
            Text("\(snapshot.deficitStrikeCount)")
                .font(SumiInk.display(42))
                .monospacedDigit()
                .foregroundStyle(SumiInk.seal)
            VStack(alignment: .leading, spacing: 4) {
                if snapshot.deficitStrikeLog.isEmpty {
                    Text("No deficit strikes recorded.")
                        .font(SumiInk.body(12))
                        .foregroundStyle(SumiInk.inkMuted)
                } else {
                    ForEach(snapshot.deficitStrikeLog.suffix(4), id: \.date) { record in
                        Text("\(record.date)  ·  earned \(CreditMath.displayString(record.earnedCredits))")
                            .font(SumiInk.body(12))
                            .foregroundStyle(SumiInk.ink)
                    }
                }
            }
        }
    }

    private func auditCard<Content: View>(
        title: String,
        seal: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(SumiInk.caption(11))
                    .tracking(1.4)
                    .foregroundStyle(SumiInk.inkMuted)
                Spacer()
                Text(seal)
                    .font(.system(size: 13, weight: .bold, design: .serif))
                    .foregroundStyle(Color.white)
                    .frame(width: 26, height: 26)
                    .background(SumiInk.seal)
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
        .background(SumiInk.paperSoft.opacity(0.55))
    }

    private func metricBlock(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
            Text(value)
                .font(SumiInk.display(28))
                .monospacedDigit()
                .foregroundStyle(SumiInk.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !unit.isEmpty {
                Text(unit)
                    .font(SumiInk.body(11))
                    .foregroundStyle(SumiInk.inkMuted)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
    }

    private var ledgerPage: TransactionLedgerPage {
        TransactionLedgerQuery.page(
            from: snapshot.transactions,
            filter: filter,
            search: search,
            page: page,
            pageSize: pageSize
        )
    }

    private var ledgerPane: some View {
        let pageModel = ledgerPage
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(LedgerAuditKind.allCases, id: \.self) { kind in
                    Button {
                        filter = kind
                        page = 1
                    } label: {
                        Text(kind.caption)
                            .font(SumiInk.caption(9))
                            .tracking(1.2)
                            .foregroundStyle(filter == kind ? Color.white : SumiInk.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(filter == kind ? SumiInk.ink : SumiInk.paperSoft)
                            .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                TextField("Search ledger", text: $search)
                    .textFieldStyle(.plain)
                    .font(SumiInk.body(13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 220)
                    .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
                    .onChange(of: search) { _, _ in
                        page = 1
                    }
            }

            ledgerHeader
            if pageModel.items.isEmpty {
                Text("No transactions match this filter.")
                    .font(SumiInk.body(13))
                    .foregroundStyle(SumiInk.inkMuted)
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 0) {
                    ForEach(pageModel.items) { row in
                        ledgerRow(row)
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 14) {
                Text("PAGE \(pageModel.page) OF \(pageModel.totalPages)  ·  \(pageModel.totalItems) ROWS")
                    .font(SumiInk.caption(10))
                    .tracking(1.2)
                    .foregroundStyle(SumiInk.inkMuted)
                Spacer()
                Text("PER PAGE")
                    .font(SumiInk.caption(9))
                    .foregroundStyle(SumiInk.inkMuted)
                ForEach(TransactionLedgerQuery.pageSizeOptions, id: \.self) { size in
                    Button {
                        pageSize = size
                        page = 1
                    } label: {
                        Text("\(size)")
                            .font(SumiInk.caption(10))
                            .foregroundStyle(pageSize == size ? Color.white : SumiInk.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(pageSize == size ? SumiInk.ink : SumiInk.paperSoft)
                    }
                    .buttonStyle(.plain)
                }
                Button("PREV") {
                    page = max(1, pageModel.page - 1)
                }
                .buttonStyle(SumiInkGhostButton())
                .disabled(!pageModel.hasPrevious)
                Button("NEXT") {
                    page = min(pageModel.totalPages, pageModel.page + 1)
                }
                .buttonStyle(SumiInkGhostButton())
                .disabled(!pageModel.hasNext)
                TextField("pg", text: $jumpPage)
                    .textFieldStyle(.plain)
                    .font(SumiInk.body(12))
                    .monospacedDigit()
                    .frame(width: 36)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
                Button("JUMP") {
                    if let value = Int(jumpPage) {
                        page = value
                    }
                }
                .buttonStyle(SumiInkGhostButton())
            }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 24)
    }

    private var ledgerHeader: some View {
        HStack {
            Text("TIME").frame(width: 168, alignment: .leading)
            Text("TYPE").frame(width: 140, alignment: .leading)
            Text("AMOUNT").frame(width: 90, alignment: .trailing)
            Text("BALANCE").frame(width: 90, alignment: .trailing)
            Text("DESCRIPTION").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(SumiInk.caption(9))
        .tracking(1.6)
        .foregroundStyle(SumiInk.inkMuted)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(SumiInk.rule).frame(height: 1) }
    }

    private func ledgerRow(_ transaction: WalletTransaction) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(transaction.timestamp.ISO8601Format())
                .frame(width: 168, alignment: .leading)
                .monospacedDigit()
            Text(transaction.transactionType.rawValue.uppercased())
                .frame(width: 140, alignment: .leading)
            Text(signedAmount(transaction.amount))
                .frame(width: 90, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(transaction.amount < 0 ? SumiInk.seal : SumiInk.ink)
            Text(CreditMath.displayString(transaction.balanceAfter))
                .frame(width: 90, alignment: .trailing)
                .monospacedDigit()
            Text(transaction.description)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .font(SumiInk.body(12))
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(SumiInk.rule.opacity(0.55)).frame(height: 1) }
    }

    private var settingsPane: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text("2FA Security Gate")
                    .font(SumiInk.display(22))
                Text("Twelve-character password and Google Authenticator TOTP unlock administrative settings. Successful unlocks dispatch a Resend warning.")
                    .font(SumiInk.body(13))
                    .foregroundStyle(SumiInk.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if snapshot.security.isUnlocked {
                    unlockedSettings
                } else if snapshot.security.isEnrolled {
                    lockedSettings
                } else {
                    enrollmentSettings
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 16) {
                governanceCard
                emergencyCard
                sentinelCard
            }
            .frame(width: 360)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
    }

    private var lockedSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("2FA PROTECTION ACTIVE")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.seal)
                Spacer()
            }
            SecureField("Password (12+ characters)", text: $password)
                .textFieldStyle(.plain)
                .font(SumiInk.body(14))
                .padding(10)
                .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
            SecureField("Authenticator code", text: $totp)
                .textFieldStyle(.plain)
                .font(SumiInk.body(14))
                .padding(10)
                .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
            if let error = snapshot.security.unlockError {
                Text(error)
                    .font(SumiInk.body(12))
                    .foregroundStyle(SumiInk.seal)
            }
            Button("UNLOCK SETTINGS") {
                let submittedPassword = password
                let submittedTOTP = totp
                clearSecrets()
                onUnlock?(submittedPassword, submittedTOTP)
            }
            .buttonStyle(SumiInkSealButton())
            .disabled(password.count < SecurityGatekeeper.minimumPasswordLength || totp.count < 6)
        }
        .padding(18)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
    }

    private var enrollmentSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ENROLL ADMIN 2FA")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.seal)
            Text("Set a 12+ character password and confirm a generated authenticator secret with a test code. Configuration writes stay open until enrollment completes.")
                .font(SumiInk.body(13))
                .foregroundStyle(SumiInk.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password (12+ characters, upper/lower/number/symbol)", text: $password)
                .textFieldStyle(.plain)
                .font(SumiInk.body(14))
                .padding(10)
                .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
            let complexity = PasswordHasher.validateComplexity(password)
            if !password.isEmpty && !complexity.isValid {
                Text("Requires: " + complexity.missing.joined(separator: ", "))
                    .font(SumiInk.caption(10))
                    .foregroundStyle(SumiInk.seal)
            }
            SecureField("Confirm password", text: $confirmPassword)
                .textFieldStyle(.plain)
                .font(SumiInk.body(14))
                .padding(10)
                .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
            Text("Authenticator secret")
                .font(SumiInk.caption(9))
                .tracking(1.6)
                .foregroundStyle(SumiInk.inkMuted)
            Text(enrollSecret.isEmpty ? "Generating…" : enrollSecret)
                .font(SumiInk.body(13))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
            if !enrollSecret.isEmpty {
                Text(TOTPEngine.otpAuthURL(secret: enrollSecret))
                    .font(SumiInk.caption(9))
                    .foregroundStyle(SumiInk.inkMuted)
                    .textSelection(.enabled)
            }
            SecureField("Test authenticator code", text: $totp)
                .textFieldStyle(.plain)
                .font(SumiInk.body(14))
                .padding(10)
                .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
            if let error = snapshot.security.unlockError {
                Text(error)
                    .font(SumiInk.body(12))
                    .foregroundStyle(SumiInk.seal)
            }
            Button("ENROLL 2FA") {
                let submittedPassword = password
                let submittedConfirm = confirmPassword
                let submittedSecret = enrollSecret
                let submittedTOTP = totp
                clearSecrets()
                onEnroll?(submittedPassword, submittedConfirm, submittedSecret, submittedTOTP)
            }
            .buttonStyle(SumiInkSealButton())
            .disabled(
                !PasswordHasher.validateComplexity(password).isValid
                    || confirmPassword != password
                    || totp.count < 6
                    || enrollSecret.isEmpty
            )
        }
        .padding(18)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
        .onAppear {
            if enrollSecret.isEmpty {
                enrollSecret = (try? TOTPEngine.generateSecret()) ?? ""
            }
        }
    }

    private var unlockedSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledValue("Alert mail recipient", snapshot.security.alertRecipient)
            labeledValue("Last alert", snapshot.security.lastAlertKind?.rawValue ?? "—")
            labeledValue("Gate", "UNLOCKED · 2FA PROTECTION ACTIVE")
            if snapshot.security.mailDispatchFailed {
                Text("Local audit mode (no Resend API key configured). The session is recorded locally.")
                    .font(SumiInk.body(11))
                    .foregroundStyle(SumiInk.inkMuted)
            }
            Button("LOCK SETTINGS") {
                clearSecrets()
                onLock?()
            }
            .buttonStyle(SumiInkGhostButton())
        }
        .padding(18)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
    }

    private func clearSecrets() {
        password = ""
        confirmPassword = ""
        totp = ""
    }

    private var governanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("48-HOUR GOVERNANCE")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
            Text(snapshot.governance.bannerCaption)
                .font(SumiInk.body(14))
                .foregroundStyle(SumiInk.ink)
            Text(snapshot.governance.remainingCaption)
                .font(SumiInk.display(28))
                .monospacedDigit()
                .foregroundStyle(SumiInk.seal)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
        .background(SumiInk.sealWash.opacity(0.65))
    }

    private var emergencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EMERGENCY SAFETY VALVE")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
            Text(snapshot.emergencyValveCaption)
                .font(SumiInk.body(14))
            Text("Pending debt  \(snapshot.formattedEmergencyDebt)")
                .font(SumiInk.body(13))
                .foregroundStyle(SumiInk.inkMuted)
            if snapshot.emergencyValveActive {
                Text("EMERGENCY OVERRIDE ENGAGED (30m release active)")
                    .font(SumiInk.caption(10))
                    .tracking(1.4)
                    .foregroundStyle(SumiInk.seal)
            } else {
                Button("ENGAGE EMERGENCY VALVE (30m)") {
                    showingEmergencyConfirmation = true
                }
                .buttonStyle(SumiInkGhostButton())
                .alert("Confirm Emergency Override", isPresented: $showingEmergencyConfirmation) {
                    Button("ENGAGE (−2.0c DEBT)", role: .destructive) {
                        onTriggerEmergencyValve?()
                    }
                    Button("CANCEL", role: .cancel) {}
                } message: {
                    Text(EmergencySafetyValveEngine.confirmationPromptText)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
    }

    private var sentinelStatus: SMAppService.Status {
        SMAppService.daemon(plistName: "com.mavoid.zoidlockin.helper.plist").status
    }

    private var sentinelStatusCaption: String {
        switch sentinelStatus {
        case .enabled:
            return "ENABLED · ROOT SENTINEL"
        case .requiresApproval:
            return "APPROVAL REQUIRED IN SYSTEM SETTINGS"
        case .notRegistered:
            return "NOT REGISTERED"
        case .notFound:
            return "BUNDLE HELPER NOT FOUND"
        @unknown default:
            return "UNKNOWN"
        }
    }

    private var sentinelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SENTINEL DAEMON")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Spacer()
                Text(sentinelStatusCaption)
                    .font(SumiInk.caption(9))
                    .tracking(1.2)
                    .foregroundStyle(sentinelStatus == .enabled ? SumiInk.ink : SumiInk.seal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sentinelStatus == .enabled ? SumiInk.paperSoft : SumiInk.sealWash)
            }
            Text("Hard lockdown privileged sentinel supervising unauthorized gaming executables and network socket filters.")
                .font(SumiInk.body(12))
                .foregroundStyle(SumiInk.inkMuted)
            if sentinelStatus != .enabled {
                Button("REGISTER SENTINEL DAEMON") {
                    try? SMAppService.daemon(plistName: "com.mavoid.zoidlockin.helper.plist").register()
                }
                .buttonStyle(SumiInkGhostButton())
            } else {
                Text("Daemon actively supervised by macOS launchd.")
                    .font(SumiInk.caption(10))
                    .foregroundStyle(SumiInk.inkMuted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(SumiInk.caption(9))
                .tracking(1.6)
                .foregroundStyle(SumiInk.inkMuted)
            Text(value)
                .font(SumiInk.body(14))
        }
    }

    private func signedAmount(_ amount: Double) -> String {
        let body = CreditMath.displayString(abs(amount))
        if amount > 0 { return "+\(body)" }
        if amount < 0 { return "−\(body)" }
        return body
    }
}

private struct SumiInkSealButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SumiInk.caption(11))
            .tracking(1.8)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(SumiInk.seal.opacity(configuration.isPressed ? 0.8 : 1))
    }
}

private struct SumiInkGhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SumiInk.caption(10))
            .tracking(1.4)
            .foregroundStyle(SumiInk.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
