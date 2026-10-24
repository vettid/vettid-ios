import Foundation
import Testing
import VettIDAltChan
import VettIDData
import VettIDDataTesting
@testable import VettIDOnboarding

/// Recovery on a new phone (VAULT-MESSAGING §11.11, §11.11.10), as the flow drives it up to the open. Mirrors vettid-android
/// `RecoverViewModelTest` for release R (IOS-PLAN ID8: its tests of the earlier PIN and password steps are not here; the
/// open is ``RecoveryOpenViewModelTests``).
@MainActor
@Suite struct RecoverViewModelTests {
    let vault = FakeVaultRepository(.setup(.vaultElsewhere))
    let clock = VirtualTime()
    let vid = "0123456789abcdef0123456789abcdef"
    let rid = "01JA0RECVERY0000000000001X"
    let code = "SK01TG8WK2FYJ1Y5MEHJ5R5J7QZKWHX0"
    let api = "https://account.vettid.org"

    var qr: String { #"{"v":1,"t":"r","api":"\#(api)","vault_id":"\#(vid)","recovery_id":"\#(rid)","code":"\#(code)"}"# }

    // §16's vector (TEST ONLY): the 48 characters the production account site would show for this locator and code.
    let typedLocator = "7ZK3M9QX2HTD"
    let typedCode = "CDEFGHJKMNPQRSTVWXYZ0123456789AB"
    let typed = "7ZK3M9QX2HTD" + "CDEFGHJKMNPQRSTVWXYZ0123456789AB" + "V3A1"
    let typedGrouped = "7ZK3 M9QX 2HTD CDEF GHJK MNPQ RSTV WXYZ 0123 4567 89AB V3A1"

    func model() async -> RecoverViewModel {
        let vm = RecoverViewModel(move: vault, vault: vault, account: vault, tick: clock.tick)
        await vm.settle()
        return vm
    }

    func typing() async -> RecoverViewModel {
        let vm = await model()
        vm.type()
        #expect(vm.state.step == .type)
        return vm
    }

    func count(_ name: String) -> Int { vault.calls.filter { $0 == name }.count }

    @Test func scanThenRegisterThenTheOpen() async throws {
        let vm = await model()
        #expect(vm.state.step == .intro)
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vault.lastRegistered == RecoveryCode(vaultID: vid, recoveryID: rid, code: code, api: api))
        #expect(vm.state.emailHint == vault.emailHint && vault.phase == .setup(.recovering) && vm.state.step == .open)
        // The one screen for the PIN and the password takes over; the end of setup is the flow's `finish`.
        vault.phase = .setup(.finishing)
        vm.finish()
        await vm.settle()
        #expect(vault.phase == .unlocked)
    }

    @Test func aRegisteredPhoneResumesAtTheOpen() async throws {
        for stage in [RecoveryStage.pin, .password] {
            vault.recoveryStageValue = stage
            #expect(await model().state.step == .open)
        }
        #expect(vault.calls.contains("recoveryStage"))
    }

    @Test func scansThatAreNotThisAccountsRecoveryCodeAreRefusedLocally() async throws {
        let vm = await model()
        vm.scan()
        vm.scanned("https://example.org")
        #expect(vm.state.refusal == .notACode)
        // §11.11.2 (0.15.0): `api` must equal this build's member API origin exactly; it is never contacted.
        vm.scanned(qr.replacingOccurrences(of: api, with: "https://account.staging.vettid.org"))
        #expect(vm.state.refusal == .otherEnvironment && vm.state.otherApi == "https://account.staging.vettid.org")
        vm.scanned(qr.replacingOccurrences(of: "\"api\":\"\(api)\",", with: ""))
        #expect(vm.state.refusal == .noApi)
        #expect(!vault.calls.contains("registerRecovery"))
        // The origin's trailing slash is not a difference.
        vm.scanned(qr.replacingOccurrences(of: api, with: api + "/"))
        await vm.settle()
        #expect(vault.calls.contains("registerRecovery"))
    }

