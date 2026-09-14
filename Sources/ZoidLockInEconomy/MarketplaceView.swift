import SwiftUI
import ZoidLockInCore

/// Menu Bar extra content. Marketplace, Offline Meeting, and Micro-Habits.
public struct MenuBarExtraView: View {
    public var snapshot: MarketplaceSnapshot
    public var meeting: OfflineMeetingSnapshot
    public var habits: MicroHabitsSnapshot
    public var onPurchase: ((AmenityKind) -> Void)?
    public var onPunchToggle: (() -> Void)?
    public var onSubmitMeeting: (() -> Void)?
    public var onAbandonMeeting: (() -> Void)?
    public var onImportArtifact: ((MeetingArtifactKind, URL) -> Void)?
    public var onRetryAudit: (() -> Void)?
    public var onAppeal: ((String) -> Void)?
    public var onCompleteHabit: ((UUID) -> Void)?
    public var onCreateHabit: ((String, Double, Int) -> Void)?

    @State private var surface: MenuBarCompanionSurface

    public init(
        snapshot: MarketplaceSnapshot,
        onPurchase: ((AmenityKind) -> Void)? = nil,
        meeting: OfflineMeetingSnapshot = .idle,
        habits: MicroHabitsSnapshot = .empty,
        onPunchToggle: (() -> Void)? = nil,
        onSubmitMeeting: (() -> Void)? = nil,
        onAbandonMeeting: (() -> Void)? = nil,
        onImportArtifact: ((MeetingArtifactKind, URL) -> Void)? = nil,
        onRetryAudit: (() -> Void)? = nil,
        onAppeal: ((String) -> Void)? = nil,
        onCompleteHabit: ((UUID) -> Void)? = nil,
        onCreateHabit: ((String, Double, Int) -> Void)? = nil,
        initialSurface: MenuBarCompanionSurface = .market
    ) {
        self.snapshot = snapshot
        self.meeting = meeting
        self.habits = habits
        self.onPurchase = onPurchase
        self.onPunchToggle = onPunchToggle
        self.onSubmitMeeting = onSubmitMeeting
        self.onAbandonMeeting = onAbandonMeeting
        self.onImportArtifact = onImportArtifact
        self.onRetryAudit = onRetryAudit
        self.onAppeal = onAppeal
        self.onCompleteHabit = onCompleteHabit
        self.onCreateHabit = onCreateHabit
        _surface = State(initialValue: initialSurface)
    }

    public var body: some View {
        VStack(spacing: 0) {
            surfaceSwitcher
            Group {
                if surface == .market {
                    MarketplacePopoverView(snapshot: snapshot, onPurchase: onPurchase)
                } else if surface == .meeting {
                    OfflineMeetingPopoverView(
                        snapshot: meeting,
                        onPunchToggle: onPunchToggle,
                        onSubmit: onSubmitMeeting,
                        onAbandon: onAbandonMeeting,
                        onImportArtifact: onImportArtifact,
                        onRetryAudit: onRetryAudit,
                        onAppeal: onAppeal
                    )
                } else {
                    MicroHabitsPopoverView(
                        snapshot: habits,
                        onComplete: onCompleteHabit,
                        onCreate: onCreateHabit
                    )
                }
            }
        }
        .background(SumiInk.paper)
    }

    private var surfaceSwitcher: some View {
        HStack(spacing: 0) {
            switcherTab("市  MARKET", surface: .market)
            switcherTab("会  MEET", surface: .meeting)
            switcherTab("習  HABIT", surface: .habits)
        }
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(width: 440)
        .background(SumiInk.paper)
    }

    private func switcherTab(_ title: String, surface tab: MenuBarCompanionSurface) -> some View {
        Button {
            surface = tab
        } label: {
            Text(title)
                .font(SumiInk.caption(10))
                .tracking(1.6)
                .foregroundStyle(surface == tab ? Color.white : SumiInk.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(surface == tab ? SumiInk.ink : SumiInk.paperSoft)
        }
        .buttonStyle(.plain)
    }
}

/// Native menu-bar marketplace popover: catalog, live pass timers, vault, curfew.
public struct MarketplacePopoverView: View {
    public var snapshot: MarketplaceSnapshot
    public var onPurchase: ((AmenityKind) -> Void)?

