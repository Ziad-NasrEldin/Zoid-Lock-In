import ServiceManagement
import SwiftUI
import ZoidLockInCore
import ZoidLockInEnforcer
import ZoidLockInFilterExtension

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
    public var onDeleteHabit: ((UUID) -> Void)?
    public var onResetLock: (() -> Void)?
    public var onToggleFocus: (() -> Void)?
    public var onToggleCooldownBypass: (() -> Void)?
    public var onActivateContentFilter: (() -> Void)?

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
    @State private var sentinelStatus: SMAppService.Status
    @State private var sentinelError: String = ""
    private var contentFilterManager: ContentFilterManager?

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
        onCreateHabit: ((String, Double, Int) -> Void)? = nil,
        onDeleteHabit: ((UUID) -> Void)? = nil,
        onResetLock: (() -> Void)? = nil,
        onToggleFocus: (() -> Void)? = nil,
        onToggleCooldownBypass: (() -> Void)? = nil,
        contentFilterManager: ContentFilterManager? = nil,
        onActivateContentFilter: (() -> Void)? = nil
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
        self.onDeleteHabit = onDeleteHabit
        self.onResetLock = onResetLock
        self.onToggleFocus = onToggleFocus
        self.onToggleCooldownBypass = onToggleCooldownBypass
        self.contentFilterManager = contentFilterManager
        self.onActivateContentFilter = onActivateContentFilter
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
        _sentinelStatus = State(initialValue: DaemonServiceRegistrar().status)
        _sentinelError = State(initialValue: "")
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

    private var isFocusActive: Bool {
        snapshot.ticker.focusState == .active || snapshot.ticker.focusState == .pausedGrace
    }

    private var overviewPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                metricBlock(label: "WALLET", value: snapshot.ticker.formattedBalance, unit: "credits")
                metricBlock(label: "FOCUS TODAY", value: "\(snapshot.todayFocusMinutes)", unit: "minutes")
                metricBlock(label: "EMERGENCY DEBT", value: snapshot.formattedEmergencyDebt, unit: "")
                metricBlock(label: "CURFEW", value: snapshot.ticker.isCurfew ? "LOCKED" : "OPEN", unit: snapshot.curfewCaption)
            }

            focusActionCard

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

    private var focusActionCard: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("集")
                        .font(.system(size: 11, weight: .bold, design: .serif))
                        .foregroundStyle(Color.white)
                        .frame(width: 22, height: 22)
                        .background(isFocusActive ? SumiInk.seal : SumiInk.ink)
                    Text(focusStatusHeader)
                        .font(SumiInk.caption(10))
                        .tracking(1.6)
                        .foregroundStyle(isFocusActive ? SumiInk.seal : SumiInk.ink)
                    Spacer()
                    Text(snapshot.ticker.dayStateCaption.uppercased())
                        .font(SumiInk.caption(10))
                        .tracking(1.2)
                        .foregroundStyle(SumiInk.seal)
                }

                HStack(alignment: .lastTextBaseline, spacing: 14) {
                    Text(snapshot.ticker.formattedElapsed)
                        .font(SumiInk.display(32))
                        .monospacedDigit()
                        .foregroundStyle(isFocusActive ? SumiInk.ink : SumiInk.inkMuted)

                    Text(formattedNextMint)
                        .font(SumiInk.body(12))
                        .foregroundStyle(SumiInk.inkMuted)

                    Spacer()

                    Button {
                        onToggleFocus?()
                    } label: {
                        Text(isFocusActive ? "COMPLETE FOCUS SESSION" : "PUNCH IN FOCUS BLOCK")
                            .font(SumiInk.body(12))
                            .tracking(1.8)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(isFocusActive ? SumiInk.seal : SumiInk.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(isFocusActive ? SumiInk.sealWash.opacity(0.3) : SumiInk.paperSoft)
        .overlay(Rectangle().stroke(isFocusActive ? SumiInk.seal.opacity(0.4) : SumiInk.rule, lineWidth: 1))
    }

    private var focusStatusHeader: String {
        switch snapshot.ticker.focusState {
        case .active:
            return "DEEP WORK FOCUS IN PROGRESS"
        case .pausedGrace:
            return "PAUSED · 5-MINUTE GRACE TOLERANCE ACTIVE"
        case .completed:
            return "SESSION COMPLETED · CREDITS MINTED"
        case .abandoned:
            return "SESSION ABANDONED (IDLE EXCEEDED 5 MIN)"
        case nil:
            return "IDLE · READY FOR DEEP WORK"
        }
    }

    private var formattedNextMint: String {
        guard isFocusActive else { return "Rate: 1.0c/hr (2.0x Morning Bonus before 12:00 PM)" }
        let rem = snapshot.ticker.focusRemainingToNextMintSeconds
        let mins = rem / 60
        let secs = rem % 60
        return String(format: "+0.5c in %02d:%02d", mins, secs)
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

    private func registerRow<Accessory: View>(
        label: String,
        value: String,
        note: String,
        emphasized: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(label)
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
                .frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(SumiInk.display(22))
                    .monospacedDigit()
                    .foregroundStyle(SumiInk.ink)
                Text(note)
                    .font(SumiInk.body(12))
                    .foregroundStyle(SumiInk.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(SumiInk.rule.opacity(0.7)).frame(height: 1) }
    }

    private func registerRow(
        label: String,
        value: String,
        note: String,
        emphasized: Bool = false
    ) -> some View {
        registerRow(label: label, value: value, note: note, emphasized: emphasized) {
            EmptyView()
        }
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("REGISTER")
                    .font(SumiInk.caption(10))
                    .tracking(2.4)
                    .foregroundStyle(SumiInk.inkMuted)
                Text("Settings")
                    .font(SumiInk.heading(22))
                    .foregroundStyle(SumiInk.ink)
            }
            .padding(.bottom, 16)

            if snapshot.security.isUnlocked {
                sessionBar
            } else if snapshot.security.isEnrolled {
                lockedSettings
            } else {
                enrollmentSettings
            }

            Rectangle()
                .fill(SumiInk.rule)
                .frame(height: 1)
                .padding(.top, 18)

            priceRegister
            domainRegister
            habitRegister
            cooldownRegister
            emergencyRegister
            sentinelRegister
            contentFilterCard

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
    }

    private var configurationLocked: Bool {
        !snapshot.security.isUnlocked || (snapshot.governance.isLocked && !snapshot.governance.isBypassEnabled)
    }

    private var lockedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOCKED")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
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
                    .foregroundStyle(SumiInk.inkMuted)
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
        .padding(.bottom, 4)
    }

    private var enrollmentSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ENROLL")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
            SecureField("Password (12+ characters, upper/lower/number/symbol)", text: $password)
                .textFieldStyle(.plain)
                .font(SumiInk.body(14))
                .padding(10)
                .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
            let complexity = PasswordHasher.validateComplexity(password)
            if !password.isEmpty && !complexity.isValid {
                Text("Requires: " + complexity.missing.joined(separator: ", "))
                    .font(SumiInk.caption(10))
                    .foregroundStyle(SumiInk.inkMuted)
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
                    .foregroundStyle(SumiInk.inkMuted)
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
        .padding(.bottom, 4)
        .onAppear {
            if enrollSecret.isEmpty {
                enrollSecret = (try? TOTPEngine.generateSecret()) ?? ""
            }
        }
    }

    private var sessionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("OPEN")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Spacer()
                Button("LOCK SETTINGS") {
                    clearSecrets()
                    onLock?()
                }
                .buttonStyle(SumiInkGhostButton())
            }

            HStack(alignment: .center, spacing: 12) {
                Text("MAIL")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                    .frame(width: 88, alignment: .leading)

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
                Text("Local audit mode")
                    .font(SumiInk.body(11))
                    .foregroundStyle(SumiInk.inkMuted)
            }
        }
        .padding(.bottom, 4)
    }

    private var priceRegister: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AmenityKind.allCases, id: \.self) { kind in
                amenityPriceRow(kind: kind)
            }
        }
    }

    private func amenityPriceRow(kind: AmenityKind) -> some View {
        let current = snapshot.currentCost(for: kind)
        let standard = AmenityCatalog.standard.intrinsicCost(of: kind)
        let note = snapshot.isPriceOverridden(for: kind)
            ? "std \(CreditMath.displayString(standard))c"
            : "standard"
        return registerRow(
            label: kind == AmenityKind.allCases.first ? "PRICES" : "",
            value: "\(kind.displayName)  ·  \(CreditMath.displayString(current))c",
            note: note
        ) {
            if snapshot.security.isUnlocked && !configurationLocked {
                HStack(spacing: 4) {
                    Button("−0.5") {
                        onUpdateAmenityPrice?(kind, max(0.5, current - 0.5))
                    }
                    .buttonStyle(SumiInkGhostButton())
                    Button("+0.5") {
                        onUpdateAmenityPrice?(kind, min(50.0, current + 0.5))
                    }
                    .buttonStyle(SumiInkGhostButton())
                }
            } else {
                EmptyView()
            }
        }
    }

    private var domainRegister: some View {
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.security.isUnlocked && !configurationLocked {
                registerRow(
                    label: "DOMAINS",
                    value: snapshot.blocklistRules.isEmpty ? "default catalog" : "\(snapshot.blocklistRules.count) custom",
                    note: "suffix"
                ) {
                    HStack(spacing: 8) {
                        TextField("reddit.com", text: $newDomain)
                            .textFieldStyle(.plain)
                            .font(SumiInk.body(13))
                            .padding(6)
                            .frame(width: 180)
                            .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
                        Button("ADD") {
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
            } else {
                registerRow(
                    label: "DOMAINS",
                    value: snapshot.blocklistRules.isEmpty ? "default catalog" : snapshot.blocklistRules.map(\.suffix).joined(separator: "  ·  "),
                    note: snapshot.blocklistRules.isEmpty ? "no custom suffixes" : "\(snapshot.blocklistRules.count) recorded"
                )
            }

            if snapshot.security.isUnlocked && !configurationLocked {
                ForEach(snapshot.blocklistRules) { rule in
                    registerRow(label: "", value: rule.suffix, note: "custom") {
                        Button("REMOVE") {
                            onRemoveBlocklistRule?(rule.suffix)
                        }
                        .buttonStyle(SumiInkGhostButton())
                    }
                }
            }
        }
    }

    private var habitRegister: some View {
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.security.isUnlocked && !configurationLocked {
                registerRow(
                    label: "HABITS",
                    value: snapshot.habits.isEmpty ? "starter catalog" : "\(snapshot.habits.count) listed",
                    note: "daily discipline"
                ) {
                    HStack(spacing: 8) {
                        TextField("Habit title", text: $newHabitTitle)
                            .textFieldStyle(.plain)
                            .font(SumiInk.body(13))
                            .padding(6)
                            .frame(width: 180)
                            .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
                        Picker("Reward", selection: $newHabitReward) {
                            Text("+0.25c").tag(0.25)
                            Text("+0.50c").tag(0.50)
                            Text("+0.75c").tag(0.75)
                            Text("+1.00c").tag(1.00)
                        }
                        .frame(width: 90)
                        Picker("Daily", selection: $newHabitFreq) {
                            Text("1x").tag(1)
                            Text("2x").tag(2)
                            Text("3x").tag(3)
                            Text("4x").tag(4)
                            Text("5x").tag(5)
                        }
                        .frame(width: 70)
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
                ForEach(snapshot.habits) { habit in
                    registerRow(
                        label: "",
                        value: habit.title,
                        note: "\(habit.formattedReward)  ·  \(habit.dailyFrequencyLimit)x/day"
                    ) {
                        Button("DELETE") {
                            onDeleteHabit?(habit.id)
                        }
                        .buttonStyle(SumiInkGhostButton())
                    }
                }
            } else {
                registerRow(
                    label: "HABITS",
                    value: snapshot.habits.isEmpty ? "starter catalog" : snapshot.habits.map(\.title).joined(separator: "  ·  "),
                    note: snapshot.habits.isEmpty
                        ? "default daily tasks"
                        : snapshot.habits.map { "\($0.formattedReward) · \($0.dailyFrequencyLimit)x" }.joined(separator: "   ")
                )
            }
        }
    }

    private func clearSecrets() {
        password = ""
        confirmPassword = ""
        totp = ""
    }

    private var cooldownRegister: some View {
        registerRow(
            label: "COOLDOWN",
            value: snapshot.governance.remainingCaption,
            note: snapshot.governance.bannerCaption
        ) {
            if snapshot.security.isUnlocked {
                HStack(spacing: 8) {
                    if snapshot.governance.isLocked {
                        Button("RESET") {
                            onResetLock?()
                        }
                        .buttonStyle(SumiInkSealButton())
                    }
                    if snapshot.governance.isBypassEnabled {
                        Button("STRICT") {
                            onToggleCooldownBypass?()
                        }
                        .buttonStyle(SumiInkGhostButton())
                    } else {
                        Button("BYPASS") {
                            onToggleCooldownBypass?()
                        }
                        .buttonStyle(SumiInkGhostButton())
                    }
                }
            } else {
                EmptyView()
            }
        }
    }

    private var emergencyRegister: some View {
        registerRow(
            label: "EMERGENCY",
            value: snapshot.formattedEmergencyDebt,
            note: snapshot.emergencyValveActive
                ? "30m release active"
                : snapshot.emergencyValveCaption
        ) {
            if snapshot.emergencyValveActive {
                EmptyView()
            } else {
                Button("ENGAGE (30m)") {
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
    }

    private var sentinelStatusCaption: String {
        DaemonServiceRegistrar.statusCaption(sentinelStatus)
    }

    private var sentinelRegister: some View {
        registerRow(
            label: "SENTINEL",
            value: sentinelStatusCaption,
            note: sentinelError.isEmpty ? "process and socket filter" : sentinelError
        ) {
            if sentinelStatus != .enabled {
                Button("REGISTER") {
                    registerSentinelDaemon()
                }
                .buttonStyle(SumiInkGhostButton())
            } else {
                EmptyView()
            }
        }
    }

    private func registerSentinelDaemon() {
        let registrar = DaemonServiceRegistrar()
        do {
            sentinelError = ""
            sentinelStatus = try registrar.register()
        } catch {
            sentinelStatus = registrar.status
            sentinelError = error.localizedDescription
        }
    }

    private var contentFilterCard: some View {
        ContentFilterSettingsCard(
            manager: contentFilterManager,
            onActivate: onActivateContentFilter
        )
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
 
 /// Dedicated settings card that observes `ContentFilterManager` so SwiftUI reactively
 /// updates when the filter status changes asynchronously.
 public struct ContentFilterSettingsCard: View {
     @ObservedObject private var manager: ContentFilterManager
     public var onActivate: (() -> Void)?
 
    public init(manager: ContentFilterManager? = nil, onActivate: (() -> Void)? = nil) {
        self._manager = ObservedObject(wrappedValue: manager ?? ContentFilterManager.mockForTesting)
        self.onActivate = onActivate
    }
 
     private var status: ContentFilterStatus {
         manager.status
     }
 
     private var errorMessage: String {
         manager.errorMessage
     }
 
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("FILTER")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
                .frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.caption)
                    .font(SumiInk.display(22))
                    .foregroundStyle(status == .failed ? SumiInk.seal : SumiInk.ink)
                Text(note)
                    .font(SumiInk.body(12))
                    .foregroundStyle(errorMessage.isEmpty ? SumiInk.inkMuted : SumiInk.seal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if status != .enabled {
                Button(status == .pendingApproval ? "PROMPT" : "ACTIVATE") {
                    manager.requestActivation()
                    onActivate?()
                }
                .buttonStyle(SumiInkGhostButton())
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(SumiInk.rule.opacity(0.7)).frame(height: 1) }
        .onAppear {
            manager.refreshStatus()
        }
    }

    private var note: String {
        if !errorMessage.isEmpty {
            return errorMessage
        }
        switch status {
        case .enabled:
            return "socket filter active"
        case .pendingApproval:
            return "approve in System Settings"
        case .failed:
            return "activation failed"
        case .disabled:
            return "socket filter not configured"
        }
    }
}
