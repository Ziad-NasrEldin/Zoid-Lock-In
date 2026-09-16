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
    public var onUpdateAmenityPrice: ((AmenityKind, Double) -> Void)?
    public var onAddBlocklistRule: ((String) -> Void)?
    public var onRemoveBlocklistRule: ((String) -> Void)?
    public var onUpdateAlertRecipient: ((String) -> Void)?
    public var onCreateHabit: ((String, Double, Int) -> Void)?

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
    @State private var newDomain: String = ""
    @State private var newHabitTitle: String = ""
    @State private var newHabitReward: Double = 0.25
    @State private var newHabitFreq: Int = 1
    @State private var editingEmail: Bool = false
    @State private var newEmailText: String = ""

    public init(
        snapshot: CommandDashboardSnapshot,
        onUnlock: ((String, String) -> Void)? = nil,
        onLock: (() -> Void)? = nil,
        onEnroll: ((String, String, String, String) -> Void)? = nil,
        onTriggerEmergencyValve: (() -> Void)? = nil,
        onUpdateAmenityPrice: ((AmenityKind, Double) -> Void)? = nil,
        onAddBlocklistRule: ((String) -> Void)? = nil,
        onRemoveBlocklistRule: ((String) -> Void)? = nil,
        onUpdateAlertRecipient: ((String) -> Void)? = nil,
        onCreateHabit: ((String, Double, Int) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onUnlock = onUnlock
        self.onLock = onLock
        self.onEnroll = onEnroll
        self.onTriggerEmergencyValve = onTriggerEmergencyValve
        self.onUpdateAmenityPrice = onUpdateAmenityPrice
        self.onAddBlocklistRule = onAddBlocklistRule
        self.onRemoveBlocklistRule = onRemoveBlocklistRule
        self.onUpdateAlertRecipient = onUpdateAlertRecipient
        self.onCreateHabit = onCreateHabit
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
        _newDomain = State(initialValue: "")
        _newHabitTitle = State(initialValue: "")
        _newHabitReward = State(initialValue: 0.25)
        _newHabitFreq = State(initialValue: 1)
        _editingEmail = State(initialValue: false)
        _newEmailText = State(initialValue: snapshot.security.alertRecipient)
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
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ADMINISTRATIVE GOVERNANCE & SETTINGS")
                            .font(SumiInk.caption(10))
                            .tracking(2.0)
                            .foregroundStyle(SumiInk.inkMuted)
                        Text("48-Hour Rate Limiting · 2FA Protection")
                            .font(SumiInk.heading(22))
                            .foregroundStyle(SumiInk.ink)
                        Text("Any change to amenity pricing, habit rewards, or blocked domain rules engages the 48-hour monotonic cooldown. Admin access is authenticated via local 2FA credentials.")
                            .font(SumiInk.body(12))
                            .foregroundStyle(SumiInk.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if snapshot.security.isUnlocked {
                        unlockedSettings
                    } else if snapshot.security.isEnrolled {
                        lockedSettings
                        readOnlySettingsPreview
                    } else {
                        enrollmentSettings
                        readOnlySettingsPreview
                    }
                }
                .padding(.bottom, 24)
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
        VStack(alignment: .leading, spacing: 20) {
            sessionBar
            amenityPriceEditor
            blocklistRuleEditor
            habitSettingsSection
        }
    }

    private var sessionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GATE UNLOCKED · 10-MINUTE ADMIN SESSION ACTIVE")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.seal)
                Spacer()
                Button("LOCK SETTINGS") {
                    clearSecrets()
                    onLock?()
                }
                .buttonStyle(SumiInkGhostButton())
            }

            HStack(alignment: .center, spacing: 12) {
                Text("Alert Mail Recipient:")
                    .font(SumiInk.caption(10))
                    .tracking(1.2)
                    .foregroundStyle(SumiInk.inkMuted)

                if editingEmail {
                    TextField("new-email@domain.com", text: $newEmailText)
                        .textFieldStyle(.plain)
                        .font(SumiInk.body(13))
                        .padding(6)
                        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
                        .frame(maxWidth: 240)

                    Button("SAVE") {
                        let trimmed = newEmailText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onUpdateAlertRecipient?(trimmed)
                            editingEmail = false
                        }
                    }
                    .buttonStyle(SumiInkSealButton())

                    Button("CANCEL") {
                        editingEmail = false
                    }
                    .buttonStyle(SumiInkGhostButton())
                } else {
                    Text(snapshot.security.alertRecipient)
                        .font(SumiInk.body(13))
                        .foregroundStyle(SumiInk.ink)

                    Button("EDIT") {
                        newEmailText = snapshot.security.alertRecipient
                        editingEmail = true
                    }
                    .buttonStyle(SumiInkGhostButton())
                }
            }

            if snapshot.security.mailDispatchFailed {
                Text("Local audit mode (no Resend API key configured). Administrative alerts are recorded locally.")
                    .font(SumiInk.body(11))
                    .foregroundStyle(SumiInk.inkMuted)
            }
        }
        .padding(16)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
        .background(SumiInk.sealWash.opacity(0.4))
    }

    private var amenityPriceEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AMENITY PRICING SCHEDULE")
                        .font(SumiInk.caption(10))
                        .tracking(1.8)
                        .foregroundStyle(SumiInk.inkMuted)
                    Text("Configure Living Comfort & Pass Credit Costs")
                        .font(SumiInk.heading(18))
                        .foregroundStyle(SumiInk.ink)
                }
                Spacer()
                if snapshot.governance.isLocked && !snapshot.governance.isBypassEnabled {
                    Text("48H COOLDOWN ACTIVE · READ-ONLY")
                        .font(SumiInk.caption(9))
                        .tracking(1.4)
                        .foregroundStyle(SumiInk.seal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(SumiInk.sealWash)
                        .overlay(Rectangle().stroke(SumiInk.seal, lineWidth: 1))
                }
            }

            Text("Any price modification records an immutable HMAC seal and engages the 48-hour cooldown period. Changes apply immediately to the Marketplace and local socket filters.")
                .font(SumiInk.body(12))
                .foregroundStyle(SumiInk.inkMuted)

            VStack(spacing: 8) {
                ForEach(AmenityKind.allCases, id: \.self) { kind in
                    amenityPriceRow(kind: kind)
                }
            }
        }
        .padding(16)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
    }

    private func amenityPriceRow(kind: AmenityKind) -> some View {
        let current = snapshot.currentCost(for: kind)
        let standard = AmenityCatalog.standard.intrinsicCost(of: kind)
        let isOverridden = snapshot.isPriceOverridden(for: kind)
        let isLocked = snapshot.governance.isLocked && !snapshot.governance.isBypassEnabled

        return HStack(spacing: 12) {
            Text(kind.sealGlyph)
                .font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundStyle(Color.white)
                .frame(width: 24, height: 24)
                .background(isOverridden ? SumiInk.seal : SumiInk.ink)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.displayName)
                        .font(SumiInk.body(13))
                        .foregroundStyle(SumiInk.ink)
                    if isOverridden {
                        Text("OVERRIDE")
                            .font(SumiInk.caption(8))
                            .tracking(1.0)
                            .foregroundStyle(SumiInk.seal)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SumiInk.sealWash)
                    }
                }
                Text(kind.subtitle)
                    .font(SumiInk.body(11))
                    .foregroundStyle(SumiInk.inkMuted)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(CreditMath.displayString(current))c")
                    .font(SumiInk.display(16))
                    .monospacedDigit()
                    .foregroundStyle(isOverridden ? SumiInk.seal : SumiInk.ink)
                Text("std: \(CreditMath.displayString(standard))c")
                    .font(SumiInk.caption(9))
                    .foregroundStyle(SumiInk.inkMuted)
            }

            if !isLocked {
                HStack(spacing: 4) {
                    Button("−0.5") {
                        let newPrice = max(0.5, current - 0.5)
                        onUpdateAmenityPrice?(kind, newPrice)
                    }
                    .buttonStyle(SumiInkGhostButton())

                    Button("+0.5") {
                        let newPrice = min(50.0, current + 0.5)
                        onUpdateAmenityPrice?(kind, newPrice)
                    }
                    .buttonStyle(SumiInkGhostButton())
                }
            }
        }
        .padding(10)
        .background(SumiInk.paperSoft)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
    }

    private var blocklistRuleEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DOMAIN BLOCKLIST RULES")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Text("Custom Distraction Domains")
                    .font(SumiInk.heading(18))
                    .foregroundStyle(SumiInk.ink)
            }

            Text("Domains blocked by default via Packet Filter and Network Extension. Adding or deleting a domain engages the 48-hour rate-limit.")
                .font(SumiInk.body(12))
                .foregroundStyle(SumiInk.inkMuted)

            let isLocked = snapshot.governance.isLocked && !snapshot.governance.isBypassEnabled

            if !isLocked {
                HStack(spacing: 8) {
                    TextField("Enter domain suffix (e.g. reddit.com)", text: $newDomain)
                        .textFieldStyle(.plain)
                        .font(SumiInk.body(13))
                        .padding(8)
                        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))

                    Button("ADD DOMAIN") {
                        let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onAddBlocklistRule?(trimmed)
                            newDomain = ""
                        }
                    }
                    .buttonStyle(SumiInkSealButton())
                    .disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if snapshot.blocklistRules.isEmpty {
                Text("No custom domain rules configured. Default system catalog rules are active.")
                    .font(SumiInk.body(12))
                    .foregroundStyle(SumiInk.inkMuted)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(snapshot.blocklistRules) { rule in
                        HStack {
                            Text("●")
                                .font(.system(size: 8))
                                .foregroundStyle(SumiInk.seal)
                            Text(rule.suffix)
                                .font(SumiInk.body(13))
                                .foregroundStyle(SumiInk.ink)
                            Spacer()
                            if !isLocked {
                                Button("REMOVE") {
                                    onRemoveBlocklistRule?(rule.suffix)
                                }
                                .buttonStyle(SumiInkGhostButton())
                            }
                        }
                        .padding(8)
                        .background(SumiInk.paperSoft)
                        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
                    }
                }
            }
        }
        .padding(16)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
    }

    private var habitSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DAILY DISCIPLINE MICRO-HABITS")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Text("Micro-Habits Catalog & Budget")
                    .font(SumiInk.heading(18))
                    .foregroundStyle(SumiInk.ink)
            }

            Text("Non-work daily tasks award up to +1.50 credits/day total. Adding tasks enforces strict daily caps.")
                .font(SumiInk.body(12))
                .foregroundStyle(SumiInk.inkMuted)

            let isLocked = snapshot.governance.isLocked && !snapshot.governance.isBypassEnabled

            if !isLocked {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Habit title (e.g. 10m Meditation)", text: $newHabitTitle)
                            .textFieldStyle(.plain)
                            .font(SumiInk.body(13))
                            .padding(8)
                            .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))

                        Picker("Reward", selection: $newHabitReward) {
                            Text("+0.25c").tag(0.25)
                            Text("+0.50c").tag(0.50)
                            Text("+0.75c").tag(0.75)
                            Text("+1.00c").tag(1.00)
                        }
                        .frame(width: 90)

                        Picker("Daily", selection: $newHabitFreq) {
                            Text("1x/day").tag(1)
                            Text("2x/day").tag(2)
                        }
                        .frame(width: 80)

                        Button("CREATE") {
                            let title = newHabitTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !title.isEmpty {
                                onCreateHabit?(title, newHabitReward, newHabitFreq)
                                newHabitTitle = ""
                            }
                        }
                        .buttonStyle(SumiInkSealButton())
                        .disabled(newHabitTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(10)
                .background(SumiInk.paperSoft)
                .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
            }

            if snapshot.habits.isEmpty {
                Text("Default starter habits catalog active (Brushing Teeth, Making Bed, Hydration, Movement).")
                    .font(SumiInk.body(12))
                    .foregroundStyle(SumiInk.inkMuted)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(snapshot.habits) { habit in
                        HStack {
                            Text(habit.title)
                                .font(SumiInk.body(13))
                                .foregroundStyle(SumiInk.ink)
                            Spacer()
                            Text(habit.formattedReward)
                                .font(SumiInk.caption(11))
                                .monospacedDigit()
                                .foregroundStyle(SumiInk.seal)
                            Text("· Max \(habit.dailyFrequencyLimit)x/day")
                                .font(SumiInk.caption(10))
                                .foregroundStyle(SumiInk.inkMuted)
                        }
                        .padding(8)
                        .background(SumiInk.paperSoft)
                        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
                    }
                }
            }
        }
        .padding(16)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
    }

    private var readOnlySettingsPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("CURRENT CONFIGURATION (READ-ONLY)")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Spacer()
                Text("LOCKED · 2FA REQUIRED TO EDIT")
                    .font(SumiInk.caption(9))
                    .tracking(1.2)
                    .foregroundStyle(SumiInk.seal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SumiInk.sealWash)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("AMENITY PRICES")
                    .font(SumiInk.caption(9))
                    .tracking(1.4)
                    .foregroundStyle(SumiInk.inkMuted)

                ForEach(AmenityKind.allCases, id: \.self) { kind in
                    let current = snapshot.currentCost(for: kind)
                    let isOverridden = snapshot.isPriceOverridden(for: kind)
                    HStack {
                        Text(kind.sealGlyph)
                            .font(.system(size: 11, weight: .bold, design: .serif))
                            .foregroundStyle(Color.white)
                            .frame(width: 20, height: 20)
                            .background(isOverridden ? SumiInk.seal : SumiInk.ink)
                        Text(kind.displayName)
                            .font(SumiInk.body(12))
                        Spacer()
                        Text("\(CreditMath.displayString(current)) credits")
                            .font(SumiInk.body(12))
                            .monospacedDigit()
                            .foregroundStyle(isOverridden ? SumiInk.seal : SumiInk.ink)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SumiInk.paperSoft)
                }
            }

            if !snapshot.blocklistRules.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CUSTOM BLOCKED DOMAINS")
                        .font(SumiInk.caption(9))
                        .tracking(1.4)
                        .foregroundStyle(SumiInk.inkMuted)

                    ForEach(snapshot.blocklistRules) { rule in
                        HStack {
                            Text("●")
                                .font(.system(size: 7))
                                .foregroundStyle(SumiInk.seal)
                            Text(rule.suffix)
                                .font(SumiInk.body(12))
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SumiInk.paperSoft)
                    }
                }
            }
        }
        .padding(16)
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
