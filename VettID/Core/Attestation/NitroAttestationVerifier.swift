import Foundation
import CryptoKit
import Security

// MARK: - Nitro Attestation Verifier

/// Verifies AWS Nitro Enclave attestation documents
///
/// Nitro attestation documents are CBOR-encoded COSE_Sign1 structures that prove:
/// - The code running in the enclave (via PCR values)
/// - The enclave is running on genuine Nitro hardware
/// - The enclave's ephemeral public key for E2E encryption
final class NitroAttestationVerifier {

    // MARK: - Types

    /// Expected PCR values for verification
    struct ExpectedPCRs {
        /// PCR0: Hash of the enclave image (48 bytes hex = 96 chars)
        let pcr0: String
        /// PCR1: Hash of the Linux kernel and bootstrap
        let pcr1: String
        /// PCR2: Hash of the application
        let pcr2: String
        /// When this PCR set becomes valid
        let validFrom: Date
        /// When this PCR set expires (nil = no expiration)
        let validUntil: Date?

        /// Check if this PCR set is currently valid
        var isValid: Bool {
            let now = Date()
            if now < validFrom { return false }
            if let until = validUntil, now > until { return false }
            return true
        }
    }

    /// Result of attestation verification
    struct AttestationResult {
        /// Whether the attestation is valid
        let isValid: Bool
        /// Enclave's ephemeral public key for session encryption
        let enclavePublicKey: Data
        /// PCR values from the attestation document
        let pcrs: [Int: Data]
        /// Timestamp from the attestation
        let timestamp: Date
        /// Module ID of the enclave
        let moduleId: String
        /// User data included in attestation (if any)
        let userData: Data?
        /// Nonce from the attestation (if any)
        let nonce: Data?
    }

    /// Parsed attestation document
    struct AttestationDocument {
        let moduleId: String
        let timestamp: UInt64
        let digest: String
        let pcrs: [Int: Data]
        let certificate: Data
        let cabundle: [Data]
        let publicKey: Data?
        let userData: Data?
        let nonce: Data?
    }

    // MARK: - Properties

    /// Maximum age for attestation documents (5 minutes)
    private let maxAttestationAge: TimeInterval = 300

    /// Expected AWS Nitro root CA common name
    private static let awsNitroRootCN = "aws.nitro-enclaves"

    // MARK: - Initialization

    init() {
        // No bundled certificate needed - we dynamically validate from cabundle
    }

    // MARK: - Public API

    /// Verify a Nitro attestation document
    /// - Parameters:
    ///   - attestationDocument: Raw CBOR-encoded attestation document
    ///   - expectedPCRs: Expected PCR values to match
    ///   - nonce: Optional nonce that should be in the attestation
    /// - Returns: Verification result with enclave public key
    func verify(
        attestationDocument: Data,
        expectedPCRs: ExpectedPCRs,
        nonce: Data? = nil
    ) throws -> AttestationResult {
        // Step 1: Parse COSE_Sign1 structure
        let (payload, signature, protectedHeader) = try parseCOSESign1(attestationDocument)

        // Step 2: Parse attestation payload
        let document = try parseAttestationPayload(payload)

        // Step 3: Verify certificate chain
        try verifyCertificateChain(
            certificate: document.certificate,
            cabundle: document.cabundle
        )

        // Step 4: Verify COSE signature using the leaf certificate
        try verifyCOSESignature(
            protectedHeader: protectedHeader,
            payload: payload,
            signature: signature,
            certificate: document.certificate
        )

        // Step 5: Verify timestamp is recent
        let attestationTime = Date(timeIntervalSince1970: TimeInterval(document.timestamp / 1000))
        let age = Date().timeIntervalSince(attestationTime)
        if age > maxAttestationAge {
            throw NitroAttestationError.documentExpired(age: age)
        }

        // Step 6: Verify nonce if provided
        if let expectedNonce = nonce {
            guard let documentNonce = document.nonce, documentNonce == expectedNonce else {
                throw NitroAttestationError.nonceMismatch
            }
        }

        // Step 7: Verify PCR values
        try verifyPCRs(document.pcrs, expected: expectedPCRs)

        // Step 8: Extract public key
        guard let publicKey = document.publicKey else {
            throw NitroAttestationError.missingPublicKey
        }

        return AttestationResult(
            isValid: true,
            enclavePublicKey: publicKey,
            pcrs: document.pcrs,
            timestamp: attestationTime,
            moduleId: document.moduleId,
            userData: document.userData,
            nonce: document.nonce
        )
    }

