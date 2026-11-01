#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VettIDData
import VettIDUI
import VettIDVotes

/// What the vote screen can ask for. Mirrors vettid-android `VoteActions`.
public struct VoteActions {
    public var onBack: @MainActor () -> Void = {}
    public var onRetry: @MainActor () -> Void = {}
    public var onSelect: @MainActor (String) -> Void = { _ in }
    public var onCast: @MainActor () -> Void = {}
    public var onConfirmCast: @MainActor () -> Void = {}
    public var onDismissCast: @MainActor () -> Void = {}
    public var onPassword: @MainActor (String) -> Void = { _ in }
    public var onSubmitPassword: @MainActor () -> Void = {}
    public var onCheck: @MainActor () -> Void = {}
    public var onAnswerRestore: @MainActor (Bool) -> Void = { _ in }
    public var onSaveProof: @MainActor () -> Void = {}
    public var onDismissProofWarning: @MainActor () -> Void = {}
    public var onFetchProof: @MainActor () -> Void = {}
    /// The system exporter's answer: written where the member chose (true), or cancelled or dismissed (false).
    public var onProofExporterAnswered: @MainActor (Bool) -> Void = { _ in }
    public var onProofExporterFailed: @MainActor () -> Void = {}
    public var onProofShown: @MainActor () -> Void = {}
    public var onRelease: @MainActor () -> Void = {}
    public var onDismissRelease: @MainActor () -> Void = {}
    /// The vault PIN, taken from the in-app keypad as the request is sent (IOS-PLAN §6.5).
    public var onConfirmRelease: @MainActor (String) -> Void = { _ in }
    public var onDismissCastProblem: @MainActor () -> Void = {}
    public var onCloseWindow: @MainActor () -> Void = {}
    public var onDismissAlreadyVoted: @MainActor () -> Void = {}
    /// The app went to the background or the iPhone locked: the password goes.
    public var onForgetSecrets: @MainActor () -> Void = {}
    /// The screen left: the password and unsaved evidence go.
    public var onLeave: @MainActor () -> Void = {}

    public init() {}
}

/// One vote (ANDROID-PLAN 0.1.102 to 0.1.108 §4 "Votes", screens 2 to 7). The service's words are shown as plain text; the
/// disclosure sentence is the app's own and fixed. The screen, its sheets and the proof are kept out of screenshots and
/// screen recordings (IOS-PLAN §4.16 "Screen privacy"): the vote's choice is shown here. Mirrors vettid-android
/// `VoteScreen`.
public struct VoteScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.vettIDTimeScale) private var timeScale
    @Environment(ScreenshotAllowance.self) private var allowance: ScreenshotAllowance?
    let state: VoteScreenState
    let proof: ProofFile?
    let actions: VoteActions
    @State private var exporting = false

    public init(state: VoteScreenState, proof: ProofFile? = nil, actions: VoteActions) {
        self.state = state
        self.proof = proof
        self.actions = actions
    }

    public var body: some View {
        SecureContainer(isSecure: !(allowance?.allowed ?? false)) {
            DetailScaffold(onBack: actions.onBack) { content }
                .accessibilityIdentifier("vote_screen")
        }
        .sheet(isPresented: castSheet) {
            CastSheet(state: state, actions: actions).vettIDGrowingSheet()
                .interactiveDismissDisabled(state.cast == .sending)
        }
        .sheet(isPresented: Binding(get: { state.restoreAsked }, set: { _ in })) {
            RestoreSheet(state: state, actions: actions).vettIDGrowingSheet().interactiveDismissDisabled(true)
        }
        .sheet(isPresented: Binding(get: { state.releaseDialog }, set: { if !$0 { actions.onDismissRelease() } })) {
            ReleaseSheet(state: state, actions: actions).vettIDGrowingSheet()
        }
        .confirmDialog(
            isPresented: Binding(get: { state.proofWarning }, set: { if !$0 { actions.onDismissProofWarning() } }),
            title: VoteStrings.voteSaveProof,
            message: VoteStrings.voteSaveProofWarning,
            confirmLabel: VoteStrings.voteProofSave,
            onConfirm: actions.onFetchProof
        )
        // The system's exporter writes the vault's evidence, unchanged, only where the member chooses (IOS-PLAN §4.16).
        .fileExporter(
            isPresented: $exporting, document: proof.map(ProofDocument.init), contentTypes: [.json],
            defaultFilename: proof?.name ?? "vettid-vote.json",
            onCompletion: { result in
                switch result {
                case .success: actions.onProofExporterAnswered(true)
                case .failure(let error as CocoaError) where error.code == .userCancelled: actions.onProofExporterAnswered(false)
                case .failure: actions.onProofExporterFailed()
                }
            },
            onCancellation: { actions.onProofExporterAnswered(false) }
        )
        .onChange(of: state.proofReady, initial: true) { _, ready in if ready, proof != nil { exporting = true } }
        .onChange(of: proof) { _, p in if p != nil, state.proofReady { exporting = true } }
        // The result of a save is announced, once.
        .onChange(of: state.proofSaved) { _, saved in if saved { Announcer.announce(VoteStrings.voteProofSaved, .polite) } }
        .onChange(of: state.proofSaveFailed) { _, failed in if failed { Announcer.announce(VoteStrings.voteProofFailed, .assertive) } }
        .onDisappear { actions.onLeave() }
        .onChange(of: scenePhase) { _, now in if now == .background { actions.onForgetSecrets() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            actions.onForgetSecrets()
        }
    }

    /// While a cast is on its way the sheet it was started from stays, busy; the sheet shows the confirm step, then the
    /// password step in place.
    private var castSheet: Binding<Bool> {
        Binding(get: { state.cast != .none }, set: { if !$0 { actions.onDismissCast() } })
    }

    @ViewBuilder private var content: some View {
        if let s = state.summary {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VoteContent(state: state, facts: VoteFacts.of(state, summary: s, now: context.date, timeScale: timeScale), actions: actions)
            }
        } else if state.loadError != nil {
            loadFailed
        } else if state.loaded {
            NoticeCard(.info, title: VoteStrings.voteGoneTitle, message: VoteStrings.votesEmptyBody)
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("vote_gone")
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("vote_loading")
        }
    }

    private var loadFailed: some View {
        let kind = state.loadError?.kind ?? .other
        return NoticeCard(.warning, title: VoteStrings.voteErrorTitle, message: kind.message(timeScale: 1), announce: .polite) {
            NoticeAction(label: VoteStrings.votesRetry, identifier: "vote_retry", action: actions.onRetry)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("vote_load_failed")
    }
}

/// The evidence for `fileExporter`: its bytes from memory, never read back.
struct ProofDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let bytes: Data

    init(_ file: ProofFile) { bytes = file.bytes }

    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}
#endif
