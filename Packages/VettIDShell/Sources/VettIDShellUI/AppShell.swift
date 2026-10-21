#if os(iOS)
import SwiftUI
import VettIDApprovals
import VettIDApprovalsUI
import VettIDConnections
import VettIDConnectionsUI
import VettIDData
import VettIDHistory
import VettIDHistoryUI
import VettIDItems
import VettIDItemsUI
import VettIDMessages
import VettIDMessagesUI
import VettIDNotifications
import VettIDNotificationsUI
import VettIDOnboarding
import VettIDOnboardingUI
import VettIDSettings
import VettIDSettingsUI
import VettIDShell
import VettIDUI

/// The open app (IOS-PLAN ID14): the slide-in drawer, the only top-level navigation (no tab bar), with its destinations in
/// vettid-android's order; the owner check's banners above every screen; a navigation stack per destination for the
/// screens pushed over it, with the system back gesture; the avatar sheet; and the owner check the member asks for
/// ("Check now", turning the hold off) over everything. The check past the deadline is the root's (``OwnerCheckGate``),
/// before the shell. The clone alarm's banner goes first, the rotation offer last, in vettid-android's order; those of later
/// rows (a pending deletion, the notifications note) go between them. Mirrors vettid-android `AppShell`.
public struct AppShell: View {
    private let account: any AccountRepository
    private let vault: any VaultRepository
    let ownerChecks: any OwnerCheckRepository
    private let credential: any CredentialRepository
    private let profiles: any ProfileRepository
    private let appLock: any AppLockSettings
    @Bindable var model: ShellModel
    private let gate: OwnerCheckGate
    private let now: Date
    private let version: AppVersion
    private let installedFrom: InstalledFrom
    private let promptReason: String
    private let canary: (any CanaryManifestRepository)?
    private let canaryInbox: CanaryManifestInbox?
    private let releaseUpdates: (any ReleaseUpdateRepository)?
    private let releaseNotes: (any ReleaseNotesRepository)?
    private let releaseInbox: ReleaseUpdateInbox?
    let connections: (any ConnectionsRepository)?
    private let connectionRequests: (any ConnectionRequestsRepository)?
    private let inviteInbox: InviteLinkInbox?
    private let messages: (any MessagesRepository)?
    private let attachments: (any AttachmentsRepository)?
    let feed: (any FeedRepository)?
    let approvals: (any ApprovalsRepository)?
    let history: (any HistoryRepository)?
    let historyExport: (any HistoryExportRepository)?
    let items: (any ItemsRepository)?
    let sharing: (any SharingRepository)?
    private let onOpenPortal: @MainActor () -> Void
    /// The member's own profile photo (VAULT-MESSAGING §10.8), decoded once per photo, for the top bar's avatar, the avatar
    /// sheet and the account card (vettid-android `rememberProfilePhoto(ownPhoto)`).
    @State private var ownPhoto: UIImage?
    /// The tags' colours while the vault is open (owner decision 2026-10-09): made with the shell, so nothing runs while
    /// the vault is locked.
    @State var tagColors: TagColorsKeeper?