    @Test func wrongCodesAreCountedAndTheFifthVoidsTheRecovery() async throws {
        vault.registrations = Array(repeating: .refused(code: "bad_code"), count: 5)
        let vm = await model()
        vm.scan()
        for i in 1...4 {
            vm.scanned(qr)
            await vm.settle()
            #expect(vm.state.step == .scan && vm.state.refusal == .badCode && vm.state.wrongCodes == i)
        }
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.refusal == .voided)
    }

    @Test func enclaveRefusalsSayWhy() async throws {
        let vm = await model()
        vm.scan()
        let table: [(String, CodeRefusal)] = [
            ("expired", .expired), ("too_early", .tooEarly), ("no_recovery", .gone), ("used", .gone), ("attestation", .attestation),
            ("retry", .retry),
            // The API's 409 recovery_not_available at the claim or the register (the app cannot read the recovery).
            ("not_available", .notAvailable),
            // 0.34.0: a release with recovery_r and without recovery_offered (nothing sent, or the vault's not_offered).
            ("not_offered", .notOffered),
            // Anything else is a try again.
            ("something_new", .retry),
        ]
        for (c, r) in table {
            vault.registrations.append(.refused(code: c))
            vm.scanned(qr)
            await vm.settle()
            #expect(vm.state.refusal == r && vm.state.step == .scan, "\(c)")
        }
    }

    @Test func noBackupAtTheRegisterCannotBeRecovered() async throws {
        vault.registrations.append(.refused(code: "no_backup"))
        let vm = await model()
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.step == .noBackup && vm.state.refusal == nil && vault.calls.contains("abandonRecovery"))
        #expect(vm.state.startOverURL == "https://account.vettid.org/account/vault/deletion/")
    }

    /// A read of the stage that failed is not "no recovery": a registered recovery is not offered a new code.
    @Test func aStageThatCouldNotBeReadSaysSoAndOffersARetry() async throws {
        vault.fail["recoveryStage"] = VaultFailure(.network)
        vault.recoveryStageValue = .pin
        let vm = await model()
        #expect(vm.state.step == .stageFailed && vm.state.error == .network)
        vm.scan()
        vm.type()
        #expect(vm.state.step == .stageFailed)
        vm.retryStage()
        await vm.settle()
        #expect(vm.state.step == .open && vm.state.error == nil)
    }

    @Test func noRecoveryShowsWhatToDo() async throws {
        let vm = await model()
        #expect(vm.state.step == .intro && !vm.back())
        vm.scan()
        #expect(vm.back() && vm.state.step == .intro)
    }

    // MARK: - Leaving a registered recovery

    func atTheOpen() async -> RecoverViewModel {
        vault.recoveryStageValue = .pin
        vault.phase = .setup(.recovering)
        let vm = await model()
        #expect(vm.state.step == .open)
        return vm
    }

    @Test func startOverAsksFirstAndThenForgetsTheRecoveryOnThisPhone() async throws {
        let vm = await atTheOpen()
        vm.askStartOver()
        #expect(vm.state.confirmStartOver && !vault.calls.contains("abandonRecovery"))
        vm.dismissStartOver()
        #expect(!vm.state.confirmStartOver)
        vm.confirmStartOver() // not asked for: nothing
        await vm.settle()
        #expect(!vault.calls.contains("abandonRecovery"))
        vm.askStartOver()
        vm.confirmStartOver()
        await vm.settle()
        #expect(count("abandonRecovery") == 1)
        // Back at the start of the flow, with nothing of the old recovery: a new code can be scanned or typed.
        let s = vm.state
        #expect(s.step == .intro && s.emailHint.isEmpty && !s.busy && vault.phase == .signedOut)
        #expect(!vm.back())
        // The app has no call that cancels the recovery itself (VAULT-MESSAGING §11.11.4): none was made.
        #expect(vault.calls.filter { $0 != "recoveryStage" } == ["abandonRecovery"])
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.step == .open)
    }

    /// The data layer's refusals of a start over and a registration are kinds of guidance the screens can text.
    @Test func theRefusalsOfAnOpenThatWentOutAreGuidance() async throws {
        let vm = await atTheOpen()
        vault.fail["abandonRecovery"] = VaultFailure(.other, code: MoveCodes.recoveryOpened)
        vm.askStartOver()
        vm.confirmStartOver()
        await vm.settle()
        #expect(vm.state.guidance == .alreadyRecovered)
        vault.recoveryStageValue = .code
        let scanning = await model()
        vault.fail["registerRecovery"] = VaultFailure(.other, code: VaultManager.codeRecoveryOpenSent)
        scanning.scan()
        scanning.scanned(qr)
        await scanning.settle()
        #expect(scanning.state.guidance == .finishWithPin && scanning.state.step == .scan)
        #expect(RecoverState().guidance == nil)
        var s = RecoverState()
        for (code, g) in [
            (VaultManager.codeRecoveryOpenPending, RecoverGuidance.tryOpenAgain), (VaultManager.codeRecoveryOpenUnknown, .retry),
            (VaultManager.codeRecoveryRegistered, .startOverFirst),
        ] {
            s.errorCode = code
            #expect(s.guidance == g)
        }
    }

    /// Guidance on a code step leads to the open step; any other refusal does not.
    @Test func guidanceOnACodeStepLeadsToTheOpen() async throws {
        let plain = await model()
        plain.showOpen()
        #expect(plain.state.step == .intro)
        vault.fail["registerRecovery"] = VaultFailure(.other, code: VaultManager.codeRecoveryOpenSent)
        let vm = await model()
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.guidance == .finishWithPin && vm.state.step == .scan)
        vm.showOpen()
        #expect(vm.state.step == .open && vm.state.guidance == .finishWithPin && vm.state.refusal == nil)
    }

    @Test func startOverIsOfferedOnlyWhereARegistrationIsHeld() async throws {
        let fresh = await model()
        fresh.askStartOver() // the intro: nothing registered, nothing to forget
        #expect(!fresh.state.confirmStartOver)
    }

    @Test func aStartOverThatFailsSaysSoAndStaysWhereItWas() async throws {
        let vm = await atTheOpen()
        vault.fail["abandonRecovery"] = VaultFailure(.other, code: "keystore")
        vm.askStartOver()
        vm.confirmStartOver()
        await vm.settle()
        #expect(vm.state.step == .open && vm.state.error == .other && vm.state.errorCode == "keystore" && !vm.state.busy)
    }

    // MARK: - The code typed instead of scanned (VAULT-MESSAGING 0.25.0 §11.11.10; ANDROID-PLAN 0.1.33)

    @Test func typeThenRegisterThenTheOpen() async throws {
        let vm = await typing()
        #expect(vm.state.accountHost == "account.vettid.org" && vm.state.typedGroups == 0 && !vm.state.typedComplete)
        // As typed: lower case, with the site's spaces.
        vm.setTyped(typedGrouped.lowercased())
        #expect(vm.state.typed == typed && vm.state.typedGroups == 12 && vm.state.typedComplete && vm.state.typedProblem == nil)
        vm.submitTyped()
        #expect(vm.state.step == .registering)
        await vm.settle()
        let sent = try #require(vault.lastTyped)
        #expect(sent.locator == typedLocator && sent.code == typedCode)
        #expect(!vault.calls.contains("registerRecovery"), "the scanned register is not used")
        #expect(vm.state.emailHint == vault.emailHint && vm.state.step == .open)
        #expect(vm.state.typed.isEmpty, "the characters are gone once the code was accepted")
    }

    @Test func typedCharactersAreNormalizedAndRefusedOnesAreNamedWithTheirGroup() async throws {
        let vm = await typing()
        vm.setTyped("7zk3-m9")
        #expect(vm.state.typed == "7ZK3M9" && vm.state.typedGroups == 1)
        // I and L are read as 1, O as 0.
        vm.setTyped("7ZK3M9iLoO")
        #expect(vm.state.typed == "7ZK3M91100" && vm.state.typedProblem == nil)
        // A U is refused in the field: dropped, never guessed to be a V; the 11th character is in group 3.
        vm.setTyped("7ZK3M91100u")
        #expect(vm.state.typed == "7ZK3M91100" && vm.state.typedProblem == .letterU && vm.state.typedGroup == 3)
        // The next valid character clears the notice.
        vm.setTyped("7ZK3M91100V")
        #expect(vm.state.typedProblem == nil)
        vm.setTyped("7ZK3M91100V!")
        #expect(vm.state.typed == "7ZK3M91100V" && vm.state.typedProblem == .otherCharacter && vm.state.typedGroup == 3)
        // A forty-ninth character is ignored.
        vm.setTyped(typed + "Z")
        #expect(vm.state.typed == typed && vm.state.typedProblem == nil)
        #expect(count("registerTypedRecovery") == 0)
        #expect(!"\(vm.state)".contains("7ZK3") && !String(reflecting: vm.state).contains("7ZK3"))
    }

    @Test func aStringFailingTheCheckSendsNothingAndIsNotCounted() async throws {
        let vm = await typing()
        // One mistyped character.
        let mistyped = String(typed.prefix(4)) + "N" + String(typed.dropFirst(5))
        vm.setTyped(mistyped)
        #expect(vm.state.typedComplete)
        vm.submitTyped()
        await vm.settle()
        #expect(vm.state.step == .type && vm.state.typedProblem == .badCheck && vm.state.typed == mistyped)
        // A staging account site's code in this (production) app: the same refusal, on the phone.
        vm.setTyped(typedLocator + typedCode + "J5JH")
        #expect(vm.state.typedProblem == nil, "editing clears the notice")
        vm.submitTyped()
        await vm.settle()
        #expect(vm.state.typedProblem == .badCheck)
        // Nothing reached the repository (so neither the member API nor the vault), and no wrong code was counted.
        #expect(count("registerTypedRecovery") == 0 && count("registerRecovery") == 0 && vault.lastTyped == nil)
        #expect(vm.state.wrongCodes == 0 && vm.state.refusal == nil && vm.state.error == nil)
        // Corrected, it goes out.
        vm.setTyped(typed)
        vm.submitTyped()
        await vm.settle()
        #expect(count("registerTypedRecovery") == 1 && vm.state.step == .open)
    }

    @Test func wrongLengthsAreNotSent() async throws {
        let vm = await typing()
        vm.submitTyped()
        #expect(vm.state.typedProblem == .incomplete)
        vm.setTyped(String(typed.dropLast()))
        #expect(vm.state.typedProblem == nil && !vm.state.typedComplete)
        vm.submitTyped()
        #expect(vm.state.typedProblem == .incomplete)
        // The bare 32 characters of an account page from before MEMBER-API 2.4.0: said at the paste, and at Continue.
        vm.setTyped("")
        vm.setTyped(RecoveryCodes.grouped(typedCode))
        #expect(vm.state.typedProblem == .shortCode)
        vm.submitTyped()
        #expect(vm.state.typedProblem == .shortCode)
        // Typing through the 32nd character is not a paste.
        vm.setTyped(String(typed.prefix(31)))
        vm.setTyped(String(typed.prefix(32)))
        #expect(vm.state.typedProblem == nil)
        await vm.settle()
        #expect(count("registerTypedRecovery") == 0)
    }

    @Test func typedRefusalsShowTheScansTextsAndReturnToTheEntry() async throws {
        let vm = await typing()
        vm.setTyped(typed)
        let table: [(String, CodeRefusal)] = [
            // The claim's 404 (any miss) and 409.
            ("no_recovery", .gone), ("not_available", .notAvailable),
            // The vault's answers.
            ("too_early", .tooEarly), ("attestation", .attestation), ("retry", .retry),
        ]
        for (c, r) in table {
            vault.registrations.append(.refused(code: c))
            vm.submitTyped()
            await vm.settle()
            #expect(vm.state.refusal == r && vm.state.step == .type && vm.state.typed == typed && !vm.state.busy, "\(c)")
        }
        // The recovery has ended: the characters go.
        for (c, r) in [("expired", CodeRefusal.expired), ("used", .gone)] {
            vm.setTyped(typed)
            vault.registrations.append(.refused(code: c))
            vm.submitTyped()
            await vm.settle()
            #expect(vm.state.refusal == r && vm.state.step == .type && vm.state.typed.isEmpty, "\(c)")
        }
        vm.setTyped(typed)
        vault.registrations.append(.refused(code: "no_backup"))
        vm.submitTyped()
        await vm.settle()
        #expect(vm.state.step == .noBackup && vm.state.typed.isEmpty)
    }

    @Test func wrongTypedCodesAreCountedWithScannedOnesOfTheSameRecovery() async throws {
        vault.registrations = Array(repeating: .refused(code: "bad_code"), count: 5)
        // The claim by locator names the recovery the QR names.
        vault.typedRecoveryID = rid
        let vm = await typing()
        vm.setTyped(typed)
        for i in 1...2 {
            vm.submitTyped()
            await vm.settle()
            #expect(vm.state.step == .type && vm.state.refusal == .badCode && vm.state.wrongCodes == i && vm.state.typed == typed)
        }
        // The same recovery's QR, scanned: the count goes on.
        vm.scan()
        vm.scanned(qr)
        await vm.settle()
        #expect(vm.state.refusal == .badCode && vm.state.wrongCodes == 3)
        vm.type()
        #expect(vm.state.typed == typed, "the entry is still there after a look at the scanner")
        vm.submitTyped()
        await vm.settle()
        #expect(vm.state.wrongCodes == 4)
        vm.submitTyped()
        await vm.settle()
        #expect(vm.state.refusal == .voided && vm.state.typed.isEmpty)
    }

    @Test func aRateLimitedClaimSaysHowLongToWait() async throws {
        let vm = await typing()
        vm.setTyped(typed)
        vault.fail["registerTypedRecovery"] = VaultFailure(.rateLimited, code: "rate_limited", retryAfterSeconds: 754)
        vm.submitTyped()
        await vm.settle()
        await clock.advance(seconds: 2)
        await vm.settle()
        #expect(vm.state.step == .type && vm.state.error == .rateLimited && (752...754).contains(vm.state.retrySeconds))
        #expect(vm.state.typed == typed && vm.state.wrongCodes == 0)
        // The wait is for the text only: another try (another network) is possible at once, and clears it.
        vm.submitTyped()
        await vm.settle()
        #expect(vm.state.step == .open && vm.state.retrySeconds == 0)
    }

    @Test func otherFailuresOfTheTypedClaimAreShownAndTheEntryKept() async throws {
        let vm = await typing()
        vm.setTyped(typed)
        for kind in [FailureKind.network, .unauthorized, .vaultUnavailable, .servicePaused, .noResponse, .other, .rateLimited] {
            vault.fail["registerTypedRecovery"] = VaultFailure(kind)
            vm.submitTyped()
            await vm.settle()
            // A rate limit without a wait shows no countdown.
            #expect(vm.state.error == kind && vm.state.step == .type && vm.state.typed == typed && vm.state.retrySeconds == 0)
            #expect(vm.state.refusal == nil)
        }
    }

    @Test func typingAndScanningLeadToEachOtherAndBackLeavesToTheIntro() async throws {
        let vm = await model()
        vm.type()
        #expect(vm.state.step == .type)
        vm.scan()
        #expect(vm.state.step == .scan)
        // A QR read while the typed entry is shown is not acted on, and typing while the scanner is shown changes nothing.
        vm.setTyped(typed)
        #expect(vm.state.typed.isEmpty)
        vm.type()
        vm.scanned(qr)
        await vm.settle()
        #expect(!vault.calls.contains("registerRecovery"))
        #expect(vm.back() && vm.state.step == .intro)
        #expect(!vm.back())
    }

    @Test func theTypedVectorIsAcceptedByThisAppsOrigin() {
        // What the tests above rely on: the vector's check matches the production origin and no other.
        guard case .ok = TypedRecoveryCode.parse(typed, api: api) else {
            Issue.record("the vector is not accepted")
            return
        }
        #expect(TypedRecoveryCode.parse(typed, api: "https://account.staging.vettid.org") == .badCheck)
    }
}
