import Testing
@testable import VettID

struct AppEnvironmentTests {
    @Test func debugBuildTalksToStaging() {
        // The tests run in the Debug configuration (`com.vettid.app.dev`).
        #expect(AppEnvironment.current.kind == .debug)
        #expect(AppEnvironment.current.accountHost == "account.staging.vettid.org")
    }

    @Test func refusesMissingOrUnknownValues() {
        #expect(AppEnvironment(infoDictionary: [:]) == nil)
        #expect(AppEnvironment(infoDictionary: [
            "VettIDEnvironment": "elsewhere", "VettIDAccountHost": "example.org",
        ]) == nil)
        #expect(AppEnvironment(infoDictionary: [
            "VettIDEnvironment": "staging", "VettIDAccountHost": "",
        ]) == nil)
    }

    @Test func readsAKnownEnvironment() {
        let env = AppEnvironment(infoDictionary: [
            "VettIDEnvironment": "production", "VettIDAccountHost": "account.vettid.org",
        ])
        #expect(env?.kind == .production)
        #expect(env?.accountHost == "account.vettid.org")
    }
}
