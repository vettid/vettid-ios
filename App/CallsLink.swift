import VettIDCalls
import VettIDCallsWebRTC

/// The calls are linked into the app in every configuration (Debug, Staging and Release); their wiring and screens come in a
/// later change. Until then this is the one reference from the app into the call logic and the media engine, so that the
/// linker keeps both and `scripts/release-check.sh` can see them in the archives.
enum CallsLink {
    /// The media suites the engine offers, and the call logic's diagnostics type: names only, nothing is started.
    @MainActor static func summary() -> String {
        // Names only: making a factory needs the call's audio session, which belongs to the wiring.
        "\(WebRtcMediaEngine.supportedSuites.count) media suites, \(WebRtcMediaEngineFactory.self), \(CallsDiagnostics.self)"
    }
}
