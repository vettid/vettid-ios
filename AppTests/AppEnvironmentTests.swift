import Testing
import VettIDAltChan
import VettIDAttestation
@testable import VettID

struct AppEnvironmentTests {
    static var production: [String: Any] {
        [
            "VettIDEnvironment": "production", "VettIDAccountHost": "account.vettid.org", "VettIDRelayHost": "relay.vettid.org",
            "VettIDManifestHost": "vettid.org", "VettIDManifestKeys": "", "VettIDVotesHost": "votes.vettid.org",
        ]
    }

    @Test func debugBuildTalksToStaging() throws {
        // The tests run in the Debug configuration (`com.vettid.app.dev`).
        let env = AppEnvironment.current
        #expect(env.kind == .debug)
        #expect(env.accountHost == "account.staging.vettid.org")
        #expect(env.apiOrigin == "https://account.staging.vettid.org")
        #expect(env.relayURL == "https://relay.vettid.org")
        #expect(env.manifestURL == "https://staging.vettid.org/.well-known/vettid/pcr-manifest.json")
        #expect(env.votesURL == "https://votes.staging.vettid.org")
        // The staging channel's key A (key id e9b3a403423120ac), and only it.
        #expect(try env.trust().manifestKeys.map(\.keyID) == ["e9b3a403423120ac"])
    }

    @Test func refusesMissingOrUnknownValues() {
        #expect(AppEnvironment(infoDictionary: [:]) == nil)
        var unknown = Self.production
        unknown["VettIDEnvironment"] = "elsewhere"
        #expect(AppEnvironment(infoDictionary: unknown) == nil)
        for key in ["VettIDAccountHost", "VettIDRelayHost", "VettIDManifestHost"] {
            var empty = Self.production
            empty[key] = ""
            #expect(AppEnvironment(infoDictionary: empty) == nil, "\(key)")
        }
    }

    @Test func readsAKnownEnvironment() throws {
        let env = try #require(AppEnvironment(infoDictionary: Self.production))
        #expect(env.kind == .production)
        #expect(env.accountHost == "account.vettid.org")
        #expect(env.apiOrigin == "https://account.vettid.org" && env.relayURL == "https://relay.vettid.org")
        #expect(env.manifestURL == "https://vettid.org/.well-known/vettid/pcr-manifest.json")
        #expect(env.votesURL == "https://votes.vettid.org")
        // Release pins the production keys in code, whatever its Info.plist says.
        var planted = Self.production
        planted["VettIDManifestKeys"] = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEok8gqeC5VcGx4KL+B5fL7UgENBXf"
            + "+59RigkR0TZ0NqjiWM2VK6V1+paNoqRTBx7nXXN3L/2ehjsTb31GGVkEAw=="
        let pinned = try #require(AppEnvironment(infoDictionary: planted)).trust().manifestKeys.map(\.keyID)
        #expect(pinned == ManifestKeys.production.map(\.keyID))
    }

    /// The dev stack's member API is plain HTTP on the Mac; its relay URL is the one tokens name.
    @Test func theDevStackAddresses() throws {
        let env = try #require(AppEnvironment(infoDictionary: [
            "VettIDEnvironment": "devstack", "VettIDAccountHost": "127.0.0.1:18081", "VettIDRelayHost": "relay.vettid.test",
            "VettIDManifestHost": "127.0.0.1:18081",
        ]))
        #expect(env.apiOrigin == "http://127.0.0.1:18081" && env.relayURL == "https://relay.vettid.test")
        #expect(env.manifestKeys.isEmpty)
        // No votes site on the dev stack: nothing is fetched.
        #expect(env.votesHost == nil && env.votesURL == nil)
    }

    /// STAGING-TIME-SCALE §4 item 4: a Release build accepts only real time; Staging and Debug 1 and 24; DevStack its own.
    @Test func eachBuildAcceptsItsTimeScales() throws {
        let release = try #require(AppEnvironment(infoDictionary: Self.production))
        let releaseTrust = try release.trust()
        #expect(release.timeScales == .production && releaseTrust.timeScales == .production)
        #expect(!releaseTrust.timeScales.accepts(24))
        // The configuration these tests run in, whichever it is.
        let current = AppEnvironment.current
        let expected: TimeScalePolicy = switch current.kind {
        case .production: .production
        case .staging, .debug: .staging
        case .devstack: .development
        }
        let currentTrust = try current.trust()
        #expect(current.timeScales == expected && currentTrust.timeScales == expected)
        var staging = Self.production
        staging["VettIDEnvironment"] = "staging"
        #expect(try #require(AppEnvironment(infoDictionary: staging)).timeScales == .staging)
        var dev = Self.production
        dev["VettIDEnvironment"] = "devstack"
        #expect(try #require(AppEnvironment(infoDictionary: dev)).timeScales == .development)
    }
}