    public init(snapshot: MarketplaceSnapshot, onPurchase: ((AmenityKind) -> Void)? = nil) {
        self.snapshot = snapshot
        self.onPurchase = onPurchase
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            shieldBanner
            Divider().overlay(SumiInk.rule)
            balance
            if !snapshot.activeItems.isEmpty {
                Divider().overlay(SumiInk.rule)
                activePasses
            }
            Divider().overlay(SumiInk.rule)
            catalog
            Spacer(minLength: 8)
            footer
        }
        .padding(22)
        .frame(
            width: 440,
            height: 700,
            alignment: .topLeading
        )
        .background(MarketplacePaperBackground())
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ZOID LOCK IN")
                    .font(SumiInk.caption(11))
                    .tracking(3.2)
                    .foregroundStyle(SumiInk.inkMuted)
                Text(snapshot.weekdayCaption.uppercased())
                    .font(SumiInk.body(15))
                    .foregroundStyle(SumiInk.ink)
            }
            Spacer()
            VermilionSeal(text: "市", size: 38)
        }
        .padding(.bottom, 10)
    }

    private var shieldBanner: some View {
        HStack(spacing: 10) {
            Text("盾")
                .font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(SumiInk.seal)
                .overlay(Rectangle().stroke(SumiInk.seal, lineWidth: 1))
            Text(snapshot.mobileShieldCaption)
                .font(SumiInk.caption(10))
                .tracking(1.4)
                .foregroundStyle(SumiInk.seal)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SumiInk.sealWash)
        .overlay(Rectangle().stroke(SumiInk.seal.opacity(0.55), lineWidth: 1))
        .padding(.bottom, 12)
    }

    private var balance: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(snapshot.formattedBalance)
                    .font(SumiInk.display(42))
                    .monospacedDigit()
                    .foregroundStyle(SumiInk.ink)
                Text("CREDITS")
                    .font(SumiInk.caption(11))
                    .tracking(2)
                    .foregroundStyle(SumiInk.seal)
                Spacer()
                Text(snapshot.dayStateCaption)
                    .font(SumiInk.caption(10))
                    .tracking(1.4)
                    .foregroundStyle(SumiInk.seal)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(SumiInk.sealWash)
                    .overlay(Rectangle().stroke(SumiInk.seal.opacity(0.55), lineWidth: 1))
            }

            HStack(spacing: 18) {
                metric(label: "VAULT", value: snapshot.formattedVault)
                metric(label: "STREAK", value: "\(snapshot.currentStreak)  ·  best \(snapshot.highestStreak)")
            }
        }
        .padding(.vertical, 12)
    }

    private var activePasses: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVE PASSES")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
            ForEach(snapshot.activeItems) { item in
                HStack {
                    Text(item.sealGlyph)
                        .font(SumiInk.body(14))
                        .foregroundStyle(SumiInk.seal)
                        .frame(width: 22)
                    Text(item.title)
                        .font(SumiInk.body(13))
                        .foregroundStyle(SumiInk.ink)
                    Spacer()
                    Text(item.formattedRemaining ?? "0:00")
                        .font(SumiInk.body(13))
                        .monospacedDigit()
                        .foregroundStyle(SumiInk.seal)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MARKETPLACE")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
                .padding(.bottom, 4)

            ForEach(snapshot.items) { item in
                MarketplaceCatalogRow(
                    item: item,
                    isPurchaseDisabled: snapshot.purchaseInFlight || item.isBlockedByCurfew
                ) {
                    onPurchase?(item.kind)
                }
            }
        }
        .padding(.top, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let purchaseError = snapshot.purchaseError {
                Text(purchaseError)
                    .font(SumiInk.body(12))
                    .foregroundStyle(SumiInk.seal)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SumiInk.sealWash)
                    .overlay(Rectangle().stroke(SumiInk.seal.opacity(0.55), lineWidth: 1))
            }

            HStack {
                Text(snapshot.localDayKey)
                    .font(SumiInk.body(11))
                    .foregroundStyle(SumiInk.inkMuted)
                Spacer()
                Text(snapshot.curfewCaption)
                    .font(SumiInk.caption(10))
                    .tracking(0.6)
                    .foregroundStyle(snapshot.isCurfew ? SumiInk.seal : SumiInk.inkMuted)
            }
        }
        .padding(.top, 10)
    }

    private func metric(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(SumiInk.caption(10))
                .tracking(1.6)
                .foregroundStyle(SumiInk.inkMuted)
            Text(value)
                .font(SumiInk.body(13))
                .foregroundStyle(SumiInk.ink)
        }
    }
}

struct MarketplaceCatalogRow: View {
    var item: MarketplaceItemSnapshot
    var isPurchaseDisabled: Bool = false
    var onBuy: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(item.sealGlyph)
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(SumiInk.ink)
                .overlay(Rectangle().stroke(SumiInk.ink, lineWidth: 1))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(SumiInk.body(13))
                    .foregroundStyle(SumiInk.ink)
                Text(item.subtitle)
                    .font(SumiInk.body(11))
                    .foregroundStyle(SumiInk.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.formattedCost)
                        .font(SumiInk.body(13))
                        .monospacedDigit()
                        .foregroundStyle(SumiInk.ink)
                    Text("cr")
                        .font(SumiInk.caption(9))
                        .foregroundStyle(SumiInk.inkMuted)
                }
                Text(item.isActive ? (item.formattedRemaining ?? item.durationCaption) : item.durationCaption)
                    .font(SumiInk.caption(10))
                    .foregroundStyle(item.isActive ? SumiInk.seal : SumiInk.inkMuted)
            }

            Button(action: onBuy) {
                Text(item.isBlockedByCurfew ? "LOCK" : "BUY")
                    .font(SumiInk.caption(10))
                    .tracking(1.4)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(item.isBlockedByCurfew ? SumiInk.inkMuted : SumiInk.seal)
            }
            .buttonStyle(.plain)
            .disabled(isPurchaseDisabled)
            .opacity(isPurchaseDisabled ? 0.72 : 1)
        }
        .padding(.vertical, 5)
    }
}

struct MarketplacePaperBackground: View {
    var body: some View {
        ZStack {
            SumiInk.paper
            Canvas { context, size in
                let grain = SumiInk.ink.opacity(0.035)
                for row in stride(from: 0.0, to: size.height, by: 7) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: row))
                    path.addLine(to: CGPoint(x: size.width, y: row + 0.4))
                    context.stroke(path, with: .color(grain), lineWidth: 0.6)
                }
            }
        }
    }
}
