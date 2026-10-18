import Foundation
import Observation
import VettIDData

/// The canary manifest dialog at the root of the UI.
public enum CanaryManifestPrompt: Equatable, Sendable {
    /// A verified document: install it? (the bytes stay in the view model).
    case confirm(CanaryManifestView)
    /// The document was refused ([code]: one of ``CanaryManifestCodes``, or nil). Nothing changed.
    case refused(code: String?)
    /// Installed.
    case installed(CanaryManifestView)
}

/// A served manifest document handed to the app (``CanaryManifestInbox``, VAULT-RELEASES §10.1 step 9): verified first
/// (pinned keys, format, serial rules), shown to the member, installed only on their confirmation. Opening a file with
/// VettID does nothing else. Mirrors vettid-android `CanaryManifestViewModel`.
@MainActor
@Observable
public final class CanaryManifestViewModel {
    public private(set) var prompt: CanaryManifestPrompt?

    @ObservationIgnored private let inbox: CanaryManifestInbox
    @ObservationIgnored private let repo: any CanaryManifestRepository
    @ObservationIgnored private let work = Work()
    /// The verified document the member is asked about.
    @ObservationIgnored private var pending: [UInt8]?
    /// Bumped by every document taken and every dismissal: the answer of an earlier check is not shown.
    @ObservationIgnored private var generation = 0

    /// The inbox's resets and unreadable files already followed.
    @ObservationIgnored private var resets: Int
    @ObservationIgnored private var unreadable: Int

    public init(inbox: CanaryManifestInbox, repo: any CanaryManifestRepository) {
        self.inbox = inbox
        self.repo = repo
        resets = inbox.resets
        unreadable = inbox.unreadable
    }

    /// The inbox changed: after a wipe of this phone (``CanaryManifestInbox/reset()``) the dialog closes and an answer
    /// still awaited is not shown; a file that could not be read is refused (vettid-android's `canary_refused_other`);
    /// a document waiting is taken (``receive()``).
    public func inboxChanged() {
        if inbox.resets != resets {
            resets = inbox.resets
            dismiss()
        }
        if inbox.unreadable != unreadable {
            unreadable = inbox.unreadable
            dismiss()
            prompt = .refused(code: nil)
        }
        receive()
    }

    deinit { work.cancelAll() }

    /// Takes the document waiting in the inbox, if any: the root of the UI calls it when it appears and whenever the
    /// inbox changes. A newer document replaces the one being asked about.
    public func receive() {
        guard let doc = inbox.document else { return }
        inbox.consume()
        pending = nil
        prompt = nil
        generation += 1
        let g = generation
        work.launch { [weak self] in await self?.check(doc, g) }
    }

    private func check(_ doc: [UInt8], _ g: Int) async {
        let p: CanaryManifestPrompt
        do {
            p = .confirm(try await repo.checkCanaryManifest(doc))
        } catch {
            p = .refused(code: (error as? VaultFailure)?.code)
        }
        guard g == generation else { return }
        if case .confirm = p { pending = doc }
        prompt = p
    }

    /// The member confirmed: verified again and installed (the dialog closes meanwhile).
    public func confirm() {
        guard let doc = pending else { return }
        pending = nil
        prompt = nil
        generation += 1
        let g = generation
        work.launch { [weak self] in await self?.install(doc, g) }
    }

    private func install(_ doc: [UInt8], _ g: Int) async {
        let p: CanaryManifestPrompt
        do {
            p = .installed(try await repo.installCanaryManifest(doc))
        } catch {
            p = .refused(code: (error as? VaultFailure)?.code)
        }
        guard g == generation else { return }
        prompt = p
    }

    public func dismiss() {
        pending = nil
        prompt = nil
        generation += 1
    }

    /// TEST ONLY: returns once the work started has run.
    func settle() async { await work.settle() }
}
