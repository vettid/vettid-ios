#if os(iOS)
import SwiftUI
import VettIDData
import VettIDHistory
import VettIDUI

/// What the History destinations need from the app shell. Mirrors vettid-android `HistoryHost`.
public struct HistoryHost {
    /// An entry's screen, by its `seq`.
    public var onOpenEntry: @MainActor (Int64) -> Void = { _ in }
    public var onBack: @MainActor () -> Void = {}
    /// A connection's page (the entry's connection).
    public var onOpenConnection: @MainActor (String) -> Void = { _ in }
    /// An item of the Vault (an item entry's); nil until the Vault screens (IOS-PLAN §8 I3.1).
    public var onOpenItem: (@MainActor (String) -> Void)?
    /// The credential alarm (an open alarm refuses an export).
    public var onOpenAlarm: @MainActor () -> Void = {}
    /// The daily check (an export answered `owner_check_required`).
    public var onOwnerCheck: @MainActor () -> Void = {}

    public init() {}
}

/// History with its export, and their view models, made when the screen first appears and released when it goes: from
/// the drawer ([chrome]) or a connection's page ([connectionID], with a back arrow). Each time the list is shown again
/// (back from an entry, the export closed, which the vault recorded as `audit.exported`), its newest entries are read
/// again. While an export is under way its steps take the list's place. Mirrors vettid-android `historyDestination`.
public struct HistoryRoute: View {
    private let history: any HistoryRepository
    private let export: any HistoryExportRepository
    private let connections: (any ConnectionsRepository)?
    private let ownerChecks: (any OwnerCheckRepository)?
    private let connectionID: String?
    private let chrome: ShellChrome?
    private let host: HistoryHost
    @State private var model: HistoryViewModel?
    @State private var exportModel: HistoryExportViewModel?

    public init(
        history: any HistoryRepository, export: any HistoryExportRepository, connections: (any ConnectionsRepository)? = nil,
        ownerChecks: (any OwnerCheckRepository)? = nil, connectionID: String? = nil, chrome: ShellChrome?, host: HistoryHost
    ) {
        self.history = history
        self.export = export
        self.connections = connections
        self.ownerChecks = ownerChecks
        self.connectionID = connectionID
        self.chrome = chrome
        self.host = host
    }

    public var body: some View {
        let state = model?.state ?? HistoryState(filter: AuditFilter(connectionID: connectionID))
        let step = exportModel?.step ?? .closed
        ZStack {
            if step == .closed {
                HistoryScreen(state: state, chrome: chrome, onBack: connectionID == nil ? nil : host.onBack, actions: actions)
                    .onAppear { model?.refresh() }
            } else {
                HistoryExportScreen(
                    step: step, words: state.filterWords(dates: dateWords(state)), file: exportModel?.exportFile, actions: exportActions
                )
            }
        }
        .onAppear {
            if model == nil {
                model = HistoryViewModel(history: history, connections: connections, ownerChecks: ownerChecks, connectionID: connectionID)
            }
            if exportModel == nil { exportModel = HistoryExportViewModel(repo: export) }
        }
        .onDisappear { if exportModel?.step != .closed { exportModel?.close() } }
    }

    private func dateWords(_ s: HistoryState) -> String? {
        s.filter.since != nil || s.filter.until != nil ? HistoryFilterRow.dateLabel(s) : nil
    }

    private var actions: HistoryActions {
        var a = HistoryActions()
        guard let m = model else { return a }
        let host = host
        a.onOpen = { host.onOpenEntry($0) }
        a.onQuery = { m.setQuery($0) }
        a.onCategory = { m.setCategory($0) }
        a.onConnection = { m.setConnection($0) }
        a.onDates = { m.setDates($0, since: $1, until: $2) }
        a.onClearFilters = { m.clearFilters() }
        a.onLoadMore = { m.loadMore() }
        a.onRetry = { m.retry() }
        // ANDROID-PLAN §4 History "Export": exactly what the list shows (its category, connection, dates and search).
        if let e = exportModel { a.onExport = { e.start(m.state.exportContext) } }
        return a
    }

    private var exportActions: HistoryExportActions {
        var a = HistoryExportActions()
        guard let e = exportModel else { return a }
        let host = host
        a.onFormat = { e.chooseFormat($0) }
        a.onContinue = { e.confirm() }
        a.onSubmitPin = { e.submitPin($0) }
        a.onSave = { e.saveRequested() }
        // The list reads its newest entries again as it is shown again (`audit.exported` on top).
        a.onSaved = { e.saved($0) }
        a.onSaveFailed = { e.saveFailed() }
        a.onClose = { e.close() }
        a.onOpenAlarm = {
            e.close()
            host.onOpenAlarm()
        }
        a.onOwnerCheck = {
            e.close()
            host.onOwnerCheck()
        }
        return a
    }
}

/// One entry's screen with its view model.
public struct HistoryEntryRoute: View {
    private let seq: Int64
    private let history: any HistoryRepository
    private let connections: (any ConnectionsRepository)?
    private let host: HistoryHost
    @State private var model: HistoryEntryViewModel?

    public init(_ seq: Int64, history: any HistoryRepository, connections: (any ConnectionsRepository)? = nil, host: HistoryHost) {
        self.seq = seq
        self.history = history
        self.connections = connections
        self.host = host
    }

    public var body: some View {
        HistoryEntryScreen(state: model?.state ?? HistoryEntryState(), actions: actions)
            .onAppear {
                if model == nil { model = HistoryEntryViewModel(seq: seq, history: history, connections: connections) }
            }
    }

    private var actions: HistoryEntryActions {
        var a = HistoryEntryActions()
        a.onBack = host.onBack
        a.onOpenConnection = host.onOpenConnection
        a.onOpenItem = host.onOpenItem
        if let m = model { a.onRetry = { m.load() } }
        return a
    }
}
#endif
