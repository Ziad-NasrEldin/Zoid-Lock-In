import SwiftUI
import ZoidLockInCore

/// Native menu-bar micro-habits popover: checklist, 48-hour lock, editor.
public struct MicroHabitsPopoverView: View {
    public var snapshot: MicroHabitsSnapshot
    public var onComplete: ((UUID) -> Void)?
    public var onCreate: ((String, Double, Int) -> Void)?

    @State private var draftTitle = ""
    @State private var draftReward = HabitCreditMinting.defaultReward
    @State private var draftFrequency = HabitCreditMinting.minDailyFrequency

    public init(
        snapshot: MicroHabitsSnapshot,
        onComplete: ((UUID) -> Void)? = nil,
        onCreate: ((String, Double, Int) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onComplete = onComplete
        self.onCreate = onCreate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            lockBanner
            Divider().overlay(SumiInk.rule)
            balance
            Divider().overlay(SumiInk.rule)
            habitList
            Spacer(minLength: 8)
            editor
            footer
        }
        .padding(22)
        .frame(width: 440, height: 780, alignment: .topLeading)
        .background(MarketplacePaperBackground())
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ZOID LOCK IN")
                    .font(SumiInk.caption(11))
                    .tracking(3.2)
                    .foregroundStyle(SumiInk.inkMuted)
                Text("MICRO-HABITS")
                    .font(SumiInk.body(15))
                    .foregroundStyle(SumiInk.ink)
            }
            Spacer()
            VermilionSeal(text: "習", size: 38)
        }
        .padding(.bottom, 10)
    }

    private var lockBanner: some View {
        HStack(spacing: 10) {
            Text(snapshot.governance.isLocked ? "鎖" : "開")
                .font(.system(size: 12, weight: .bold, design: .serif))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(snapshot.governance.isLocked ? SumiInk.seal : SumiInk.ink)
                .overlay(
                    Rectangle().stroke(
                        snapshot.governance.isLocked ? SumiInk.seal : SumiInk.ink,
                        lineWidth: 1
                    )
                )
            Text(snapshot.governance.bannerCaption)
                .font(SumiInk.caption(10))
                .tracking(1.2)
                .monospacedDigit()
                .foregroundStyle(snapshot.governance.isLocked ? SumiInk.seal : SumiInk.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(snapshot.governance.isLocked ? SumiInk.sealWash : SumiInk.paperSoft)
        .overlay(
            Rectangle().stroke(
                (snapshot.governance.isLocked ? SumiInk.seal : SumiInk.ink).opacity(0.55),
                lineWidth: 1
            )
        )
        .padding(.bottom, 12)
        .accessibilityIdentifier("governance-lock-banner")
        .accessibilityLabel(snapshot.governance.bannerCaption)
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
                if let feedback = snapshot.lastFeedback {
                    Text(feedback.uppercased())
                        .font(SumiInk.caption(10))
                        .tracking(1.4)
                        .foregroundStyle(SumiInk.seal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(SumiInk.sealWash)
                        .overlay(Rectangle().stroke(SumiInk.seal.opacity(0.55), lineWidth: 1))
                        .accessibilityIdentifier("habit-credit-feedback")
                }
            }

            HStack(spacing: 18) {
                metric(label: "TODAY", value: snapshot.formattedDailyCredits)
                metric(
                    label: "CAP",
                    value: snapshot.dailyCapReached ? "1.5c LOCKED" : "1.5c OPEN"
                )
            }
        }
        .padding(.vertical, 12)
    }

    private var habitList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DAILY DISCIPLINE")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
                .padding(.bottom, 4)

            if snapshot.habits.isEmpty {
                Text("No micro-habits yet. Add one when configuration is unlocked.")
                    .font(SumiInk.body(13))
                    .foregroundStyle(SumiInk.inkMuted)
                    .padding(.vertical, 12)
            } else {
                ForEach(snapshot.habits) { habit in
                    MicroHabitRow(
                        habit: habit,
                        isDisabled: !habit.canComplete
                    ) {
                        onComplete?(habit.id)
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HABIT EDITOR")
                    .font(SumiInk.caption(10))
                    .tracking(1.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Spacer()
                if snapshot.editorIsLocked {
                    Text("LOCKED")
                        .font(SumiInk.caption(9))
                        .tracking(1.6)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(SumiInk.seal)
                        .accessibilityIdentifier("habit-editor-lock-badge")
                }
            }

            HStack(spacing: 8) {
                TextField("Make bed, stretch…", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(SumiInk.body(13))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(SumiInk.paperSoft)
                    .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))
                    .disabled(snapshot.editorIsLocked)

                editorChip(
                    CreditMath.displayString(HabitCreditMinting.defaultReward),
                    selected: abs(draftReward - 0.25) < 0.001
                ) {
                    draftReward = 0.25
                }
                editorChip("0.5", selected: abs(draftReward - 0.5) < 0.001) {
                    draftReward = 0.5
                }
            }

            HStack(spacing: 8) {
                Text("FREQUENCY")
                    .font(SumiInk.caption(9))
                    .tracking(1.4)
                    .foregroundStyle(SumiInk.inkMuted)
                editorChip("1 / DAY", selected: draftFrequency == 1) {
                    draftFrequency = 1
                }
                editorChip("2 / DAY", selected: draftFrequency == 2) {
                    draftFrequency = 2
                }
                Spacer()
                Button {
                    let title = draftTitle
                    onCreate?(title, draftReward, draftFrequency)
                    draftTitle = ""
                } label: {
                    Text("ADD")
                        .font(SumiInk.caption(10))
                        .tracking(1.4)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(snapshot.editorIsLocked ? SumiInk.inkMuted : SumiInk.seal)
                }
                .buttonStyle(.plain)
                .disabled(snapshot.editorIsLocked || draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(snapshot.editorIsLocked)
            .opacity(snapshot.editorIsLocked ? 0.72 : 1)
        }
        .padding(.top, 10)
        .accessibilityIdentifier("habit-editor")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lastError = snapshot.lastError {
                Text(lastError)
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
                Text(snapshot.weekdayCaption.uppercased())
                    .font(SumiInk.caption(10))
                    .tracking(0.6)
                    .foregroundStyle(SumiInk.inkMuted)
            }
        }
        .padding(.top, 10)
    }

    private func editorChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(SumiInk.caption(9))
                .tracking(0.8)
                .foregroundStyle(selected ? Color.white : SumiInk.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(selected ? SumiInk.ink : SumiInk.paperSoft)
                .overlay(Rectangle().stroke(SumiInk.ink.opacity(selected ? 1 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(snapshot.editorIsLocked)
    }

    private func metric(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(SumiInk.caption(10))
                .tracking(1.6)
                .foregroundStyle(SumiInk.inkMuted)
            Text(value)
                .font(SumiInk.body(13))
                .monospacedDigit()
                .foregroundStyle(SumiInk.ink)
        }
    }
}

struct MicroHabitRow: View {
    var habit: MicroHabitRowSnapshot
    var isDisabled: Bool
    var onComplete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onComplete) {
                ZStack {
                    Rectangle()
                        .stroke(SumiInk.ink, lineWidth: 1)
                        .frame(width: 16, height: 16)
                    if habit.completionsToday > 0 {
                        Rectangle()
                            .fill(SumiInk.seal)
                            .frame(
                                width: habit.isFrequencyReached ? 16 : 10,
                                height: habit.isFrequencyReached ? 16 : 10
                            )
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.45 : 1)
            .accessibilityLabel(habit.title)
            .accessibilityIdentifier("habit-check-\(habit.id.uuidString)")

            VStack(alignment: .leading, spacing: 1) {
                Text(habit.title)
                    .font(SumiInk.body(13))
                    .foregroundStyle(habit.isEnabled ? SumiInk.ink : SumiInk.inkMuted)
                    .lineLimit(1)
                Text(habit.formattedReward)
                    .font(SumiInk.caption(10))
                    .foregroundStyle(SumiInk.seal)
            }

            Spacer(minLength: 8)

            Text(habit.statusCaption)
                .font(SumiInk.caption(10))
                .tracking(1.0)
                .foregroundStyle(habit.canComplete ? SumiInk.inkMuted : SumiInk.seal)
        }
        .padding(.vertical, 5)
        .opacity(habit.isEnabled ? 1 : 0.62)
    }
}
