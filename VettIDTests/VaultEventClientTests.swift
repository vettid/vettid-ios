import XCTest
@testable import VettID

/// Tests for VaultEventClient and related types
final class VaultEventClientTests: XCTestCase {

    // MARK: - VaultEventType Tests

    func testVaultEventType_sendMessage_hasCorrectType() {
        let event = VaultEventType.sendMessage(recipient: "user123", content: "Hello")
        XCTAssertEqual(event.type, "messaging.send")
    }

    func testVaultEventType_sendMessage_hasCorrectPayload() {
        let event = VaultEventType.sendMessage(recipient: "user123", content: "Hello World")
        let payload = event.payload

        XCTAssertEqual(payload["recipient"]?.value as? String, "user123")
        XCTAssertEqual(payload["content"]?.value as? String, "Hello World")
    }

    func testVaultEventType_updateProfile_hasCorrectType() {
        let event = VaultEventType.updateProfile(updates: ["name": "John"])
        XCTAssertEqual(event.type, "profile.update")
    }

    func testVaultEventType_createConnection_hasCorrectType() {
        let event = VaultEventType.createConnection(inviteCode: "ABC123")
        XCTAssertEqual(event.type, "connection.create")
    }

    func testVaultEventType_createConnection_hasCorrectPayload() {
        let event = VaultEventType.createConnection(inviteCode: "INVITE-XYZ")
        let payload = event.payload

        XCTAssertEqual(payload["invite_code"]?.value as? String, "INVITE-XYZ")
    }

    func testVaultEventType_retrieveSecret_hasCorrectType() {
        let event = VaultEventType.retrieveSecret(secretId: "secret-123")
        XCTAssertEqual(event.type, "secret.retrieve")
    }

    func testVaultEventType_storeSecret_hasCorrectType() {
        let event = VaultEventType.storeSecret(secretId: "secret-456", data: Data())
        XCTAssertEqual(event.type, "secret.store")
    }

    func testVaultEventType_storeSecret_encodesDataAsBase64() {
        let testData = "test secret data".data(using: .utf8)!
        let event = VaultEventType.storeSecret(secretId: "secret-789", data: testData)
        let payload = event.payload

        let encodedData = payload["data"]?.value as? String
        XCTAssertEqual(encodedData, testData.base64EncodedString())
    }

    func testVaultEventType_custom_hasCorrectType() {
        let event = VaultEventType.custom(type: "custom.event", payload: [:])
        XCTAssertEqual(event.type, "custom.event")
    }

    func testVaultEventType_custom_preservesPayload() {
        let customPayload: [String: AnyCodableValue] = [
            "key1": AnyCodableValue("value1"),
            "key2": AnyCodableValue(42)
        ]
        let event = VaultEventType.custom(type: "custom.event", payload: customPayload)
        let payload = event.payload

        XCTAssertEqual(payload["key1"]?.value as? String, "value1")
        XCTAssertEqual(payload["key2"]?.value as? Int, 42)
    }

    // MARK: - VaultEventMessage Tests

    func testVaultEventMessage_encoding() throws {
        let message = VaultEventMessage(
            id: "req-123",
            type: "test.event",
            payload: ["key": AnyCodableValue("value")],
            timestamp: "2025-12-07T12:00:00Z"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["id"] as? String, "req-123")
        XCTAssertEqual(json["type"] as? String, "test.event")
        XCTAssertEqual(json["timestamp"] as? String, "2025-12-07T12:00:00Z")
        XCTAssertNotNil(json["payload"])
    }

    // MARK: - VaultEventResponse Tests

    func testVaultEventResponse_decoding_success() throws {
        let json = """
        {
            "event_id": "req-456",
            "success": true,
            "timestamp": "2025-12-07T12:01:00Z",
            "result": {"data": "processed"},
            "error": null
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(VaultEventResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.responseId, "req-456")
        XCTAssertTrue(response.isSuccess)
        XCTAssertNotNil(response.result)
        XCTAssertNil(response.error)
    }

    func testVaultEventResponse_decoding_error() throws {
        let json = """
        {
            "event_id": "req-789",
            "success": false,
            "timestamp": "2025-12-07T12:02:00Z",
            "result": null,
            "error": "Handler execution failed"
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(VaultEventResponse.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(response.responseId, "req-789")
        XCTAssertFalse(response.isSuccess)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error, "Handler execution failed")
    }

    func testVaultEventResponse_decoding_withIdFallback() throws {
        let json = """
        {
            "id": "req-fallback",
            "success": true,
            "timestamp": "2025-12-07T12:03:00Z",
            "result": null,
            "error": null
        }
        """

        let decoder = JSONDecoder()
        let response = try decoder.decode(VaultEventResponse.self, from: json.data(using: .utf8)!)

        // Should fall back to id when event_id is not present
        XCTAssertEqual(response.responseId, "req-fallback")
        XCTAssertTrue(response.isSuccess)
    }

    // MARK: - AnyCodableValue Tests

    func testAnyCodableValue_encodesString() throws {
        let value = AnyCodableValue("test string")
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        let decoded = String(data: data, encoding: .utf8)!

        XCTAssertEqual(decoded, "\"test string\"")
    }

    func testAnyCodableValue_encodesInt() throws {
        let value = AnyCodableValue(42)
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        let decoded = String(data: data, encoding: .utf8)!

        XCTAssertEqual(decoded, "42")
    }

    func testAnyCodableValue_encodesBool() throws {
        let value = AnyCodableValue(true)
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        let decoded = String(data: data, encoding: .utf8)!

        XCTAssertEqual(decoded, "true")
    }

    func testAnyCodableValue_encodesDouble() throws {
        let value = AnyCodableValue(3.14)
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        let decoded = String(data: data, encoding: .utf8)!

        XCTAssertTrue(decoded.contains("3.14"))
    }

    func testAnyCodableValue_decodesString() throws {
        let json = "\"decoded string\""
        let decoder = JSONDecoder()
        let value = try decoder.decode(AnyCodableValue.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(value.value as? String, "decoded string")
    }

    func testAnyCodableValue_decodesInt() throws {
        let json = "123"
        let decoder = JSONDecoder()
        let value = try decoder.decode(AnyCodableValue.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(value.value as? Int, 123)
    }

    func testAnyCodableValue_decodesDict() throws {
        let json = """
        {"nested": "value", "number": 99}
        """
        let decoder = JSONDecoder()
        let value = try decoder.decode(AnyCodableValue.self, from: json.data(using: .utf8)!)

        let dict = value.value as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["nested"] as? String, "value")
        XCTAssertEqual(dict?["number"] as? Int, 99)
    }
}
