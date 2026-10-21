#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDData
import VettIDUI

/// Where the Approvals screens go: one approval's decision screen (by its ``PendingApproval/key``), and back. Mirrors the
/// navigation of vettid-android `approvalsDestination`.
public struct ApprovalsHost {
    public var onOpen: @MainActor (String) -> Void = { _ in }
    public var onBack: @MainActor () -> Void = {}

    public init() {}
}

/// The Approvals list with its view model. Mirrors vettid-android `approvalsDestination`'s `ApprovalsRoute`.
public struct ApprovalsRoute: View {
    private let approvals: any ApprovalsRepository
    private let connections: any ConnectionsRepository
    private let ownerChecks: (any OwnerCheckRepository)?
    private let chrome: ShellChrome
    private let host: ApprovalsHost
    @State private var model: ApprovalsViewModel?

    /// [ownerChecks]: a list refused because the daily check was due reads again once a check passes.
    public init(
        approvals: any ApprovalsRepository, connections: any ConnectionsRepository, ownerChecks: (any OwnerCheckRepository)? = nil,
        chrome: ShellChrome, host: ApprovalsHost
    ) {
        self.approvals = approvals
        self.connections = connections
        self.ownerChecks = ownerChecks
        self.chrome = chrome
        self.host = host
    }

    public var body: some View {
        ApprovalsScreen(state: model?.state ?? ApprovalsState(), chrome: chrome, actions: actions)
            .onAppear {
                guard model == nil else { return }
                model = ApprovalsViewModel(approvals: approvals, connections: connections, ownerChecks: ownerChecks)
            }
    }

    private var actions: ApprovalsActions {
        var a = ApprovalsActions()
        a.onOpen = host.onOpen
        guard let m = model else { return a }
        a.onRetry = { m.refresh() }
        a.onDismissPeerDecline = { m.dismissPeerDecline($0) }
        a.onResume = { m.resumeAsks($0) }
        a.onAskRemove = { m.askRemove($0) }
        a.onRemove = { m.remove() }
        return a
    }
}

/// One approval's decision screen with its view model. Mirrors vettid-android `approvalsDestination`'s
/// `ApprovalDetailRoute`.
public struct ApprovalDetailRoute: View {
    private let key: String
    private let approvals: any ApprovalsRepository
    private let connections: (any ConnectionsRepository)?
    private let items: (any ItemsRepository)?
    private let host: ApprovalsHost
    @State private var model: ApprovalDetailViewModel?

    /// [items]: the Vault list, whose items a category entry can be answered with.
    public init(
        _ key: String, approvals: any ApprovalsRepository, connections: (any ConnectionsRepository)? = nil,
        items: (any ItemsRepository)? = nil, host: ApprovalsHost
    ) {
        self.key = key
        self.approvals = approvals
        self.connections = connections
        self.items = items
        self.host = host
    }

    public var body: some View {
        ApprovalDetailScreen(state: model?.state ?? ApprovalDetailState(key: key), actions: actions)
            .onAppear {
                guard model == nil else { return }
                let answers = (items?.items ?? []).map {
                    AnswerItem(id: $0.itemID, name: $0.name, category: $0.category, critical: $0.sensitivity == .critical)
                }
                model = ApprovalDetailViewModel(key: key, approvals: approvals, connections: connections, items: answers)
            }
    }

    private var actions: DecisionActions {
        var a = DecisionActions()
        a.onBack = host.onBack
        guard let m = model else { return a }
        a.onPassword = { m.setPassword($0) }
        a.onApprove = { m.approve() }
        a.onDeny = { m.deny() }
        a.onAskBlock = { m.askBlock($0) }
        a.onBlock = { m.block() }
        a.onToggleShareItem = { m.toggleShareItem($0) }
        a.onToggleGrant = { m.toggleGrantEntry($0) }
        a.onAnswerGrant = { m.answerGrantEntry($0, itemID: $1) }
        a.onGrantUses = { m.setGrantUses($0) }
        a.onGrantExpiresIn = { m.setGrantExpiresIn($0) }
        a.onFinish = { m.finish() }
        a.onForgetSecrets = { m.forgetSecrets() }
        return a
    }
}
#endif