    /// [model]: where the member is, owned above the owner check's gate. [gate]: the owner check at [now] (the root re-reads
    /// it as time passes). [promptReason]: what the Face ID, Touch ID or passcode prompt says when the app lock is turned on.
    /// [canary] and [canaryInbox]: the canary manifest on Settings → Attestation (VAULT-RELEASES §10.1 step 9).
    /// [releaseUpdates] and [releaseNotes]: Settings → Vault → "Update available" and its screen (RELEASE-UPDATES §2).
    /// [connections], [connectionRequests] and [inviteInbox]: the connect flow and an invitation link the app was opened
    /// with (VAULT-MESSAGING §6.4). [messages]: Messages, its conversations and the new-message picker (§10.5), with
    /// [connections]; [attachments]: their photos and the viewer (§10.5.1). [feed]: the bell and the Notifications screen (§10.9); [approvals]: Approvals and its decisions
    /// (§10.4, §10.12, §10.13), with [connections]. [history] and [historyExport]: History, its entries and its export
    /// (§10.9). [items] and [sharing]: the Vault, its items and their tags (§10.7, §10.8).
    public init(
        account: any AccountRepository,
        vault: any VaultRepository,
        ownerChecks: any OwnerCheckRepository,
        credential: any CredentialRepository,
        profiles: any ProfileRepository,
        appLock: any AppLockSettings,
        model: ShellModel,
        gate: OwnerCheckGate,
        now: Date,
        version: AppVersion,
        installedFrom: InstalledFrom,
        promptReason: String,
        canary: (any CanaryManifestRepository)? = nil,
        canaryInbox: CanaryManifestInbox? = nil,
        releaseUpdates: (any ReleaseUpdateRepository)? = nil,
        releaseNotes: (any ReleaseNotesRepository)? = nil,
        releaseInbox: ReleaseUpdateInbox? = nil,
        connections: (any ConnectionsRepository)? = nil,
        connectionRequests: (any ConnectionRequestsRepository)? = nil,
        inviteInbox: InviteLinkInbox? = nil,
        messages: (any MessagesRepository)? = nil,
        attachments: (any AttachmentsRepository)? = nil,
        feed: (any FeedRepository)? = nil,
        approvals: (any ApprovalsRepository)? = nil,
        history: (any HistoryRepository)? = nil,
        historyExport: (any HistoryExportRepository)? = nil,
        items: (any ItemsRepository)? = nil,
        sharing: (any SharingRepository)? = nil,
        onOpenPortal: @escaping @MainActor () -> Void
    ) {
        self.account = account
        self.vault = vault
        self.ownerChecks = ownerChecks
        self.credential = credential
        self.profiles = profiles
        self.appLock = appLock
        self.model = model
        self.gate = gate
        self.now = now
        self.version = version
        self.installedFrom = installedFrom
        self.promptReason = promptReason
        self.canary = canary
        self.canaryInbox = canaryInbox
        self.releaseUpdates = releaseUpdates
        self.releaseNotes = releaseNotes
        self.releaseInbox = releaseInbox
        self.connections = connections
        self.connectionRequests = connectionRequests
        self.inviteInbox = inviteInbox
        self.messages = messages
        self.attachments = attachments
        self.feed = feed
        self.approvals = approvals
        self.history = history
        self.historyExport = historyExport
        self.items = items
        self.sharing = sharing
        self.onOpenPortal = onOpenPortal
    }

    /// A lost answer's decision reached while its screen was closed (VAULT-MESSAGING §11.14.9): once, until "OK".
    @ViewBuilder private var changeCheckNotice: some View {
        // A change screen waiting for it shows the decision itself.
        if let check = vault.changeCheck, let text = ChangeCheckNotice.text(check, timeScale: vault.timeScale), !vault.changeCheckAwaited {
            if ChangeCheckNotice.offersLockAndUnlock(check) {
                // The PIN is uncertain: the unlock's two prompts settle it at no cost (§11.14.9 step 3).
                UrgentBanner(
                    text, actionLabel: ChangeCheckNotice.lockAndUnlock, onDismiss: { vault.acknowledgeChangeCheck() },
                    action: {
                        vault.acknowledgeChangeCheck()
                        Task { try? await vault.lock() }
                    }
                )
                .accessibilityIdentifier("change_check_notice")
            } else if ChangeCheckNotice.urgent(check) {
                UrgentBanner(text, actionLabel: ShellStrings.ownerCheckNoticeOk, action: { vault.acknowledgeChangeCheck() })
                    .accessibilityIdentifier("change_check_notice")
            } else {
                InfoBanner(text, actionLabel: ShellStrings.ownerCheckNoticeOk, onAction: { vault.acknowledgeChangeCheck() })
                    .accessibilityIdentifier("change_check_notice")
            }
        }
    }

    /// (IOS-PLAN §6.3 item 5) The earlier-secret step opened the vault: a new phone secret at once, until one is made or
    /// the member dismisses the prompt. Hidden while New phone secret is open.
    @ViewBuilder private var renewPrompt: some View {
        if vault.renewSecretSuggested, model.path.last != .newPhoneSecret {
            InfoBanner(
                ShellStrings.renewPrompt, actionLabel: ShellStrings.renewPromptAction,
                onAction: { model.push(.newPhoneSecret) }, onDismiss: { vault.dismissRenewSuggestion() }
            )
            .accessibilityIdentifier("renew_prompt")
        }
    }

    /// The clone alarm (VAULT-MESSAGING §3.5.9): an urgent banner above every screen until it is resolved; hidden on the
    /// alarm's own screen.
    @ViewBuilder private var alarmBanner: some View {
        if credential.alarm != nil, model.path.last != .alarm {
            UrgentBanner(ShellStrings.alarmBanner, actionLabel: ShellStrings.alarmReview) { model.push(.alarm) }
                .accessibilityIdentifier("alarm_banner")
        }
    }

