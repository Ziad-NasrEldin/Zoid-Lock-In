import SwiftUI
import UniformTypeIdentifiers
import ZoidLockInCore

/// Native SUMI-E Offline Meeting popover: monotonic timer + triple-artifact dropzone.
public struct OfflineMeetingPopoverView: View {
    public var snapshot: OfflineMeetingSnapshot
    public var onPunchToggle: (() -> Void)?
    public var onSubmit: (() -> Void)?
    public var onAbandon: (() -> Void)?
    public var onImportArtifact: ((MeetingArtifactKind, URL) -> Void)?
    public var onRetryAudit: (() -> Void)?
    public var onAppeal: ((String) -> Void)?

    @State private var importingKind: MeetingArtifactKind?
    @State private var targetedKind: MeetingArtifactKind?
    @State private var confirmAbandon = false
    @State private var showAppeal = false
    @State private var appealStatement = ""

    public init(
        snapshot: OfflineMeetingSnapshot,
        onPunchToggle: (() -> Void)? = nil,
        onSubmit: (() -> Void)? = nil,
        onAbandon: (() -> Void)? = nil,
        onImportArtifact: ((MeetingArtifactKind, URL) -> Void)? = nil,
        onRetryAudit: (() -> Void)? = nil,
        onAppeal: ((String) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onPunchToggle = onPunchToggle
        self.onSubmit = onSubmit
        self.onAbandon = onAbandon
        self.onImportArtifact = onImportArtifact
        self.onRetryAudit = onRetryAudit
        self.onAppeal = onAppeal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(SumiInk.rule)
            timer
            Divider().overlay(SumiInk.rule)
            dropzone
            summary
            if snapshot.phase == .submitted {
                audit
            }
            Spacer(minLength: 8)
            footer
        }
        .padding(22)
        .frame(width: 440, height: 860, alignment: .topLeading)
        .background(MarketplacePaperBackground())
        .fileImporter(
            isPresented: importPresented,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showAppeal) {
            appealSheet
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ZOID LOCK IN")
                    .font(SumiInk.caption(11))
                    .tracking(3.2)
                    .foregroundStyle(SumiInk.inkMuted)
                Text("OFFLINE MEETING")
                    .font(SumiInk.body(15))
                    .foregroundStyle(SumiInk.ink)
            }
            Spacer()
            VermilionSeal(text: "会", size: 38)
        }
        .padding(.bottom, 10)
    }

    private var timer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(snapshot.elapsedCaption)
                    .font(SumiInk.display(42))
                    .monospacedDigit()
                    .foregroundStyle(SumiInk.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                Text("ELAPSED")
                    .font(SumiInk.caption(11))
                    .tracking(2)
                    .foregroundStyle(SumiInk.seal)
                Spacer(minLength: 8)
                Text(snapshot.auditStatusCaption)
                    .font(SumiInk.caption(9))
                    .tracking(1.1)
                    .foregroundStyle(SumiInk.seal)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(SumiInk.sealWash)
                    .overlay(Rectangle().stroke(SumiInk.seal.opacity(0.55), lineWidth: 1))
                    .frame(maxWidth: 148, alignment: .trailing)
            }

            HStack(spacing: 18) {
                metric(label: "IN", value: snapshot.punchInCaption ?? "—")
                metric(label: "OUT", value: snapshot.punchOutCaption ?? "—")
            }

            Text(snapshot.durationCaption ?? "")
                .font(SumiInk.caption(10))
                .tracking(1.2)
                .foregroundStyle(SumiInk.inkMuted)

            Button(action: { onPunchToggle?() }) {
                Text(snapshot.punchButtonTitle)
                    .font(SumiInk.caption(11))
                    .tracking(2.2)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(punchFill)
            }
            .buttonStyle(.plain)
            .disabled(!snapshot.canPunchIn && !snapshot.canPunchOut)
            .opacity((snapshot.canPunchIn || snapshot.canPunchOut) ? 1 : 0.72)
        }
        .padding(.vertical, 10)
    }

    private var dropzone: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TRIPLE ARTIFACT GATE")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
                .padding(.bottom, 4)

            artifactRow(snapshot.notes, glyph: "記")
            artifactRow(snapshot.receipt, glyph: "領")
            artifactRow(snapshot.photo, glyph: "景")
        }
        .padding(.top, 12)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MEETING SUMMARY")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
                .padding(.bottom, 2)

            metric(label: "DURATION", value: snapshot.durationCaption ?? "—")
            metric(label: "STATUS", value: snapshot.auditStatusCaption)
            metric(label: "GATE", value: snapshot.phase == .submitted ? "TRIPLE ARTIFACT VALID" : snapshot.submissionCaption)
        }
        .padding(.top, 16)
    }

    private var audit: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GEMINI AUDIT")
                .font(SumiInk.caption(10))
                .tracking(1.8)
                .foregroundStyle(SumiInk.inkMuted)
                .padding(.bottom, 2)

            Text(snapshot.auditStatusCaption)
                .font(SumiInk.caption(11))
                .tracking(1.4)
                .foregroundStyle(SumiInk.seal)

            if let rationale = snapshot.geminiRationale, !rationale.isEmpty {
                Text(rationale)
                    .font(SumiInk.body(12))
                    .foregroundStyle(SumiInk.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !snapshot.detectedInconsistencies.isEmpty {
                ForEach(snapshot.detectedInconsistencies, id: \.self) { item in
                    Text("· \(item)")
                        .font(SumiInk.body(11))
                        .foregroundStyle(SumiInk.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if snapshot.canRetryAudit, onRetryAudit != nil {
                Button(action: { onRetryAudit?() }) {
                    Text("RETRY FLASH AUDIT")
                        .font(SumiInk.caption(11))
                        .tracking(2.2)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(SumiInk.ink)
                }
                .buttonStyle(.plain)
            }

            if snapshot.canAppeal {
                Button {
                    showAppeal = true
                } label: {
                    Text("APPEAL TO GEMINI PRO")
                        .font(SumiInk.caption(11))
                        .tracking(2.2)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(SumiInk.seal)
                }
                .buttonStyle(.plain)
                .disabled(onAppeal == nil)
                .opacity(onAppeal == nil ? 0.55 : 1)
            }
        }
        .padding(.top, 14)
    }

    private var appealSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GEMINI PRO")
                        .font(SumiInk.caption(11))
                        .tracking(3.2)
                        .foregroundStyle(SumiInk.inkMuted)
                    Text("ARBITRATION APPEAL")
                        .font(SumiInk.body(15))
                        .foregroundStyle(SumiInk.ink)
                }
                Spacer()
                VermilionSeal(text: "審", size: 34)
            }

            Text("Three Flash rejections are on record. Explain the edge case. The statement is sanitized before dispatch.")
                .font(SumiInk.body(12))
                .foregroundStyle(SumiInk.inkMuted)

            TextEditor(text: $appealStatement)
                .font(SumiInk.body(13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 140)
                .background(SumiInk.paperSoft)
                .overlay(Rectangle().stroke(SumiInk.rule, lineWidth: 1))

            Button {
                let statement = appealStatement
                showAppeal = false
                appealStatement = ""
                onAppeal?(statement)
            } label: {
                Text("SUBMIT TO GEMINI PRO")
                    .font(SumiInk.caption(11))
                    .tracking(2.2)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(SumiInk.seal)
            }
            .buttonStyle(.plain)
            .disabled(appealStatement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("DISMISS") {
                showAppeal = false
            }
            .buttonStyle(.plain)
            .font(SumiInk.caption(10))
            .foregroundStyle(SumiInk.inkMuted)
            Spacer()
        }
        .padding(22)
        .frame(width: 420, height: 420)
        .background(SumiInk.paper)
    }

    private func artifactRow(_ status: MeetingArtifactStatus, glyph: String) -> some View {
        let targeted = targetedKind == status.kind
        return HStack(alignment: .center, spacing: 10) {
            Text(glyph)
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(status.isValid ? SumiInk.seal : SumiInk.ink)
                .overlay(Rectangle().stroke(status.isValid ? SumiInk.seal : SumiInk.ink, lineWidth: 1))

            VStack(alignment: .leading, spacing: 1) {
                Text(status.kind.displayName.uppercased())
                    .font(SumiInk.body(13))
                    .foregroundStyle(SumiInk.ink)
                Text(status.caption)
                    .font(SumiInk.body(11))
                    .foregroundStyle(status.isPresent ? SumiInk.seal : SumiInk.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let digest = status.shortDigest {
                Text(digest)
                    .font(SumiInk.caption(9))
                    .monospacedDigit()
                    .foregroundStyle(SumiInk.inkMuted)
            }

            Button {
                importingKind = status.kind
            } label: {
                Text(status.isPresent ? "REPLACE" : "DROP")
                    .font(SumiInk.caption(10))
                    .tracking(1.4)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(status.isPresent ? SumiInk.ink : SumiInk.seal)
            }
            .buttonStyle(.plain)
            .disabled(snapshot.phase == .submitted || onImportArtifact == nil)
            .opacity(snapshot.phase == .submitted ? 0.55 : 1)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(targeted ? SumiInk.sealWash : Color.clear)
        .overlay(
            Rectangle().stroke(
                targeted ? SumiInk.seal : SumiInk.rule,
                lineWidth: targeted ? 1.5 : 1
            )
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            onImportArtifact?(status.kind, url)
            return true
        } isTargeted: { hovering in
            if hovering {
                targetedKind = status.kind
            } else if targetedKind == status.kind {
                targetedKind = nil
            }
        }
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

            Text(snapshot.submissionCaption)
                .font(SumiInk.caption(10))
                .tracking(1.4)
                .foregroundStyle(SumiInk.seal)

            Button(action: { onSubmit?() }) {
                Text("SUBMIT BUNDLE")
                    .font(SumiInk.caption(11))
                    .tracking(2.2)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(snapshot.canSubmit ? SumiInk.seal : SumiInk.inkMuted)
            }
            .buttonStyle(.plain)
            .disabled(!snapshot.canSubmit)
            .opacity(snapshot.canSubmit ? 1 : 0.72)

            Button {
                confirmAbandon = true
            } label: {
                Text("ABANDON MEETING")
                    .font(SumiInk.caption(11))
                    .tracking(2.2)
                    .foregroundStyle(snapshot.canAbandon ? SumiInk.seal : SumiInk.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().stroke(snapshot.canAbandon ? SumiInk.seal : SumiInk.rule, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!snapshot.canAbandon || onAbandon == nil)
            .opacity(snapshot.canAbandon ? 1 : 0.55)
            .confirmationDialog(
                "Abandon this meeting?",
                isPresented: $confirmAbandon,
                titleVisibility: .visible
            ) {
                Button("Abandon Meeting", role: .destructive) {
                    onAbandon?()
                }
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("Elapsed time and staged artifacts will be discarded. Use this after a reboot or a session longer than 240 minutes.")
            }

            HStack {
                Text(snapshot.retentionCaption)
                    .font(SumiInk.caption(9))
                    .tracking(0.8)
                    .foregroundStyle(SumiInk.inkMuted)
                Spacer()
                if let id = snapshot.meetingID {
                    Text(String(id.uuidString.prefix(8)))
                        .font(SumiInk.body(11))
                        .foregroundStyle(SumiInk.inkMuted)
                }
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
                .monospacedDigit()
                .foregroundStyle(SumiInk.ink)
        }
    }

    private var punchFill: Color {
        if snapshot.canPunchIn {
            return SumiInk.seal
        }
        if snapshot.canPunchOut {
            return SumiInk.ink
        }
        return SumiInk.inkMuted
    }

    private var importPresented: Binding<Bool> {
        Binding(
            get: { importingKind != nil },
            set: { if !$0 { importingKind = nil } }
        )
    }

    private var importTypes: [UTType] {
        (importingKind ?? .notes).allowedContentTypes
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let kind = importingKind
        importingKind = nil
        guard let kind else { return }
        if case let .success(urls) = result, let url = urls.first {
            onImportArtifact?(kind, url)
        }
    }
}

extension MeetingArtifactKind {
    var allowedContentTypes: [UTType] {
        switch self {
        case .notes:
            return [UTType(filenameExtension: "md") ?? .text, .plainText]
        case .receipt:
            return [.jpeg, .png, .pdf]
        case .environmentPhoto:
            return [.jpeg, UTType("public.heic") ?? .jpeg, UTType("public.heif") ?? .jpeg]
        }
    }
}

public enum MenuBarCompanionSurface: String, Sendable, Equatable {
    case market
    case meeting
}
