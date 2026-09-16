import SwiftUI
import ZoidLockInCore

/// Native menu-bar companion view for digital deep work focus sessions.
public struct FocusPopoverView: View {
    public var snapshot: MenuBarTickerSnapshot
    public var onToggleFocus: (() -> Void)?

    public init(
        snapshot: MenuBarTickerSnapshot,
        onToggleFocus: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onToggleFocus = onToggleFocus
    }

    private var isFocusActive: Bool {
        snapshot.focusState == .active || snapshot.focusState == .pausedGrace
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statusBanner
            Divider().overlay(SumiInk.rule)
            timerSection
            Divider().overlay(SumiInk.rule)
            metricsSection
            Divider().overlay(SumiInk.rule)
            momentumSection
            Spacer(minLength: 16)
            footer
        }
        .padding(22)
        .frame(width: 440, height: 700, alignment: .topLeading)
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
            VermilionSeal(text: "集", size: 38)
        }
        .padding(.bottom, 10)
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Text("集")
                .font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(isFocusActive ? SumiInk.seal : SumiInk.inkMuted)
                .overlay(Rectangle().stroke(isFocusActive ? SumiInk.seal : SumiInk.inkMuted, lineWidth: 1))
            Text(statusBannerText)
                .font(SumiInk.caption(10))
                .tracking(1.4)
                .foregroundStyle(isFocusActive ? SumiInk.seal : SumiInk.inkMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isFocusActive ? SumiInk.sealWash : SumiInk.paperSoft)
        .overlay(Rectangle().stroke(isFocusActive ? SumiInk.seal.opacity(0.55) : SumiInk.rule, lineWidth: 1))
        .padding(.bottom, 12)
    }

    private var statusBannerText: String {
        switch snapshot.focusState {
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

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(snapshot.formattedElapsed)
                    .font(SumiInk.display(48))
                    .monospacedDigit()
                    .foregroundStyle(isFocusActive ? SumiInk.ink : SumiInk.inkMuted)
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

            Button {
                onToggleFocus?()
            } label: {
                Text(isFocusActive ? "COMPLETE FOCUS SESSION" : "PUNCH IN FOCUS BLOCK")
                    .font(SumiInk.body(13))
                    .tracking(2.2)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(isFocusActive ? SumiInk.seal : SumiInk.ink)
                    .overlay(Rectangle().stroke(isFocusActive ? SumiInk.seal : SumiInk.ink, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.vertical, 14)
    }

    private var metricsSection: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT MINT")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Text(formattedNextMint)
                    .font(SumiInk.body(14))
                    .monospacedDigit()
                    .foregroundStyle(SumiInk.ink)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("EARNED TODAY")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Text(String(format: "%0.1f Credits", snapshot.focusCreditsEarned))
                    .font(SumiInk.body(14))
                    .foregroundStyle(SumiInk.ink)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("WALLET")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Text(snapshot.formattedBalance)
                    .font(SumiInk.body(14))
                    .monospacedDigit()
                    .foregroundStyle(SumiInk.seal)
            }
        }
        .padding(.vertical, 14)
    }

    private var formattedNextMint: String {
        guard isFocusActive else { return "—" }
        let rem = snapshot.focusRemainingToNextMintSeconds
        let mins = rem / 60
        let secs = rem % 60
        return String(format: "+0.5c in %02d:%02d", mins, secs)
    }

    private var momentumSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MORNING MOMENTUM")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.seal)
                Spacer()
                Text("2.0x MULTIPLIER")
                    .font(SumiInk.caption(10))
                    .tracking(1.4)
                    .foregroundStyle(SumiInk.seal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(SumiInk.sealWash)
            }
            Text("First continuous 90-minute focus block completed before 12:00 PM Noon awards double credits (1.5 base × 2.0 = 3.0 credits), fully clearing the daily living baseline. 5-minute grace tolerance protects against brief interruptions.")
                .font(SumiInk.body(11))
                .foregroundStyle(SumiInk.inkMuted)
                .lineSpacing(3)
        }
        .padding(14)
        .background(SumiInk.paperSoft)
        .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
        .padding(.top, 14)
    }

    private var footer: some View {
        HStack {
            Text(snapshot.localDayKey)
                .font(SumiInk.body(11))
                .foregroundStyle(SumiInk.inkMuted)
            Spacer()
            if snapshot.isFridayRest {
                Text("FRIDAY REST · 0 COST")
                    .font(SumiInk.caption(10))
                    .foregroundStyle(SumiInk.seal)
            } else if snapshot.isCurfew {
                Text("CURFEW 22:00")
                    .font(SumiInk.caption(10))
                    .foregroundStyle(SumiInk.seal)
            } else {
                Text("RATE: 1.0c / HR")
                    .font(SumiInk.body(11))
                    .foregroundStyle(SumiInk.inkMuted)
            }
        }
        .padding(.top, 8)
    }
}
