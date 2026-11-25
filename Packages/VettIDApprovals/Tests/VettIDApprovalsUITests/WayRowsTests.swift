import Foundation
import Testing
import VettIDApprovals
@testable import VettIDApprovalsUI
@testable import VettIDData

// Texts and fixtures stay on one line each.
// swiftlint:disable line_length

/// ANDROID-PLAN 0.1.137 AA8: a run's and a proxy's approval screens, as rows. Mirrors vettid-android's `AgentWayScreenTest`
/// and `AgentWayTextsTest` (the overlay tests have no iOS counterpart: iOS has no overlays to refuse).
@Suite struct WayRowsTests {
    static let sha = String(repeating: "1a2b3c4d5e6f7a8b", count: 4)
    static let sha2 = String(repeating: "9f8e7d6c5b4a3928", count: 4)
    let bot = AccountNames.isolate("Build bot")

    func run(
        argv: [String] = ["/usr/bin/git", "push", "origin"], flags: Set<RunFlag> = [], program: String = "/usr/bin/git", how: SecretHow = .env,
        env: [ItemRun.EnvEntry] = [], previous: (String, String)? = nil, replaces: String? = nil, cwd: String? = nil
    ) -> HeldShow {
        .run(
            ItemRun(
                itemID: "i1", fieldID: "f1", program: program, sha256: Self.sha, argv: argv, cwd: cwd, how: how, name: "GH_TOKEN", env: env, flags: flags,
                previousSha256: previous?.0, previousPath: previous?.1, replaces: replaces
            ),
            item: "GitHub token", field: "Token"
        )
    }

    func proxy(seconds: Int = 900, prefix: String = "Bearer ", replaces: String? = nil) -> HeldShow {
        .proxy(
            ItemProxy(itemID: "i1", fieldID: "f1", host: "api.example.com", header: "Authorization", prefix: prefix, seconds: seconds, replaces: replaces),
            item: "GitHub token", field: "Token"
        )
    }

    func rows(_ h: HeldShow, expired: Bool = false) -> [WayRow] {
        WayRows.rows(h, who: bot, whoInline: bot, expired: expired)
    }

    func parts(_ rows: [WayRow]) -> [WayPart] { rows.flatMap(\.parts) }

    /// The text of the line tagged [tag], if the rows have one.
    func line(_ rows: [WayRow], _ tag: String) -> String? {
        for p in parts(rows) { if case .line(let t, let g, _, _, _) = p, g == tag { return t } }
        return nil
    }

    func box(_ rows: [WayRow], _ tag: String) -> String? {
        for p in parts(rows) { if case .box(let t, let g) = p, g == tag { return t } }
        return nil
    }

    func tags(_ rows: [WayRow]) -> [String] { rows.flatMap(\.tags) }

    func inline(_ s: String) -> String { ShownString.inline(s, empty: "(empty)") }

    func title(_ rows: [WayRow]) -> String? {
        for p in parts(rows) { if case .title(let t) = p { return t } }
        return nil
    }

    @Test func aRunShowsEverythingTheVaultHolds() {
        let r = rows(run(env: [.init(name: "GIT_DIR", value: "/tmp/x")], cwd: "/home/me/src"))
        #expect(title(r) == "\(bot) wants to run a program with \(AccountNames.isolate("GitHub token"))")
        #expect(line(r, "agent_way_summary") == "2 arguments, 1 variable, 35 bytes in all")
        #expect(line(r, "agent_way_field") == "Field: \(AccountNames.isolate("Token"))")
        #expect(WayRows.pinText(Self.sha, full: false) == "Fingerprint: 1a2b 3c4d 5e6f 7a8b")
        #expect(box(r, "agent_way_program") == "/usr/bin/git" && box(r, "agent_way_cwd") == "/home/me/src")
        #expect(line(r, "agent_way_how") == "variable \(inline("GH_TOKEN"))")
        #expect(line(r, "agent_way_env_name_0") == inline("GIT_DIR") && box(r, "agent_way_env_0") == "/tmp/x")
        #expect(box(r, "agent_way_arg_0") == "push" && box(r, "agent_way_arg_1") == "origin")
        #expect(line(r, "agent_way_no_env") == nil && line(r, "agent_way_new_folder") == nil)
    }

    @Test func theFingerprintShowsAll64DigitsOnATap() {
        #expect(WayRows.pinText(Self.sha, full: true) == "Fingerprint: " + Self.sha.chunked(4))
        #expect(tags(rows(run())).contains("agent_way_pin"))
    }