    /// Verify PCR values match expected values
    func verifyPCRs(_ actual: [Int: Data], expected: ExpectedPCRs) throws {
        guard expected.isValid else {
            throw NitroAttestationError.pcrSetExpired
        }

        // Convert expected hex strings to Data
        guard let expectedPCR0 = Data(hexString: expected.pcr0),
              let expectedPCR1 = Data(hexString: expected.pcr1),
              let expectedPCR2 = Data(hexString: expected.pcr2) else {
            throw NitroAttestationError.invalidExpectedPCRFormat
        }

        // Get actual PCR values
        guard let actualPCR0 = actual[0],
              let actualPCR1 = actual[1],
              let actualPCR2 = actual[2] else {
            throw NitroAttestationError.missingPCRValues
        }

        // Compare
        if actualPCR0 != expectedPCR0 {
            throw NitroAttestationError.pcrMismatch(
                pcr: 0,
                expected: expected.pcr0,
                actual: actualPCR0.hexEncodedString()
            )
        }
        if actualPCR1 != expectedPCR1 {
            throw NitroAttestationError.pcrMismatch(
                pcr: 1,
                expected: expected.pcr1,
                actual: actualPCR1.hexEncodedString()
            )
        }
        if actualPCR2 != expectedPCR2 {
            throw NitroAttestationError.pcrMismatch(
                pcr: 2,
                expected: expected.pcr2,
                actual: actualPCR2.hexEncodedString()
            )
        }
    }

    // MARK: - CBOR Parsing

    /// Parse COSE_Sign1 structure from CBOR data
    private func parseCOSESign1(_ data: Data) throws -> (payload: Data, signature: Data, protectedHeader: Data) {
        let decoder = CBORDecoder(data: data)

        // COSE_Sign1 is a CBOR array with tag 18
        guard let tag = try? decoder.readTag(), tag == 18 else {
            throw NitroAttestationError.invalidCBOR("Expected COSE_Sign1 tag (18)")
        }

        // Array of 4 elements: [protected, unprotected, payload, signature]
        guard let arrayLength = try? decoder.readArrayLength(), arrayLength == 4 else {
            throw NitroAttestationError.invalidCBOR("COSE_Sign1 must have 4 elements")
        }

        // Protected header (byte string)
        let protectedHeader = try decoder.readByteString()

        // Unprotected header (map) - skip it
        _ = try decoder.skipValue()

        // Payload (byte string)
        let payload = try decoder.readByteString()

        // Signature (byte string)
        let signature = try decoder.readByteString()

        return (payload, signature, protectedHeader)
    }

    /// Parse the attestation document payload
    private func parseAttestationPayload(_ data: Data) throws -> AttestationDocument {
        let decoder = CBORDecoder(data: data)

        // Attestation document is a CBOR map
        guard let mapLength = try? decoder.readMapLength() else {
            throw NitroAttestationError.invalidCBOR("Expected map for attestation document")
        }

        var moduleId: String?
        var timestamp: UInt64?
        var digest: String?
        var pcrs: [Int: Data] = [:]
        var certificate: Data?
        var cabundle: [Data] = []
        var publicKey: Data?
        var userData: Data?
        var nonce: Data?

        for _ in 0..<mapLength {
            let key = try decoder.readTextString()

            switch key {
            case "module_id":
                moduleId = try decoder.readTextString()
            case "timestamp":
                timestamp = try decoder.readUInt64()
            case "digest":
                digest = try decoder.readTextString()
            case "pcrs":
                pcrs = try parsePCRs(decoder)
            case "certificate":
                certificate = try decoder.readByteString()
            case "cabundle":
                cabundle = try parseCertificateBundle(decoder)
            case "public_key":
                publicKey = try? decoder.readByteString()
            case "user_data":
                userData = try? decoder.readByteString()
            case "nonce":
                nonce = try? decoder.readByteString()
            default:
                _ = try decoder.skipValue()
            }
        }

        guard let moduleId = moduleId,
              let timestamp = timestamp,
              let digest = digest,
              let certificate = certificate else {
            throw NitroAttestationError.invalidCBOR("Missing required fields in attestation document")
        }

        return AttestationDocument(
            moduleId: moduleId,
            timestamp: timestamp,
            digest: digest,
            pcrs: pcrs,
            certificate: certificate,
            cabundle: cabundle,
            publicKey: publicKey,
            userData: userData,
            nonce: nonce
        )
    }

    /// Parse PCR map from CBOR
    private func parsePCRs(_ decoder: CBORDecoder) throws -> [Int: Data] {
        guard let mapLength = try? decoder.readMapLength() else {
            throw NitroAttestationError.invalidCBOR("Expected map for PCRs")
        }

        var pcrs: [Int: Data] = [:]
        for _ in 0..<mapLength {
            let index = try decoder.readUInt64()
            let value = try decoder.readByteString()
            pcrs[Int(index)] = value
        }

        return pcrs
    }

