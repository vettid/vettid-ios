import Foundation
import VettIDApprovals
import VettIDData

/// A piece of a row of a run's or a proxy's approval screen (ANDROID-PLAN 0.1.137 AA8): what the screen draws, with the tag a test
/// finds it by (Android's `testTag`; here the accessibility identifier).
enum WayPart: Equatable {
    case title(String)
    case heading(String)
    /// A line of text; [stress] is the part of it shown in bold ("moved to <path>"); a warning is in the warning style.
    case line(String, tag: String, warning: Bool = false, mono: Bool = false, stress: String? = nil)
    /// A string by the string rule, in its own box.
    case box(String, tag: String)
    /// A program's fingerprint: its first 16 digits, all 64 on a tap.
    case pin(String, tag: String)
    /// An argument's number.
    case number(Int)
}

/// One row, with a stable id: a part that follows another under it moves with it.
struct WayRow: Equatable, Identifiable {
    var id: String
    var parts: [WayPart]

    /// Every tag the row draws.
    var tags: [String] {
        parts.compactMap {
            switch $0 {
            case .line(_, let tag, _, _, _), .box(_, let tag), .pin(_, let tag): tag
            default: nil
            }
        }
    }
}

/// The rows of a run or a proxy, in the plan's order (AA8 "A run", "A proxy"), each a pure function of the held request, so that
/// the tests read them as Android's compose tests read the screen. Mirrors vettid-android `AgentWayScreen`'s `runRows`/`proxyRows`.
enum WayRows {
    /// "A `{secret_file}`", the argument a `file` run puts the secret file's path in.
    static let secretFile = "{secret_file}"

    /// [who] starts a sentence and [whoInline] is inside one (both isolated); [expired]: the request ended while open.
    static func rows(_ show: HeldShow, who: String, whoInline: String, expired: Bool) -> [WayRow] {
        var rows: [WayRow] = []
        if expired {
            rows.append(WayRow(id: "expired", parts: [.line(ApprovalsStrings.wayExpired, tag: "agent_way_expired", warning: true)]))
        }
        switch show {
        case .run(let r, let item, let field): rows += run(r, item: item, field: field, who: who)
        case .proxy(let p, let item, let field): rows += proxy(p, item: item, field: field, who: who, whoInline: whoInline)
        default: break
        }
        return rows
    }

    /// A program's fingerprint line: the first 16 digits in groups of four, all 64 once [full] (a tap).
    static func pinText(_ sha256: String, full: Bool) -> String {
        ApprovalsStrings.runFingerprint(full ? Fingerprints.full(sha256) : Fingerprints.short(sha256))
    }

    private static func inline(_ s: String) -> String { ShownString.inline(s, empty: ApprovalsStrings.stringEmpty) }

    private static func sameBytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    // MARK: A run

    // swiftlint:disable:next cyclomatic_complexity
    private static func run(_ r: ItemRun, item: String, field: String, who: String) -> [WayRow] {
        let warnings = runWarnings(r)
        var rows: [WayRow] = []
        func add(_ id: String, _ parts: WayPart...) { rows.append(WayRow(id: id, parts: parts)) }
        if r.replaces != nil { add("again", .line(ApprovalsStrings.runAskedAgain, tag: "agent_way_asked_again", warning: true)) }
        add("title", .title(ApprovalsStrings.runTitle(who, AccountNames.isolate(item))))
        for (i, w) in warnings.enumerated() { add("warn_top_\(i)", warning(w, "agent_way_warning_top_\(i)")) }
        add("summary", .line(summary(r), tag: "agent_way_summary"))
        add("field", .line(ApprovalsStrings.wayField(AccountNames.isolate(field)), tag: "agent_way_field"))
        var program: [WayPart] = [
            .heading(ApprovalsStrings.runProgram), .box(r.program, tag: "agent_way_program"), .pin(r.sha256, tag: "agent_way_pin"),
        ]
        if ProgramAdvice.batchFile(r.program) {
            program.append(.line(ApprovalsStrings.runBatchFile, tag: "agent_way_batch_file"))
        }
        rows.append(WayRow(id: "program", parts: program))
        if let first = r.argv.first, !sameBytes(first, r.program) {
            add("asked_as", .line(ApprovalsStrings.runAskedAs, tag: "agent_way_asked_as_label"), .box(first, tag: "agent_way_asked_as"))
        }
        add("args", .heading(ApprovalsStrings.runArguments))
        let args = Array(r.argv.dropFirst())
        if args.isEmpty { add("no_args", .line(ApprovalsStrings.runNoArguments, tag: "agent_way_no_arguments")) }
        for (i, arg) in args.enumerated() {
            var parts: [WayPart] = [.number(i + 1), .box(arg, tag: "agent_way_arg_\(i)")]
            // Only when the secret is handed in a file, and only for exactly `{secret_file}`.
            if r.how == .file, sameBytes(arg, secretFile) {
                parts.append(.line(ApprovalsStrings.runSecretFile, tag: "agent_way_secret_file_\(i)"))
            }
            rows.append(WayRow(id: "arg_\(i)", parts: parts))
        }
        add("cwd", .heading(ApprovalsStrings.runRunsIn),
            r.cwd.map { .box($0, tag: "agent_way_cwd") } ?? .line(ApprovalsStrings.runNewFolder, tag: "agent_way_new_folder"))
        add("how", .heading(ApprovalsStrings.runSecretGiven), .line(how(r), tag: "agent_way_how"))
        add("env", .heading(ApprovalsStrings.runOtherVariables))
        if r.env.isEmpty { add("no_env", .line(ApprovalsStrings.runNone, tag: "agent_way_no_env")) }
        for (i, e) in r.env.enumerated() {
            add("env_\(i)", .line(inline(e.name), tag: "agent_way_env_name_\(i)"), .box(e.value, tag: "agent_way_env_\(i)"))
        }
        if r.flags.contains(.programChanged), let before = r.previousSha256, let path = r.previousPath {
            add("before", .heading(ApprovalsStrings.runApprovedBefore), .box(path, tag: "agent_way_before_path"),
                .line(Fingerprints.full(before), tag: "agent_way_before_pin", mono: true))
            add("now", .heading(ApprovalsStrings.runNow), .box(r.program, tag: "agent_way_now_path"),
                .line(Fingerprints.full(r.sha256), tag: "agent_way_now_pin", mono: true))
        }
        for (i, w) in warnings.enumerated() { add("warn_end_\(i)", warning(w, "agent_way_warning_end_\(i)")) }
        return rows
    }