    @Test func eachFlagsWarningShowsAtTheTopAndAgainAtTheEnd() {
        let r = rows(run(flags: [.shell, .programUnrecorded]))
        #expect(line(r, "agent_way_warning_top_0") == "This program can run other programs or code given to it, so the command can do anything with your secret. Read every argument.")
        #expect(line(r, "agent_way_warning_top_1") == "First run of this program with this item. Fingerprint: 1a2b 3c4d 5e6f 7a8b. If you approve, later runs of this exact file may run without asking, as this item's settings allow.")
        #expect(line(r, "agent_way_warning_end_0") == line(r, "agent_way_warning_top_0") && line(r, "agent_way_warning_end_1") == line(r, "agent_way_warning_top_1"))
        #expect(r.first { $0.id == "title" } != nil && r.firstIndex { $0.id == "warn_top_0" }! > r.firstIndex { $0.id == "title" }!, "after the title")
        #expect(r.last?.id == "warn_end_2", "and at the end (the #636 line for git is the third)")
        let others = rows(run(flags: [.inlineCode, .unboundProgram]))
        #expect(line(others, "agent_way_warning_top_0") == "This runs code given on the command line. It can do anything with your secret.")
        #expect(line(others, "agent_way_warning_top_1") == "Any program could be asked for. Approve only a command you recognize.")
    }

    @Test func aChangedProgramShowsBothFingerprintsInFull() {
        let r = rows(run(flags: [.programChanged], previous: (Self.sha2, "/usr/bin/git")))
        #expect(line(r, "agent_way_warning_top_0") == "This program has changed since you approved it. Before: 9f8e 7d6c 5b4a 3928. Now: 1a2b 3c4d 5e6f 7a8b. If you did not update it, deny. If you approve, this file's fingerprint replaces the recorded one, and later runs of it may run without asking, as this item's settings allow.")
        #expect(line(r, "agent_way_before_pin") == Self.sha2.chunked(4) && line(r, "agent_way_now_pin") == Self.sha.chunked(4))
        #expect(box(r, "agent_way_before_path") == "/usr/bin/git" && box(r, "agent_way_now_path") == "/usr/bin/git")
        // The app never judges a change itself: the warning shows when the first 16 digits are equal too.
        let same = String(Self.sha.prefix(16)) + String(repeating: "0", count: 48)
        #expect(line(rows(run(flags: [.programChanged], previous: (same, "/usr/bin/git"))), "agent_way_warning_top_0") != nil)
    }

    @Test func aMovedProgramShowsBothPathsAndStressesWhereItMoved() {
        let r = rows(run(flags: [.programChanged], previous: (Self.sha2, "/opt/git")))
        let text = "This program moved to \(inline("/usr/bin/git")). It was approved at \(inline("/opt/git")). Before: 9f8e 7d6c 5b4a 3928. Now: 1a2b 3c4d 5e6f 7a8b. If you did not move or update it, deny. If you approve, this file's fingerprint replaces the recorded one, and later runs of it may run without asking, as this item's settings allow."
        #expect(line(r, "agent_way_warning_top_0") == text)
        guard case .line(_, _, true, _, let stress?)? = parts(r).first(where: { if case .line(_, "agent_way_warning_top_0", _, _, _) = $0 { true } else { false } }) else {
            Issue.record("no stressed part")
            return
        }
        #expect(stress == "moved to \(inline("/usr/bin/git"))" && text.contains(stress))
        #expect(box(r, "agent_way_before_path") == "/opt/git" && box(r, "agent_way_now_path") == "/usr/bin/git")
    }

    @Test func theBatchFileAndThe636LinesShow() {
        let batch = rows(run(argv: ["C:/tools/build.cmd"], program: "C:/tools/build.cmd"))
        #expect(line(batch, "agent_way_batch_file") == "This is a Windows batch file. Its fingerprint covers this file only, not the programs it starts (for an npm tool, node and its packages).")
        #expect(line(rows(run()), "agent_way_batch_file") == nil)
        // The #636 line is information, not a flag: git can run other commands; it shows at the top and at the end.
        let r = rows(run())
        #expect(line(r, "agent_way_warning_top_0") == "This program can run other commands given in its arguments. Read every argument.")
        #expect(line(r, "agent_way_warning_end_0") == line(r, "agent_way_warning_top_0"))
        #expect(line(rows(run(argv: ["/bin/true"], program: "/bin/true")), "agent_way_warning_top_0") == nil)
    }