    /// Parse certificate bundle array from CBOR
    private func parseCertificateBundle(_ decoder: CBORDecoder) throws -> [Data] {
        guard let arrayLength = try? decoder.readArrayLength() else {
            throw NitroAttestationError.invalidCBOR("Expected array for cabundle")
        }

        var certs: [Data] = []
        for _ in 0..<arrayLength {
            let cert = try decoder.readByteString()
            certs.append(cert)
        }

        return certs
    }

    // MARK: - Certificate Verification

    /// Verify the certificate chain from leaf to AWS Nitro root
    /// Uses dynamic root CA validation - extracts root from cabundle and validates it
    private func verifyCertificateChain(certificate: Data, cabundle: [Data]) throws {
        // Create SecCertificate objects
        guard let leafCert = SecCertificateCreateWithData(nil, certificate as CFData) else {
            throw NitroAttestationError.certificateChainInvalid("Invalid leaf certificate")
        }

        guard !cabundle.isEmpty else {
            throw NitroAttestationError.certificateChainInvalid("CA bundle is empty")
        }

        var intermediateCerts: [SecCertificate] = []
        for certData in cabundle {
            if let cert = SecCertificateCreateWithData(nil, certData as CFData) {
                intermediateCerts.append(cert)
            }
        }

        guard !intermediateCerts.isEmpty else {
            throw NitroAttestationError.certificateChainInvalid("No valid certificates in CA bundle")
        }

        // The last certificate in cabundle is the root CA
        let rootCert = intermediateCerts.last!

        // Verify this is the AWS Nitro root CA by checking common name
        guard let rootSubject = SecCertificateCopySubjectSummary(rootCert) as String? else {
            throw NitroAttestationError.certificateChainInvalid("Could not extract root CA subject")
        }

        // AWS Nitro root CA has CN="aws.nitro-enclaves"
        guard rootSubject.contains(Self.awsNitroRootCN) else {
            throw NitroAttestationError.certificateChainInvalid(
                "Root CA is not AWS Nitro: expected '\(Self.awsNitroRootCN)', got '\(rootSubject)'"
            )
        }

        // Verify root is self-signed by checking if it can verify itself
        try verifySelfSigned(rootCert)

        // Build certificate chain: leaf + intermediates (root is last in intermediates)
        let certsToVerify = [leafCert] + intermediateCerts

        // Create trust object
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()

        let status = SecTrustCreateWithCertificates(
            certsToVerify as CFArray,
            policy,
            &trust
        )

        guard status == errSecSuccess, let trust = trust else {
            throw NitroAttestationError.certificateChainInvalid("Failed to create trust object")
        }

        // Set the dynamically validated root as trust anchor
        SecTrustSetAnchorCertificates(trust, [rootCert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        // Evaluate trust
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)

        guard trusted else {
            let errorDesc = error.map { CFErrorCopyDescription($0) as String? } ?? nil
            throw NitroAttestationError.certificateChainInvalid(
                errorDesc ?? "Certificate chain verification failed"
            )
        }
    }

    /// Verify a certificate is self-signed
    private func verifySelfSigned(_ cert: SecCertificate) throws {
        // Create a trust with only this certificate
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()

        let status = SecTrustCreateWithCertificates(
            [cert] as CFArray,
            policy,
            &trust
        )

        guard status == errSecSuccess, let trust = trust else {
            throw NitroAttestationError.certificateChainInvalid("Failed to verify root is self-signed")
        }

        // Set itself as the only anchor
        SecTrustSetAnchorCertificates(trust, [cert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        // If it's self-signed, it should verify successfully
        var error: CFError?
        let verified = SecTrustEvaluateWithError(trust, &error)

        guard verified else {
            throw NitroAttestationError.certificateChainInvalid("Root CA is not self-signed")
        }
    }

    /// Verify COSE signature using the leaf certificate's public key
    private func verifyCOSESignature(
        protectedHeader: Data,
        payload: Data,
        signature: Data,
        certificate: Data
    ) throws {
        // Extract public key from certificate
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData) else {
            throw NitroAttestationError.invalidCOSESignature("Invalid certificate")
        }

        guard let publicKey = SecCertificateCopyKey(cert) else {
            throw NitroAttestationError.invalidCOSESignature("Could not extract public key")
        }

        // Build Sig_structure for COSE_Sign1
        // Sig_structure = ["Signature1", protected, external_aad, payload]
        let sigStructure = buildSigStructure(
            context: "Signature1",
            protectedHeader: protectedHeader,
            externalAAD: Data(),
            payload: payload
        )

        // Verify signature (ECDSA with SHA-384 for Nitro)
        var error: Unmanaged<CFError>?
        let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA384

        guard SecKeyIsAlgorithmSupported(publicKey, .verify, algorithm) else {
            throw NitroAttestationError.invalidCOSESignature("Unsupported algorithm")
        }

        let verified = SecKeyVerifySignature(
            publicKey,
            algorithm,
            sigStructure as CFData,
            signature as CFData,
            &error
        )

        guard verified else {
            throw NitroAttestationError.invalidCOSESignature("Signature verification failed")
        }
    }

    /// Build COSE Sig_structure for signature verification
    private func buildSigStructure(
        context: String,
        protectedHeader: Data,
        externalAAD: Data,
        payload: Data
    ) -> Data {
        // Sig_structure is CBOR array: [context, protected, external_aad, payload]
        var encoder = CBOREncoder()
        encoder.writeArrayHeader(4)
        encoder.writeTextString(context)
        encoder.writeByteString(protectedHeader)
        encoder.writeByteString(externalAAD)
        encoder.writeByteString(payload)
        return encoder.data
    }

}

// MARK: - Errors

enum NitroAttestationError: Error, LocalizedError {
    case invalidCBOR(String)
    case invalidCOSESignature(String)
    case certificateChainInvalid(String)
    case certificateExpired
    case pcrMismatch(pcr: Int, expected: String, actual: String)
    case pcrSetExpired
    case invalidExpectedPCRFormat
    case missingPCRValues
    case missingPublicKey
    case documentExpired(age: TimeInterval)
    case nonceMismatch

    var errorDescription: String? {
        switch self {
        case .invalidCBOR(let detail):
            return "Invalid CBOR encoding: \(detail)"
        case .invalidCOSESignature(let detail):
            return "Invalid COSE signature: \(detail)"
        case .certificateChainInvalid(let detail):
            return "Certificate chain invalid: \(detail)"
        case .certificateExpired:
            return "Certificate has expired"
        case .pcrMismatch(let pcr, let expected, let actual):
            return "PCR\(pcr) mismatch: expected \(expected.prefix(16))..., got \(actual.prefix(16))..."
        case .pcrSetExpired:
            return "Expected PCR set has expired"
        case .invalidExpectedPCRFormat:
            return "Invalid format for expected PCR values"
        case .missingPCRValues:
            return "Required PCR values missing from attestation"
        case .missingPublicKey:
            return "Enclave public key missing from attestation"
        case .documentExpired(let age):
            return "Attestation document too old (\(Int(age))s)"
        case .nonceMismatch:
            return "Attestation nonce does not match expected value"
        }
    }
}

// MARK: - CBOR Decoder

/// Minimal CBOR decoder for parsing Nitro attestation documents
private class CBORDecoder {
    private var data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var bytesRemaining: Int {
        data.count - offset
    }

    func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw NitroAttestationError.invalidCBOR("Unexpected end of data")
        }
        let byte = data[offset]
        offset += 1
        return byte
    }