    /// (Release R, ANDROID-PLAN "Transfer") The offer to rotate the vault's keys after a PIN or password change: it stays
    /// until a rotation succeeds or the member puts it away, and is hidden on the rotation screen.
    @ViewBuilder private var rotateOffer: some View {
        if vault.rotateOffered, model.path.last != .rotate {
            InfoBanner(
                ShellStrings.rotateOffer, actionLabel: ShellStrings.rotateOfferAction,
                onAction: { model.push(.rotate) }, onDismiss: { vault.dismissRotateOffer() }
            )
            .accessibilityIdentifier("rotate_offer")
        }
    }

    public var body: some View {
        ZStack {
            DrawerContainer(isOpen: $model.drawerOpen) {
                VettIDDrawerSheet(
                    sections: TopLevelDestination.drawerSections(badges: badges),
                    selectedKey: model.destination.key,
                    versionLabel: ShellStrings.drawerVersion(version.name, version.build)
                ) { item in
                    if let d = TopLevelDestination.fromKey(item.key) { model.navigate(d) } else { model.drawerOpen = false }
                }
            } content: {
                VStack(spacing: 0) {
                    alarmBanner
                    OwnerCheckBanners(
                        gate: gate, now: now, onCheckNow: { model.ownerCheck(holdOff: false) },
                        onHoldOn: { Task { await model.turnHoldOn() } }, onDismissNotices: { Task { await model.dismissNotices() } }
                    )
                    if let releaseUpdates, model.path.last != .releaseUpdate {
                        ReleaseUpdateBanner(updates: releaseUpdates) { model.push(.releaseUpdate) }
                    }
                    changeCheckNotice
                    renewPrompt
                    rotateOffer
                    NavigationStack(path: $model.path) {
                        root
                            .toolbar(.hidden, for: .navigationBar)
                            .systemBackGesture()
                            .navigationDestination(for: ShellRoute.self) { route in
                                detail(route).toolbar(.hidden, for: .navigationBar)
                            }
                    }
                }
                // The open app, for UI tests (a container: what is inside keeps its own identifiers).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("app_shell")
            }
            // While the asked check is shown, nothing of the vault under it is visible or reachable, VoiceOver included
            // (VAULT-MESSAGING §3.6.5).
            .accessibilityHidden(model.asked != nil)
            .allowsHitTesting(model.asked == nil)
            if let mode = model.asked {
                OwnerCheckFlow(
                    mode: mode, repo: ownerChecks, vault: vault, onDone: { model.ownerCheckDone() }, onCancel: { model.ownerCheckDone() }
                )
                .accessibilityAddTraits(.isModal)
                .transition(.move(edge: .bottom))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.asked)
        // A request to open the update screen (on Android a notification tap; on the iPhone with phase P) waits until the
        // open app is shown.
        .onAppear {
            openRequestedUpdate()
            openInvite()
        }
        .onChange(of: releaseInbox?.pending) { _, _ in openRequestedUpdate() }
        // An invitation link the app was opened with (§6.4) waits until the open app is shown: the accept screen, where
        // the member confirms.
        .onChange(of: inviteInbox?.link) { _, _ in openInvite() }
        .avatarSheet(isPresented: $model.showAccount) {
            AccountSheet(
                account: account.account,
                photo: ownPhoto,
                onLockVault: { Task { await model.lockVault() } },
                onChangeName: { model.changeName() },
                onSharedProfile: { model.sharedProfile() },
                onOpenPortal: onOpenPortal
            )
        }
        .environment(\.vettIDTagColors, tagColors?.colors ?? [:])
        .onAppear { startTagColors() }
        .task(id: profiles.profile?.photo) {
            let decoded = await ProfilePhotos.decoded(profiles.profile?.photo)
            // A decode that began before the photo changed or was cleared does not show it after (IOS-PLAN §4.7).
            guard !Task.isCancelled else { return }
            ownPhoto = decoded
        }
    }

    private func openRequestedUpdate() {
        guard let inbox = releaseInbox, inbox.pending else { return }
        inbox.consume()
        if releaseUpdates != nil, model.path.last != .releaseUpdate { model.push(.releaseUpdate) }
    }

    private func openInvite() {
        guard let inbox = inviteInbox, let link = inbox.link else { return }
        inbox.consume()
        if connections != nil, connectionRequests != nil { model.openInvite(link) }
    }

    /// The drawer's counts (vettid-android `ShellBadges`): the approvals waiting for a decision, the conversations with
    /// unread messages.
    private var badges: [TopLevelDestination: Int] {
        [
            .approvals: approvals?.approvals.count { $0.needsDecision } ?? 0,
            .messages: messages?.conversations.count { $0.unread > 0 } ?? 0,
        ]
    }

    private var chrome: ShellChrome {
        let model = model
        return ShellChrome(
            accountName: AccountHeader.name(account.account, placeholder: ShellStrings.accountPlaceholderName),
            accountPhoto: ownPhoto,
            // The bell on every drawer screen; none while the vault is held or the daily check is due (§3.6.3).
            bell: NotificationsBell.of(feed, held: gate.gated) { model.openNotifications() },
            onMenu: { model.drawerOpen = true },
            onAvatar: { model.showAccount = true }
        )
    }

    @ViewBuilder private var root: some View {
        switch model.destination {
        case .settings:
            SettingsRoute(
                account: account, vault: vault, ownerChecks: ownerChecks, appLock: appLock, updates: releaseUpdates,
                promptReason: promptReason, host: settingsHost, accountPhoto: ownPhoto
            )
        case .help:
            // A back arrow, as on Android, where it returns to the start destination.
            HelpScreen { model.back() }
        case .messages:
            if let messages, connections != nil {
                MessagesRoute(messages: messages, ownerChecks: ownerChecks, chrome: chrome, host: messagesHost)
            } else {
                ComingLaterScreen(destination: model.destination, chrome: chrome)
            }
        case .approvals:
            if let approvals, let connections {
                ApprovalsRoute(
                    approvals: approvals, connections: connections, ownerChecks: ownerChecks, chrome: chrome, host: approvalsHost
                )
            } else {
                ComingLaterScreen(destination: model.destination, chrome: chrome)
            }
        case .history:
            if let history, let historyExport {
                HistoryRoute(
                    history: history, export: historyExport, connections: connections, ownerChecks: ownerChecks, items: items,
                    chrome: chrome, host: historyHost
                )
            } else {
                ComingLaterScreen(destination: model.destination, chrome: chrome)
            }
        case .items:
            if let items {
                ItemsRoute(items: items, ownerChecks: ownerChecks, chrome: chrome, host: itemsHost)
            } else {
                ComingLaterScreen(destination: model.destination, chrome: chrome)
            }
        case .connections:
            if let connections, let connectionRequests {
                ConnectionsRoute(
                    connections: connections, requests: connectionRequests, ownerChecks: ownerChecks, account: account, chrome: chrome,
                    host: connectHost
                )
            } else {
                ComingLaterScreen(destination: model.destination, chrome: chrome)
            }
        }
    }

    @ViewBuilder private func detail(_ route: ShellRoute) -> some View {
        switch route {
        case .vaultStatus:
            VaultStatusRoute(vault: vault, installedFrom: installedFrom) { model.pop() }
        case .attestation:
            AttestationRoute(vault: vault, canary: canary, canaryInbox: canaryInbox) { model.pop() }
        case .changeName, .sharedProfile:
            profileDetail(route)
        case .changePin, .newPhoneSecret, .deleteVault:
            securityDetail(route)
        case .credential, .changePassword, .rotate, .alarm, .newCredential:
            credentialDetail(route)
        case .releaseUpdate, .connect, .connection:
            featureDetail(route)
        case .conversation, .newMessage, .photo:
            messagesDetail(route)
        case .notifications, .approval, .historyEntry, .connectionHistory:
            activityDetail(route)
        case .item, .newItem, .itemEdit, .tags:
            itemsDetail(route)
        }
    }

    /// The PIN change, a new phone secret and the vault's deletion, from Settings.
    @ViewBuilder private func securityDetail(_ route: ShellRoute) -> some View {
        switch route {
        case .changePin(let fromAttempts):
            ChangePinRoute(vault: vault, fromAttempts: fromAttempts) { model.pop() }
        case .newPhoneSecret:
            NewPhoneSecretRoute(vault: vault) { model.pop() }
        default:
            DeleteVaultRoute(vault: vault) { model.pop() }
        }
    }

    /// The account's names and the shared profile (VAULT-MESSAGING §10.8).
    @ViewBuilder private func profileDetail(_ route: ShellRoute) -> some View {
        if route == .sharedProfile {
            SharedProfileRoute(
                profiles: profiles, accounts: account, items: items, onOpenItem: { model.openItem($0) },
                onChangeName: { model.push(.changeName) }
            ) { model.pop() }
        } else {
            ChangeNameRoute(accounts: account, profiles: profiles) { model.pop() }
        }
    }

    /// The screens of the features over the vault: the release update, the connect flow, a connection's detail.
    @ViewBuilder private func featureDetail(_ route: ShellRoute) -> some View {
        switch route {
        case .releaseUpdate:
            if let releaseUpdates, let releaseNotes {
                ReleaseUpdateRoute(updates: releaseUpdates, ownerCheck: ownerChecks, notes: releaseNotes) { model.pop() }
            }
        case .connect(let destination):
            if let connections, let connectionRequests {
                ConnectRoute(destination, connections: connections, requests: connectionRequests, host: connectHost)
            }
        case .connection(let id):
            if let connections { ConnectionDetailRoute(id, connections: connections, host: connectHost) }
        default:
            EmptyView()
        }
    }

    /// A conversation, the new-message picker and the photo viewer (vettid-android's `messagesDestination`).
    @ViewBuilder private func messagesDetail(_ route: ShellRoute) -> some View {
        switch route {
        case .conversation(let id):
            if let messages, let connections {
                ConversationRoute(id, messages: messages, connections: connections, attachments: attachments, host: messagesHost)
            }
        case .newMessage:
            if let connections { NewMessageRoute(connections: connections, host: messagesHost) }
        case .photo(let connectionID, let messageID):
            if let attachments, let messages {
                PhotoViewerRoute(
                    connectionID: connectionID, messageID: messageID, attachments: attachments, messages: messages, host: messagesHost
                )
            }
        default:
            EmptyView()
        }
    }

    /// The Credential screen and the screens pushed from it (vettid-android's `credentialDestination`).
    @ViewBuilder private func credentialDetail(_ route: ShellRoute) -> some View {
        switch route {
        case .changePassword:
            ChangePasswordRoute(repo: credential, vault: vault) { model.pop() }
        case .rotate:
            RotateRoute(repo: credential) { model.pop() }
        case .alarm:
            AlarmRoute(repo: credential) { model.pop() }
        case .newCredential:
            NewCredentialRoute(repo: credential, vault: vault) { model.pop() }
        default:
            CredentialRoute(
                repo: credential, onBack: { model.pop() }, onChangePassword: { model.push(.changePassword) },
                onOwnerCheck: { model.ownerCheck(holdOff: false) }, more: credentialLinks
            )
        }
    }

    private var credentialLinks: CredentialRouteLinks {
        let model = model
        var l = CredentialRouteLinks()
        l.onRotate = { model.push(.rotate) }
        l.onReviewAlarm = { model.push(.alarm) }
        l.onNewCredential = { model.push(.newCredential) }
        return l
    }

    private var connectHost: ConnectHost {
        let model = model
        var h = ConnectHost()
        h.onBack = { model.pop() }
        h.replace = { model.replace(.connect($0)) }
        h.push = { model.push(.connect($0)) }
        h.onOpenConnection = { model.push(.connection($0)) }
        h.replaceWithConnection = { model.replace(.connection($0)) }
        // A connection's History, once History is there (IOS-PLAN §8 I2.3).
        if history != nil, historyExport != nil { h.onOpenHistory = { model.openConnectionHistory($0) } }
        // "Send a message" on a connection's page and after connecting, once the messages are there (IOS-PLAN §8 I2.2).
        if messages != nil { h.onOpenConversation = { model.openConversation($0) } }
        return h
    }

    /// Where the Messages screens go (vettid-android `MessagesHost`).
    private var messagesHost: MessagesHost {
        let model = model
        var h = MessagesHost()
        h.onBack = { model.pop() }
        h.onOpenConversation = { model.openConversation($0) }
        h.onCompose = { model.push(.newMessage) }
        h.onOpenConnection = { model.push(.connection($0)) }
        h.onInvite = { model.push(.connect(.invite)) }
        h.onInviteLink = { model.openInvite($0) }
        h.onOpenPhoto = { model.push(.photo(connectionID: $0, messageID: $1)) }
        return h
    }

    private var settingsHost: SettingsHost {
        let model = model
        var h = SettingsHost()
        // Settings has a back arrow, as on Android, where it returns to the start destination.
        h.onBack = { model.back() }
        h.onAccount = { model.showAccount = true }
        h.onOpenAccountSite = onOpenPortal
        h.onVaultStatus = { model.push(.vaultStatus) }
        h.onReleaseUpdate = { model.push(.releaseUpdate) }
        h.onAttestation = { model.push(.attestation) }
        h.onChangePin = { model.push(.changePin(fromAttempts: false)) }
        h.onCredential = { model.push(.credential) }
        h.onNewPhoneSecret = { model.push(.newPhoneSecret) }
        h.onDeleteVault = { model.push(.deleteVault) }
        h.onSharedProfile = { model.push(.sharedProfile) }
        h.onOwnerCheck = { holdOff in model.ownerCheck(holdOff: holdOff) }
        return h
    }
}
#endif
