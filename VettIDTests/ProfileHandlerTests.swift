import XCTest
@testable import VettID

/// Unit tests for ProfileHandler
final class ProfileHandlerTests: XCTestCase {

    // MARK: - ProfileField Tests

    func testProfileField_rawValues() {
        XCTAssertEqual(ProfileField.displayName.rawValue, "display_name")
        XCTAssertEqual(ProfileField.bio.rawValue, "bio")
        XCTAssertEqual(ProfileField.location.rawValue, "location")
        XCTAssertEqual(ProfileField.email.rawValue, "email")
        XCTAssertEqual(ProfileField.phone.rawValue, "phone")
        XCTAssertEqual(ProfileField.website.rawValue, "website")
        XCTAssertEqual(ProfileField.avatarUrl.rawValue, "avatar_url")
        XCTAssertEqual(ProfileField.publicKey.rawValue, "public_key")
    }

    func testProfileField_displayLabels() {
        XCTAssertEqual(ProfileField.displayName.displayLabel, "Display Name")
        XCTAssertEqual(ProfileField.bio.displayLabel, "Bio")
        XCTAssertEqual(ProfileField.location.displayLabel, "Location")
        XCTAssertEqual(ProfileField.email.displayLabel, "Email")
        XCTAssertEqual(ProfileField.phone.displayLabel, "Phone")
        XCTAssertEqual(ProfileField.website.displayLabel, "Website")
        XCTAssertEqual(ProfileField.avatarUrl.displayLabel, "Avatar")
        XCTAssertEqual(ProfileField.publicKey.displayLabel, "Public Key")
    }

    func testProfileField_publicFields() {
        let publicFields = ProfileField.publicFields

        XCTAssertTrue(publicFields.contains(.displayName))
        XCTAssertTrue(publicFields.contains(.bio))
        XCTAssertTrue(publicFields.contains(.location))
        XCTAssertTrue(publicFields.contains(.avatarUrl))

        // These should NOT be in public fields
        XCTAssertFalse(publicFields.contains(.email))
        XCTAssertFalse(publicFields.contains(.phone))
        XCTAssertFalse(publicFields.contains(.website))
        XCTAssertFalse(publicFields.contains(.publicKey))
    }

    func testProfileField_privateFields() {
        let privateFields = ProfileField.privateFields

        XCTAssertTrue(privateFields.contains(.email))
        XCTAssertTrue(privateFields.contains(.phone))
        XCTAssertTrue(privateFields.contains(.website))

        // These should NOT be in private fields
        XCTAssertFalse(privateFields.contains(.displayName))
        XCTAssertFalse(privateFields.contains(.bio))
        XCTAssertFalse(privateFields.contains(.location))
        XCTAssertFalse(privateFields.contains(.avatarUrl))
    }

    func testProfileField_allCases() {
        let allCases = ProfileField.allCases

        XCTAssertEqual(allCases.count, 8)
        XCTAssertTrue(allCases.contains(.displayName))
        XCTAssertTrue(allCases.contains(.bio))
        XCTAssertTrue(allCases.contains(.location))
        XCTAssertTrue(allCases.contains(.email))
        XCTAssertTrue(allCases.contains(.phone))
        XCTAssertTrue(allCases.contains(.website))
        XCTAssertTrue(allCases.contains(.avatarUrl))
        XCTAssertTrue(allCases.contains(.publicKey))
    }

    func testProfileField_publicAndPrivateCoverage() {
        let publicFields = Set(ProfileField.publicFields)
        let privateFields = Set(ProfileField.privateFields)

        // Public and private should not overlap
        XCTAssertTrue(publicFields.isDisjoint(with: privateFields))

        // Combined they should cover most fields (except publicKey)
        let combined = publicFields.union(privateFields)
        XCTAssertEqual(combined.count, 7)
    }

    // MARK: - ProfileHandlerError Tests

    func testProfileHandlerError_getFailedDescription() {
        let error = ProfileHandlerError.getFailed("Connection refused")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("get"))
        XCTAssertTrue(error.errorDescription!.contains("Connection refused"))
    }

    func testProfileHandlerError_updateFailedDescription() {
        let error = ProfileHandlerError.updateFailed("Validation error")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("update"))
        XCTAssertTrue(error.errorDescription!.contains("Validation error"))
    }

    func testProfileHandlerError_deleteFailedDescription() {
        let error = ProfileHandlerError.deleteFailed("Field not found")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("delete"))
        XCTAssertTrue(error.errorDescription!.contains("Field not found"))
    }

    func testProfileHandlerError_broadcastFailedDescription() {
        let error = ProfileHandlerError.broadcastFailed("No connections")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("broadcast"))
        XCTAssertTrue(error.errorDescription!.contains("No connections"))
    }

    func testProfileHandlerError_switchCoverage() {
        let errors: [ProfileHandlerError] = [
            .getFailed("test"),
            .updateFailed("test"),
            .deleteFailed("test"),
            .broadcastFailed("test")
        ]

        for error in errors {
            switch error {
            case .getFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .updateFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .deleteFailed(let reason):
                XCTAssertEqual(reason, "test")
            case .broadcastFailed(let reason):
                XCTAssertEqual(reason, "test")
            }
        }
    }

    // MARK: - Profile Data Validation Tests

    func testProfileField_emailValidation() {
        let validEmails = ["test@example.com", "user.name@domain.org", "a@b.co"]
        let invalidEmails = ["", "not-an-email", "@no-user.com", "no-domain@"]

        for email in validEmails {
            XCTAssertTrue(isValidEmail(email), "Should be valid: \(email)")
        }

        for email in invalidEmails {
            XCTAssertFalse(isValidEmail(email), "Should be invalid: \(email)")
        }
    }

    func testProfileField_phoneValidation() {
        // Basic phone number patterns
        let validPhones = ["+1234567890", "123-456-7890", "(123) 456-7890"]

        for phone in validPhones {
            XCTAssertTrue(phone.count >= 10, "Phone should have at least 10 characters: \(phone)")
        }
    }

    // MARK: - Profile Dictionary Tests

    func testProfile_dictionaryConversion() {
        var profile: [String: String] = [:]
        profile[ProfileField.displayName.rawValue] = "John Doe"
        profile[ProfileField.email.rawValue] = "john@example.com"
        profile[ProfileField.bio.rawValue] = "Software developer"

        XCTAssertEqual(profile["display_name"], "John Doe")
        XCTAssertEqual(profile["email"], "john@example.com")
        XCTAssertEqual(profile["bio"], "Software developer")
    }

    func testProfile_emptyFieldsHandling() {
        var profile: [String: String] = [:]
        profile[ProfileField.displayName.rawValue] = ""
        profile[ProfileField.bio.rawValue] = nil

        XCTAssertEqual(profile[ProfileField.displayName.rawValue], "")
        XCTAssertNil(profile[ProfileField.bio.rawValue])
    }

    // MARK: - Helper Methods

    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
}