    @Test func theSecretFileNoteNeedsTheExactArgumentAndAFileRun() {
        let file = rows(run(argv: ["/usr/bin/tool", "--key", "{secret_file}", "{secret_file} ", "{SECRET_FILE}"], program: "/usr/bin/tool", how: .file))
        #expect(line(file, "agent_way_secret_file_1") == "(the secret file's path)")
        #expect(line(file, "agent_way_secret_file_0") == nil && line(file, "agent_way_secret_file_2") == nil && line(file, "agent_way_secret_file_3") == nil)
        #expect(line(file, "agent_way_how") == "a temporary file, its path in variable \(inline("GH_TOKEN"))")
        let env = rows(run(argv: ["/usr/bin/tool", "{secret_file}"], program: "/usr/bin/tool", how: .env))
        #expect(line(env, "agent_way_secret_file_0") == nil, "only for a file run")
        #expect(line(rows(run(how: .stdin)), "agent_way_how") == "standard input")
    }

    @Test func askedForAsShowsOnlyWhenArgv0Differs() {
        #expect(box(rows(run(argv: ["git", "push"])), "agent_way_asked_as") == "git")
        #expect(line(rows(run(argv: ["git", "push"])), "agent_way_asked_as_label") == "Asked for as:")
        #expect(box(rows(run()), "agent_way_asked_as") == nil)
        // By bytes: a canonically equivalent spelling is another program.
        #expect(box(rows(run(argv: ["/usr/bin/cafe\u{0301}"], program: "/usr/bin/caf\u{00E9}")), "agent_way_asked_as") != nil)
    }

    @Test func noArgumentsAndNoVariablesSaySo() {
        let r = rows(run(argv: ["/usr/bin/git"]))
        #expect(line(r, "agent_way_no_arguments") == "No arguments" && line(r, "agent_way_no_env") == "None")
        #expect(line(r, "agent_way_new_folder") == "A new, empty folder of its own")
        #expect(line(r, "agent_way_summary") == "0 arguments, 0 variables, 12 bytes in all")
    }