    /// A warning's text and the part of it that is stressed ("moved to <path>"), if any.
    struct Warning: Equatable {
        var text: String
        var stress: String?
    }

    private static func warning(_ w: Warning, _ tag: String) -> WayPart { .line(w.text, tag: tag, warning: true, stress: w.stress) }

    /// One line per flag, each with its full warning, then the #636 line when it applies (AA8 "A run").
    static func runWarnings(_ r: ItemRun) -> [Warning] {
        var out: [Warning] = []
        let fp = Fingerprints.short(r.sha256)
        if r.flags.contains(.shell) { out.append(Warning(text: ApprovalsStrings.runWarnShell)) }
        if r.flags.contains(.inlineCode) { out.append(Warning(text: ApprovalsStrings.runWarnInlineCode)) }
        if r.flags.contains(.unboundProgram) { out.append(Warning(text: ApprovalsStrings.runWarnUnbound)) }
        if r.flags.contains(.programUnrecorded) { out.append(Warning(text: ApprovalsStrings.runWarnUnrecorded(fp))) }
        if r.flags.contains(.programChanged) {
            let before = Fingerprints.short(r.previousSha256 ?? "")
            if let previous = r.previousPath, sameBytes(previous, r.program) {
                out.append(Warning(text: ApprovalsStrings.runWarnChanged(before, fp)))
            } else {
                let path = inline(r.program)
                let was = inline(r.previousPath ?? "")
                out.append(Warning(text: ApprovalsStrings.runWarnMoved(path, was, before, fp), stress: ApprovalsStrings.runMovedTo(path)))
            }
        }
        if ProgramAdvice.runsCommands(r.program) { out.append(Warning(text: ApprovalsStrings.runRunsCommands)) }
        return out
    }

    /// "<N> arguments, <M> variables, <size> in all" (`argv` after the first; the bytes of all of `argv` and `env`).
    static func summary(_ r: ItemRun) -> String {
        ApprovalsStrings.runSummary(
            ApprovalsStrings.runArgumentsCount(r.argv.count - 1), ApprovalsStrings.runVariablesCount(r.env.count),
            sizeText(WaySizes.runBytes(r))
        )
    }

    static func sizeText(_ bytes: Int) -> String {
        switch WaySizes.unit(bytes) {
        case .bytes(let n): ApprovalsStrings.wayBytes(n)
        case .kb(let t): ApprovalsStrings.wayKb(t)
        case .mb(let t): ApprovalsStrings.wayMb(t)
        }
    }

    private static func how(_ r: ItemRun) -> String {
        let name = inline(r.name ?? "")
        return switch r.how {
        case .env: ApprovalsStrings.runHowEnv(name)
        case .stdin: ApprovalsStrings.runHowStdin
        case .file: ApprovalsStrings.runHowFile(name)
        }
    }

    // MARK: A proxy

    private static func proxy(_ p: ItemProxy, item: String, field: String, who: String, whoInline: String) -> [WayRow] {
        let host = inline(p.host)
        var rows: [WayRow] = []
        func add(_ id: String, _ parts: WayPart...) { rows.append(WayRow(id: id, parts: parts)) }
        if p.replaces != nil { add("again", .line(ApprovalsStrings.proxyAskedAgain, tag: "agent_way_asked_again", warning: true)) }
        add("title", .title(ApprovalsStrings.proxyTitle(who, AccountNames.isolate(item), host, length(p.seconds))))
        add("body", .line(ApprovalsStrings.proxyBody(host), tag: "agent_way_proxy_body"),
            .line(ApprovalsStrings.proxyEndsSooner(whoInline), tag: "agent_way_ends_sooner"))
        add("host", .box(p.host, tag: "agent_way_host"))
        add("field", .line(ApprovalsStrings.wayField(AccountNames.isolate(field)), tag: "agent_way_field"))
        // "Sent as: <header>: <prefix>••••••••": the prefix by the string rule, a trailing space marked, none for an empty one.
        let prefix = p.prefix.isEmpty ? "" : ShownString.inline(p.prefix, empty: "")
        add("sent_as", .line(ApprovalsStrings.proxySentAs(inline(p.header), prefix), tag: "agent_way_sent_as"))
        return rows
    }

    /// A proxy's length (AA8): hours, minutes and seconds, as many as it has ("15 minutes", "1 minute 30 seconds", "1 hour").
    static func length(_ seconds: Int) -> String {
        let h = seconds / 3_600
        let m = seconds % 3_600 / 60
        let s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append(ApprovalsStrings.durationHours(h)) }
        if m > 0 { parts.append(ApprovalsStrings.durationMinutes(m)) }
        if s > 0 || parts.isEmpty { parts.append(ApprovalsStrings.waySeconds(s)) }
        return parts.joined(separator: " ")
    }
}
