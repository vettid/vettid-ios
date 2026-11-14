import Foundation
import Testing
import VettIDCalls
import VettIDCrypto
@preconcurrency import WebRTC
@testable import VettIDCallsWebRTC

/// Mirrors `MediaGuardsTest` (statistics, faults and configuration) of vettid-android.
struct MediaStatisticsTests {
    private func entry(_ id: String, _ type: String, _ members: [String: StatValue]) -> StatEntry {
        StatEntry(id: id, type: type, members: members)
    }

    private var report: [StatEntry] {
        [
            entry("T1", "transport", ["selectedCandidatePairId": .text("P1"), "dtlsState": .text("connected"), "bytesSent": .number(10)]),
            entry("P1", "candidate-pair", [
                "localCandidateId": .text("L1"), "remoteCandidateId": .text("R1"), "state": .text("succeeded"),
                "currentRoundTripTime": .number(0.009),
            ]),
            entry("L1", "local-candidate", [
                "candidateType": .text("host"), "protocol": .text("udp"), "networkType": .text("wifi"), "address": .text("192.0.2.1"),
            ]),
            entry("R1", "remote-candidate", ["candidateType": .text("relay"), "protocol": .text("udp"), "address": .text("192.0.2.2")]),
            entry("I1", "inbound-rtp", [
                "kind": .text("audio"), "audioLevel": .number(0.25), "packetsReceived": .number(50), "codecId": .text("C1"),
            ]),
            entry("O1", "outbound-rtp", ["kind": .text("audio"), "packetsSent": .number(60), "codecId": .text("C1")]),
            entry("S1", "media-source", ["kind": .text("audio"), "audioLevel": .number(0.5)]),
            entry("C1", "codec", ["mimeType": .text("audio/opus")]),
        ]
    }

    @Test func diagnosticsFromAStatisticsReport() {
        let reading = MediaStatistics.diagnostics(from: report)
        #expect(reading.micLevel == 0.5)
        #expect(reading.remoteLevel == 0.25)
        #expect(reading.packetsSent == 60)
        #expect(reading.packetsReceived == 50)
        #expect(reading.inboundAudioStreams == 1)
        #expect(reading.sendCodec == "audio/opus")
        #expect(reading.receiveCodec == "audio/opus")
        #expect(reading.local == CandidateInfo(type: "host", protocol: "udp", network: "wifi"))
        #expect(reading.relayed == true)
        let rtt = reading.roundTripMs ?? -1
        #expect(abs(rtt - 9) < 1e-9)
        #expect(!String(describing: reading).contains("192.0.2"))
    }

    /// A second inbound audio stream is RTP on an SSRC nobody announced.
    @Test func aSecondInboundAudioStreamIsCounted() {
        let second = entry("I2", "inbound-rtp", ["kind": .text("audio"), "packetsReceived": .number(3)])
        #expect(MediaStatistics.diagnostics(from: report + [second]).inboundAudioStreams == 2)
    }

    @Test func noPathIsNeitherRelayedNorDirect() {
        #expect(MediaStatistics.diagnostics(from: []).relayed == nil)
        let direct = report.map { $0.id == "R1" ? entry("R1", "remote-candidate", ["candidateType": .text("host")]) : $0 }
        #expect(MediaStatistics.diagnostics(from: direct).relayed == false)
    }

    @Test func theSsrcFaultOnlyRenumbers() {
        #expect(
            MediaFaultSdp.misstateSsrc("v=0\r\na=ssrc:1234 cname:x\r\na=ssrc:1234 msid:a b\r\na=mid:0\r\n")
                == "v=0\r\na=ssrc:1235 cname:x\r\na=ssrc:1235 msid:a b\r\na=mid:0\r\n"
        )
        #expect(MediaFaultSdp.misstateSsrc("a=ssrc:4294967295 cname:x\r\n") == "a=ssrc:0 cname:x\r\n")
        #expect(!MediaConfig().faults.any)
        #expect(MediaFaults(keepRemoteSsrc: true).any && MediaFaults(sendUnencrypted: true).any)
    }

    @Test func theConfigurationIsTheOneTheCallRulesFix() {
        let servers = [
            CallWire.IceServer(urls: ["turn:turn.example.org:3478?transport=udp"], username: "u", credential: "c"),
            CallWire.IceServer(urls: ["stun:stun.example.org:3478"]),
        ]
        let config = WebRtcMediaCore.configuration(servers: servers, relayOnly: false)
        #expect(config.sdpSemantics == .unifiedPlan)
        #expect(config.bundlePolicy == .maxBundle)
        #expect(config.rtcpMuxPolicy == .require)
        #expect(config.continualGatheringPolicy == .gatherContinually)
        #expect(config.tcpCandidatePolicy == .disabled)
        #expect(config.shouldPruneTurnPorts)
        #expect(config.iceTransportPolicy == .all)
        // Only the servers the vault signed.
        #expect(config.iceServers.map(\.urlStrings) == servers.map(\.urls))
        #expect(WebRtcMediaCore.configuration(servers: [], relayOnly: false).iceServers.isEmpty)
        #expect(WebRtcMediaCore.configuration(servers: servers, relayOnly: true).iceTransportPolicy == .relay)
    }
}