    @Test func aLongRunKeepsEveryArgumentInFull() {
        let args = ["/usr/bin/git"] + (1...64).map { "arg-\($0)-" + String(repeating: "x", count: 500) }
        let r = rows(run(argv: args))
        for i in 0..<64 { #expect(box(r, "agent_way_arg_\(i)") == args[i + 1]) }
        #expect(line(r, "agent_way_summary")?.hasPrefix("64 arguments, 0 variables, 3") == true)
    }

    @Test func aProxyShowsItsNote() {
        let r = rows(proxy(seconds: 90))
        #expect(title(r) == "\(bot) wants to use \(AccountNames.isolate("GitHub token")) with \(inline("api.example.com")) for 1 minute 30 seconds.")
        #expect(line(r, "agent_way_proxy_body") == "The agent will not see it; the key is sent only to \(inline("api.example.com")).")
        #expect(line(r, "agent_way_ends_sooner") == "It may end sooner, when \(bot)'s access ends.")
        #expect(box(r, "agent_way_host") == "api.example.com")
        #expect(line(r, "agent_way_sent_as") == "Sent as: \(inline("Authorization")): \(ShownString.inline("Bearer ", empty: ""))••••••••")
        #expect(line(r, "agent_way_field") == "Field: \(AccountNames.isolate("Token"))")
    }

    @Test func theLengthIsInHoursMinutesAndSeconds() {
        #expect(WayRows.length(3_600) == "1 hour" && WayRows.length(900) == "15 minutes" && WayRows.length(90) == "1 minute 30 seconds")
        #expect(WayRows.length(60) == "1 minute" && WayRows.length(61) == "1 minute 1 second" && WayRows.length(7_200) == "2 hours")
        #expect(title(rows(proxy(seconds: 3_600)))?.hasSuffix("for 1 hour.") == true)
    }

    @Test func anEmptyPrefixShowsNoMarkers() {
        #expect(line(rows(proxy(prefix: "")), "agent_way_sent_as") == "Sent as: \(inline("Authorization")): ••••••••")
    }

    @Test func aReferralSaysItWasAskedAgain() {
        #expect(line(rows(run(replaces: "h0")), "agent_way_asked_again") == "Asked again. This item's settings or its recorded program changed while you were deciding. Check the details again.")
        #expect(line(rows(proxy(replaces: "h0")), "agent_way_asked_again") == "Asked again. This item's API settings changed while you were deciding. Check the details again.")
        #expect(line(rows(run()), "agent_way_asked_again") == nil)
        #expect(rows(run(replaces: "h0")).first?.id == "again", "before the title")
    }

    @Test func anExpiredRequestSaysSo() {
        #expect(line(rows(run(), expired: true), "agent_way_expired") == "This request expired, so nothing was done.")
        #expect(line(rows(run()), "agent_way_expired") == nil)
    }

    @Test func theOutcomesSayWhatHappened() {
        func say(_ o: DeviceOutcome) -> String { ApprovalTexts.outcome(o, who: "Bot") }
        func run(_ r: String?) -> String { say(.approved(result: r, way: .run)) }
        func proxy(_ r: String?) -> String { say(.approved(result: r, way: .proxy)) }
        #expect(run("ok") == "Approved." && say(.referred) == "Not done yet: something changed while you were deciding, so you are asked again.")
        #expect(run("not_found") == "Approved, but the item or its field is gone, so the program was not run.")
        #expect(proxy("not_found") == "Approved, but the item or its field is gone, so the key was not sent.")
        #expect(run("forbidden") == "Approved, but your vault refused it, so nothing was done. Bot may no longer have a permission that covers it, may be paused, or this request was asked again too many times.")
        #expect(run("program_not_allowed") == "Approved, but this item no longer allows that program, so nothing was done.")
        #expect(run("env_not_allowed") == "Approved, but this program may no longer receive those variables, so nothing was done.")
        #expect(run("cwd_not_allowed") == "Approved, but that folder or file is no longer allowed for this item, so nothing was done.")
        #expect(run("session_required") == "Approved, but Bot's access ended first, so nothing was done." && run("denied") == run("session_required"))
        #expect(run("way_not_allowed") == "Approved, but this item no longer allows that, so nothing was done.")
        #expect(run("x") == "Approved, but your vault answered: \(AccountNames.isolate("x")).")
        #expect(run(nil) == "Your vault didn't say whether it was done.")
        #expect(say(.approved(result: "forbidden")) == "Approved, but Bot no longer has a permission that covers it, or is paused, so nothing was done.", "AA5's text stays for the other ops")
    }

    @Test func theTextsAreThePlans() {
        let texts: [(String, String)] = [
            (ApprovalsStrings.runProgram, "Program"), (ApprovalsStrings.runAskedAs, "Asked for as:"), (ApprovalsStrings.runArguments, "Arguments"),
            (ApprovalsStrings.runNoArguments, "No arguments"), (ApprovalsStrings.runSecretFile, "(the secret file's path)"),
            (ApprovalsStrings.runRunsIn, "Runs in"), (ApprovalsStrings.runSecretGiven, "Secret given as"),
            (ApprovalsStrings.runHowStdin, "standard input"), (ApprovalsStrings.runOtherVariables, "Other variables"), (ApprovalsStrings.runNone, "None"),
            (ApprovalsStrings.runApprovedBefore, "Approved before"), (ApprovalsStrings.runNow, "Now"), (ApprovalsStrings.wayApproved, "Approved."),
            (ApprovalsStrings.runPinRecorded("X"), "This program's fingerprint is now recorded for X."),
            (ApprovalsStrings.wayScrollHint, "Scroll to the end to approve."), (ApprovalsStrings.wayKb("1.0"), "1.0 KB"), (ApprovalsStrings.wayMb("2"), "2 MB"),
            (ApprovalsStrings.wayBytes(1), "1 byte"), (ApprovalsStrings.wayBytes(2), "2 bytes"),
            (ApprovalsStrings.runArgumentsCount(1), "1 argument"), (ApprovalsStrings.runVariablesCount(1), "1 variable"),
            (ApprovalsStrings.waySeconds(1), "1 second"), (ApprovalsStrings.runSummary("a", "b", "c"), "a, b, c in all"),
            (ApprovalsStrings.runTitle("A", "B"), "A wants to run a program with B"), (ApprovalsStrings.proxyTitle("A", "B", "C", "D"), "A wants to use B with C for D."),
            (ApprovalsStrings.proxySentAs("H", "P"), "Sent as: H: P••••••••"), (ApprovalsStrings.proxyEndsSooner("A"), "It may end sooner, when A's access ends."),
        ]
        for (got, want) in texts { #expect(got == want) }
    }
}

extension String {
    /// In groups of four, a space between.
    func chunked(_ n: Int) -> String {
        stride(from: 0, to: count, by: n).map { String(self[index(startIndex, offsetBy: $0)..<index(startIndex, offsetBy: min($0 + n, count))]) }.joined(separator: " ")
    }
}

// swiftlint:enable line_length