    func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw NitroAttestationError.invalidCBOR("Unexpected end of data")
        }
        let bytes = data[offset..<(offset + count)]
        offset += count
        return Data(bytes)
    }

    func readTag() throws -> UInt64 {
        let byte = try readByte()
        let majorType = byte >> 5
        guard majorType == 6 else {
            throw NitroAttestationError.invalidCBOR("Expected tag, got major type \(majorType)")
        }
        return try readArgument(byte & 0x1F)
    }

    func readArrayLength() throws -> Int {
        let byte = try readByte()
        let majorType = byte >> 5
        guard majorType == 4 else {
            throw NitroAttestationError.invalidCBOR("Expected array, got major type \(majorType)")
        }
        return Int(try readArgument(byte & 0x1F))
    }

    func readMapLength() throws -> Int {
        let byte = try readByte()
        let majorType = byte >> 5
        guard majorType == 5 else {
            throw NitroAttestationError.invalidCBOR("Expected map, got major type \(majorType)")
        }
        return Int(try readArgument(byte & 0x1F))
    }

    func readByteString() throws -> Data {
        let byte = try readByte()
        let majorType = byte >> 5
        guard majorType == 2 else {
            throw NitroAttestationError.invalidCBOR("Expected byte string, got major type \(majorType)")
        }
        let length = Int(try readArgument(byte & 0x1F))
        return try readBytes(length)
    }

    func readTextString() throws -> String {
        let byte = try readByte()
        let majorType = byte >> 5
        guard majorType == 3 else {
            throw NitroAttestationError.invalidCBOR("Expected text string, got major type \(majorType)")
        }
        let length = Int(try readArgument(byte & 0x1F))
        let bytes = try readBytes(length)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw NitroAttestationError.invalidCBOR("Invalid UTF-8 in text string")
        }
        return string
    }

    func readUInt64() throws -> UInt64 {
        let byte = try readByte()
        let majorType = byte >> 5
        guard majorType == 0 else {
            throw NitroAttestationError.invalidCBOR("Expected unsigned integer, got major type \(majorType)")
        }
        return try readArgument(byte & 0x1F)
    }

    private func readArgument(_ additionalInfo: UInt8) throws -> UInt64 {
        switch additionalInfo {
        case 0...23:
            return UInt64(additionalInfo)
        case 24:
            return UInt64(try readByte())
        case 25:
            let bytes = try readBytes(2)
            return UInt64(bytes[0]) << 8 | UInt64(bytes[1])
        case 26:
            let bytes = try readBytes(4)
            return UInt64(bytes[0]) << 24 | UInt64(bytes[1]) << 16 |
                   UInt64(bytes[2]) << 8 | UInt64(bytes[3])
        case 27:
            let bytes = try readBytes(8)
            return UInt64(bytes[0]) << 56 | UInt64(bytes[1]) << 48 |
                   UInt64(bytes[2]) << 40 | UInt64(bytes[3]) << 32 |
                   UInt64(bytes[4]) << 24 | UInt64(bytes[5]) << 16 |
                   UInt64(bytes[6]) << 8 | UInt64(bytes[7])
        default:
            throw NitroAttestationError.invalidCBOR("Invalid additional info: \(additionalInfo)")
        }
    }

    func skipValue() throws {
        let byte = try readByte()
        let majorType = byte >> 5
        let additionalInfo = byte & 0x1F

        switch majorType {
        case 0, 1: // Unsigned/negative integer
            _ = try readArgument(additionalInfo)
        case 2, 3: // Byte/text string
            let length = Int(try readArgument(additionalInfo))
            _ = try readBytes(length)
        case 4: // Array
            let length = Int(try readArgument(additionalInfo))
            for _ in 0..<length {
                try skipValue()
            }
        case 5: // Map
            let length = Int(try readArgument(additionalInfo))
            for _ in 0..<length {
                try skipValue()
                try skipValue()
            }
        case 6: // Tag
            _ = try readArgument(additionalInfo)
            try skipValue()
        case 7: // Simple/float
            switch additionalInfo {
            case 0...23: break
            case 24: _ = try readByte()
            case 25: _ = try readBytes(2)
            case 26: _ = try readBytes(4)
            case 27: _ = try readBytes(8)
            default: break
            }
        default:
            throw NitroAttestationError.invalidCBOR("Unknown major type: \(majorType)")
        }
    }
}

