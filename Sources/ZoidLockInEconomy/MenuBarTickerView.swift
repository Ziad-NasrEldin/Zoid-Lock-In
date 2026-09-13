import SwiftUI
import ZoidLockInCore

/// Compact SUMI-E ticker shown in the `MenuBarExtra` window.
public struct MenuBarTickerView: View {
    public var snapshot: MenuBarTickerSnapshot

    public init(snapshot: MenuBarTickerSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            balanceRow
            Divider()
                .overlay(SumiInk.rule)
            metrics
            footer
        }
        .padding(22)
        .frame(width: 380, height: 280, alignment: .topLeading)
        .background(SumiInk.paper)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ZOID LOCK IN")
                    .font(SumiInk.caption(11))
                    .tracking(3.2)
                    .foregroundStyle(SumiInk.inkMuted)
                Text(snapshot.weekdayCaption.uppercased())
                    .font(SumiInk.body(13))
                    .foregroundStyle(SumiInk.ink)
            }
            Spacer()
            VermilionSeal(text: "鎖")
        }
    }

    private var balanceRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text(snapshot.formattedBalance)
                .font(SumiInk.display(44))
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
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricRow(label: "FOCUS", value: snapshot.focusStatusCaption)
            metricRow(label: "STREAK", value: "\(snapshot.currentStreak)  ·  best \(snapshot.highestStreak)")
            metricRow(label: "VAULT", value: String(format: "%0.1f surplus", snapshot.lifetimeSurplus))
        }
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
                Text("NEXT +0.5  \(formattedMintCountdown)")
                    .font(SumiInk.body(11))
                    .foregroundStyle(SumiInk.inkMuted)
            }
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(SumiInk.body(14))
                .foregroundStyle(SumiInk.ink)
            Spacer()
        }
    }

    private var formattedMintCountdown: String {
        let minutes = snapshot.focusRemainingToNextMintSeconds / 60
        let seconds = snapshot.focusRemainingToNextMintSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Menu bar label: live credit ticker with a vermilion mark.
public struct MenuBarTickerLabel: View {
    public var snapshot: MenuBarTickerSnapshot

    public init(snapshot: MenuBarTickerSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(snapshot.formattedBalance)
                .font(.system(size: 13, weight: .medium, design: .serif))
                .monospacedDigit()
            Circle()
                .fill(SumiInk.seal)
                .frame(width: 6, height: 6)
        }
    }
}

public struct VermilionSeal: View {
    public var text: String
    public var size: CGFloat

    public init(text: String, size: CGFloat = 36) {
        self.text = text
        self.size = size
    }

    public var body: some View {
        Text(text)
            .font(.system(size: size * 0.44, weight: .bold, design: .serif))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(SumiInk.seal)
            .overlay(Rectangle().stroke(SumiInk.seal, lineWidth: 1))
            .rotationEffect(.degrees(-8))
    }
}
