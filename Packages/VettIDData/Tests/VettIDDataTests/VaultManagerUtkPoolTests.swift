import Foundation
import Testing
@testable import VettIDData
import VettIDDataTesting

/// The phone's UTK pool against ``FakeVaultService`` (VAULT-MESSAGING 0.52.0 §3.5.4; IOS-PLAN 0.1.16 §4.5): a UTK is
/// spent when its request is sent, a refusal included (`forbidden` to a phone that is no longer the holder); a pool the
/// vault holds full of UTKs the phone no longer has is resynced once, at most once per 10 minutes.
@MainActor
@Suite(.serialized) struct VaultManagerUtkPoolTests {
    let service: FakeVaultService
    let phone: TestVaultPhone
    let pin = "402817"
    let password = "correct horse battery"

    init() throws {
        service = try FakeVaultService()
        // A staging vault at 24: the resync's 10 minutes are 25 s (VAULT-MESSAGING 0.52.0 §3.5.4), within the skew the
        // fake vault accepts between the phone's clock and its own.
        service.timeScales = .staging
        service.timeScale = 24
        phone = try TestVaultPhone(service: service)
    }

    var m: VaultManager { phone.manager }
    var utks: Int? { m.session?.device.utkCount }

    func setUp() async throws {
        _ = try await m.redeemSetupCode(.secret(service.secret))
        try await m.enroll(pin: pin) { _ in }
        try await m.createCredential(password: password, backup: true, pin: pin) { _ in }
        try await m.finishSetup()
        #expect(m.phase == .unlocked)
    }

    /// The check refused `forbidden`.
    func forbiddenCheck() async throws {
        let outcome = try await m.ownerChecks.check(pin: pin, password: password)
        guard case .failed(_, code: "forbidden") = outcome else {
            Issue.record("not refused forbidden: \(outcome)")
            return
        }
    }

    @Test func refusalsSpendTheirUTKsAndAnEmptyPoolResyncs() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try #require(utks)
        let vaultsBefore = service.outstandingUTKs
        #expect(before > 0)
        service.notHolder = true
        service.vaultPoolFull = true
        for i in 1...before {
            try await forbiddenCheck()
            #expect(utks == before - i, "the UTK spent by the refusal")
            #expect(service.outstandingUTKs == vaultsBefore - i)
        }
        #expect(service.utkResyncs.isEmpty)
        // The pool empty and the top-up empty: one resync, its 20 UTKs kept (one spent by the check).
        try await forbiddenCheck()
        #expect(service.utkResyncs == [true])
        #expect(utks == 19)
        #expect(service.ownerChecks.isEmpty)
    }

    @Test func aSecondResyncWithinItsPeriodIsTooSoon() async throws {
        defer { phone.close() }
        // The phone reads the vault's clock from its answers (the 10 minutes and `allowed_after` are on it).
        service.stampsOnVaultClock = true
        try await setUp()
        service.notHolder = true
        service.vaultPoolFull = true
        let before = try #require(utks)
        for _ in 0..<before { try await forbiddenCheck() }
        try await forbiddenCheck()
        #expect(service.utkResyncs == [true])
        for _ in 0..<19 { try await forbiddenCheck() }
        #expect(utks == 0)
        // Within 25 s: refused `too_soon`, shown with its code, and not sent again before `allowed_after`.
        service.vaultPoolFull = true
        var outcome = try await m.ownerChecks.check(pin: pin, password: password)
        #expect(outcome == .failed(.vaultCode("too_soon"), code: "too_soon"), "\(outcome)")
        #expect(service.utkResyncs == [true, false])
        outcome = try await m.ownerChecks.check(pin: pin, password: password)
        #expect(outcome == .failed(.vaultCode("too_soon"), code: "too_soon"), "\(outcome)")
        #expect(service.utkResyncs == [true, false], "no resync before allowed_after")
        // 5 s later, still none; 26 s later, resynced.
        service.advanceVaultClock(5)
        outcome = try await m.ownerChecks.check(pin: pin, password: password)
        #expect(outcome == .failed(.vaultCode("too_soon"), code: "too_soon"), "\(outcome)")
        #expect(service.utkResyncs == [true, false])
        service.advanceVaultClock(21)
        try await forbiddenCheck()
        #expect(service.utkResyncs == [true, false, true])
        #expect(utks == 19)
    }

    @Test func aWrongPinSpendsItsUTK() async throws {
        defer { phone.close() }
        try await setUp()
        let before = try #require(utks)
        #expect(try await m.ownerChecks.check(pin: "111111", password: password) == .badPin(checksLeft: 9))
        #expect(utks == before - 1)
    }
}