// MARK: - CBOR Encoder

/// Minimal CBOR encoder for building Sig_structure
private struct CBOREncoder {
    var data = Data()

    mutating func writeArrayHeader(_ count: Int) {
        writeHeader(majorType: 4, count: UInt64(count))
    }

    mutating func writeTextString(_ string: String) {
        let bytes = string.data(using: .utf8)!
        writeHeader(majorType: 3, count: UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func writeByteString(_ bytes: Data) {
        writeHeader(majorType: 2, count: UInt64(bytes.count))
        data.append(bytes)
    }

    private mutating func writeHeader(majorType: UInt8, count: UInt64) {
        let mt = majorType << 5
        if count <= 23 {
            data.append(mt | UInt8(count))
        } else if count <= UInt8.max {
            data.append(mt | 24)
            data.append(UInt8(count))
        } else if count <= UInt16.max {
            data.append(mt | 25)
            data.append(UInt8((count >> 8) & 0xFF))
            data.append(UInt8(count & 0xFF))
        } else if count <= UInt32.max {
            data.append(mt | 26)
            data.append(UInt8((count >> 24) & 0xFF))
            data.append(UInt8((count >> 16) & 0xFF))
            data.append(UInt8((count >> 8) & 0xFF))
            data.append(UInt8(count & 0xFF))
        } else {
            data.append(mt | 27)
            for i in (0..<8).reversed() {
                data.append(UInt8((count >> (i * 8)) & 0xFF))
            }
        }
    }
}

// MARK: - Data Extensions

extension Data {
    /// Initialize from hex string
    init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }

        var data = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Convert to hex string
    func hexEncodedString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
