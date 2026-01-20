import Foundation

// MARK: - Service Profile

/// Represents an organizational service that users can connect to
struct ServiceProfile: Codable, Identifiable, Equatable {
    let id: String  // service_guid
    let serviceName: String
    let serviceDescription: String
    let serviceLogoUrl: String?
    let serviceCategory: ServiceCategory
    let organization: OrganizationInfo
    let contactInfo: ServiceContactInfo
    let trustedResources: [TrustedResource]
    let currentContract: ServiceDataContract
    let profileVersion: Int
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "service_guid"
        case serviceName = "service_name"
        case serviceDescription = "service_description"
        case serviceLogoUrl = "service_logo_url"
        case serviceCategory = "service_category"
        case organization
        case contactInfo = "contact_info"
        case trustedResources = "trusted_resources"
        case currentContract = "current_contract"
        case profileVersion = "profile_version"
        case updatedAt = "updated_at"
    }
}

/// Service category
enum ServiceCategory: String, Codable, CaseIterable {
    case retail
    case healthcare
    case finance
    case government
    case education
    case entertainment
    case technology
    case transportation
    case hospitality
    case utilities
    case other

    var displayName: String {
        switch self {
        case .retail: return "Retail"
        case .healthcare: return "Healthcare"
        case .finance: return "Finance"
        case .government: return "Government"
        case .education: return "Education"
        case .entertainment: return "Entertainment"
        case .technology: return "Technology"
        case .transportation: return "Transportation"
        case .hospitality: return "Hospitality"
        case .utilities: return "Utilities"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .retail: return "cart.fill"
        case .healthcare: return "cross.case.fill"
        case .finance: return "banknote.fill"
        case .government: return "building.columns.fill"
        case .education: return "graduationcap.fill"
        case .entertainment: return "film.fill"
        case .technology: return "laptopcomputer"
        case .transportation: return "car.fill"
        case .hospitality: return "bed.double.fill"
        case .utilities: return "bolt.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }
}

// MARK: - Organization Info

/// Organization details with verification status
struct OrganizationInfo: Codable, Equatable {
    let name: String
    let verified: Bool
    let verificationType: VerificationType?
    let verifiedAt: Date?
    let registrationId: String?
    let country: String?

    enum CodingKeys: String, CodingKey {
        case name
        case verified
        case verificationType = "verification_type"
        case verifiedAt = "verified_at"
        case registrationId = "registration_id"
        case country
    }
}

/// Organization verification type
enum VerificationType: String, Codable {
    case business
    case nonprofit
    case government

    var displayName: String {
        switch self {
        case .business: return "Verified Business"
        case .nonprofit: return "Verified Nonprofit"
        case .government: return "Government Entity"
        }
    }

    var badgeColor: String {
        switch self {
        case .business: return "#2196F3"    // Blue
        case .nonprofit: return "#4CAF50"    // Green
        case .government: return "#9C27B0"   // Purple
        }
    }
}

// MARK: - Contact Info

/// Service contact information
struct ServiceContactInfo: Codable, Equatable {
    let emails: [VerifiedContact]
    let phoneNumbers: [VerifiedContact]
    let address: PhysicalAddress?
    let supportUrl: String?
    let supportEmail: String?
    let supportPhone: String?

    enum CodingKeys: String, CodingKey {
        case emails
        case phoneNumbers = "phone_numbers"
        case address
        case supportUrl = "support_url"
        case supportEmail = "support_email"
        case supportPhone = "support_phone"
    }
}

/// A verified contact method
struct VerifiedContact: Codable, Identifiable, Equatable {
    var id: String { value }
    let value: String
    let label: String
    let verified: Bool
    let verifiedAt: Date?
    let primary: Bool

    enum CodingKeys: String, CodingKey {
        case value
        case label
        case verified
        case verifiedAt = "verified_at"
        case primary
    }
}

/// Physical address
struct PhysicalAddress: Codable, Equatable {
    let street: String
    let city: String
    let state: String?
    let postalCode: String
    let country: String

    enum CodingKeys: String, CodingKey {
        case street
        case city
        case state
        case postalCode = "postal_code"
        case country
    }

    var formatted: String {
        var parts = [street, city]
        if let state = state {
            parts.append(state)
        }
        parts.append(postalCode)
        parts.append(country)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Trusted Resources

/// Resource that has been verified by the service
struct TrustedResource: Codable, Identifiable, Equatable {
    let id: String
    let type: TrustedResourceType
    let label: String
    let description: String?
    let url: String
    let download: DownloadInfo?
    let addedAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id = "resource_id"
        case type
        case label
        case description
        case url
        case download
        case addedAt = "added_at"
        case updatedAt = "updated_at"
    }
}

/// Type of trusted resource
enum TrustedResourceType: String, Codable {
    case website
    case appDownload = "app_download"
    case document
    case api

    var displayName: String {
        switch self {
        case .website: return "Website"
        case .appDownload: return "App Download"
        case .document: return "Document"
        case .api: return "API"
        }
    }

    var icon: String {
        switch self {
        case .website: return "globe"
        case .appDownload: return "arrow.down.app.fill"
        case .document: return "doc.fill"
        case .api: return "terminal.fill"
        }
    }
}

/// Download information for app resources
struct DownloadInfo: Codable, Equatable {
    let platform: DownloadPlatform
    let version: String
    let versionCode: Int?
    let minOsVersion: String?
    let fileSize: Int64
    let fileName: String
    let signatures: [DownloadSignature]

    enum CodingKeys: String, CodingKey {
        case platform
        case version
        case versionCode = "version_code"
        case minOsVersion = "min_os_version"
        case fileSize = "file_size"
        case fileName = "file_name"
        case signatures
    }

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}

/// Platform for downloads
enum DownloadPlatform: String, Codable {
    case android
    case ios
    case windows
    case macos
    case linux
    case web

    var displayName: String {
        switch self {
        case .android: return "Android"
        case .ios: return "iOS"
        case .windows: return "Windows"
        case .macos: return "macOS"
        case .linux: return "Linux"
        case .web: return "Web"
        }
    }
}

/// Cryptographic signature for download verification
struct DownloadSignature: Codable, Equatable {
    let algorithm: String
    let hash: String
    let signedBy: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case algorithm
        case hash
        case signedBy = "signed_by"
        case signature
    }
}

// MARK: - Data Contract

/// Data sharing contract with a service
struct ServiceDataContract: Codable, Identifiable, Equatable {
    let id: String
    let serviceGuid: String
    let version: Int
    let title: String
    let description: String
    let termsUrl: String?
    let privacyUrl: String?
    let requiredFields: [FieldSpec]
    let optionalFields: [FieldSpec]
    let onDemandFields: [String]
    let consentFields: [String]
    let canStoreData: Bool
    let storageCategories: [String]
    let canSendMessages: Bool
    let canRequestAuth: Bool
    let canRequestPayment: Bool
    let maxRequestsPerHour: Int?
    let maxStorageMB: Int?
    let createdAt: Date
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id = "contract_id"
        case serviceGuid = "service_guid"
        case version
        case title
        case description
        case termsUrl = "terms_url"
        case privacyUrl = "privacy_url"
        case requiredFields = "required_fields"
        case optionalFields = "optional_fields"
        case onDemandFields = "on_demand_fields"
        case consentFields = "consent_fields"
        case canStoreData = "can_store_data"
        case storageCategories = "storage_categories"
        case canSendMessages = "can_send_messages"
        case canRequestAuth = "can_request_auth"
        case canRequestPayment = "can_request_payment"
        case maxRequestsPerHour = "max_requests_per_hour"
        case maxStorageMB = "max_storage_mb"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

/// Specification for a data field
struct FieldSpec: Codable, Identifiable, Equatable {
    var id: String { field }
    let field: String
    let purpose: String
    let retention: String

    var fieldType: ServiceFieldType {
        ServiceFieldType(rawValue: field) ?? .custom
    }
}

/// Types of fields a service can request
enum ServiceFieldType: String, Codable, CaseIterable {
    case displayName = "display_name"
    case email
    case phone
    case dateOfBirth = "date_of_birth"
    case address
    case photo
    case governmentId = "government_id"
    case proofOfResidence = "proof_of_residence"
    case employmentInfo = "employment_info"
    case financialInfo = "financial_info"
    case healthInfo = "health_info"
    case custom

    var displayLabel: String {
        switch self {
        case .displayName: return "Display Name"
        case .email: return "Email Address"
        case .phone: return "Phone Number"
        case .dateOfBirth: return "Date of Birth"
        case .address: return "Address"
        case .photo: return "Photo"
        case .governmentId: return "Government ID"
        case .proofOfResidence: return "Proof of Residence"
        case .employmentInfo: return "Employment Information"
        case .financialInfo: return "Financial Information"
        case .healthInfo: return "Health Information"
        case .custom: return "Custom Field"
        }
    }

    var icon: String {
        switch self {
        case .displayName: return "person.fill"
        case .email: return "envelope.fill"
        case .phone: return "phone.fill"
        case .dateOfBirth: return "calendar"
        case .address: return "location.fill"
        case .photo: return "camera.fill"
        case .governmentId: return "person.text.rectangle"
        case .proofOfResidence: return "house.fill"
        case .employmentInfo: return "briefcase.fill"
        case .financialInfo: return "dollarsign.circle.fill"
        case .healthInfo: return "heart.fill"
        case .custom: return "square.grid.2x2.fill"
        }
    }

    var sensitivityLevel: SensitivityLevel {
        switch self {
        case .displayName: return .low
        case .email, .phone: return .medium
        case .dateOfBirth, .address, .photo: return .high
        case .governmentId, .proofOfResidence, .employmentInfo,
             .financialInfo, .healthInfo: return .critical
        case .custom: return .medium
        }
    }
}

/// Sensitivity level for data fields
enum SensitivityLevel: String, Codable {
    case low
    case medium
    case high
    case critical

    var color: String {
        switch self {
        case .low: return "#4CAF50"
        case .medium: return "#FF9800"
        case .high: return "#F44336"
        case .critical: return "#9C27B0"
        }
    }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }
}

// MARK: - Service Connection Record

/// Active connection with a service
struct ServiceConnectionRecord: Codable, Identifiable, Equatable {
    let id: String
    let serviceGuid: String
    let serviceProfile: ServiceProfile
    let contractId: String
    let contractVersion: Int
    let contractAcceptedAt: Date
    let pendingContractVersion: Int?
    var status: ServiceConnectionStatus
    let sharedFields: [SharedFieldMapping]
    let createdAt: Date
    var lastActivityAt: Date?

    // Usability properties
    var tags: [String]
    var isFavorite: Bool
    var isArchived: Bool
    var isMuted: Bool

    enum CodingKeys: String, CodingKey {
        case id = "connection_id"
        case serviceGuid = "service_guid"
        case serviceProfile = "service_profile"
        case contractId = "contract_id"
        case contractVersion = "contract_version"
        case contractAcceptedAt = "contract_accepted_at"
        case pendingContractVersion = "pending_contract_version"
        case status
        case sharedFields = "shared_fields"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
        case tags
        case isFavorite = "is_favorite"
        case isArchived = "is_archived"
        case isMuted = "is_muted"
    }

    init(
        id: String,
        serviceGuid: String,
        serviceProfile: ServiceProfile,
        contractId: String,
        contractVersion: Int,
        contractAcceptedAt: Date,
        pendingContractVersion: Int? = nil,
        status: ServiceConnectionStatus = .active,
        sharedFields: [SharedFieldMapping] = [],
        createdAt: Date = Date(),
        lastActivityAt: Date? = nil,
        tags: [String] = [],
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isMuted: Bool = false
    ) {
        self.id = id
        self.serviceGuid = serviceGuid
        self.serviceProfile = serviceProfile
        self.contractId = contractId
        self.contractVersion = contractVersion
        self.contractAcceptedAt = contractAcceptedAt
        self.pendingContractVersion = pendingContractVersion
        self.status = status
        self.sharedFields = sharedFields
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.tags = tags
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.isMuted = isMuted
    }
}

/// Service connection status
enum ServiceConnectionStatus: String, Codable {
    case pending
    case active
    case suspended
    case revoked
    case expired

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .active: return "Active"
        case .suspended: return "Suspended"
        case .revoked: return "Revoked"
        case .expired: return "Expired"
        }
    }

    var color: String {
        switch self {
        case .pending: return "#FF9800"
        case .active: return "#4CAF50"
        case .suspended: return "#F44336"
        case .revoked: return "#9E9E9E"
        case .expired: return "#9E9E9E"
        }
    }
}

/// Mapping of shared field to service
struct SharedFieldMapping: Codable, Identifiable, Equatable {
    var id: String { fieldSpec.field }
    let fieldSpec: FieldSpec
    let localFieldKey: String?
    let sharedAt: Date
    var lastUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case fieldSpec = "field_spec"
        case localFieldKey = "local_field_key"
        case sharedAt = "shared_at"
        case lastUpdatedAt = "last_updated_at"
    }
}

// MARK: - Service Activity

/// Activity record for a service connection
struct ServiceActivity: Codable, Identifiable, Equatable {
    let id: String
    let connectionId: String
    let type: ServiceActivityType
    let description: String
    let fields: [String]?
    let amount: Money?
    let status: String
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id = "activity_id"
        case connectionId = "connection_id"
        case type
        case description
        case fields
        case amount
        case status
        case timestamp
    }
}

/// Type of service activity
enum ServiceActivityType: String, Codable {
    case dataRequested = "data_request"
    case dataStored = "data_store"
    case auth
    case payment
    case messageReceived = "message"
    case contractUpdate = "contract_update"

    var displayName: String {
        switch self {
        case .dataRequested: return "Data Request"
        case .dataStored: return "Data Stored"
        case .auth: return "Authentication"
        case .payment: return "Payment"
        case .messageReceived: return "Message"
        case .contractUpdate: return "Contract Update"
        }
    }

    var icon: String {
        switch self {
        case .dataRequested: return "arrow.down.doc.fill"
        case .dataStored: return "externaldrive.fill"
        case .auth: return "person.badge.key.fill"
        case .payment: return "creditcard.fill"
        case .messageReceived: return "message.fill"
        case .contractUpdate: return "doc.badge.arrow.up.fill"
        }
    }
}

/// Money amount with currency
struct Money: Codable, Equatable {
    let amount: Decimal
    let currency: String

    var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currency) \(amount)"
    }
}

/// Activity summary for a service connection
struct ServiceActivitySummary: Codable, Equatable {
    let connectionId: String
    let totalDataRequests: Int
    let totalDataStored: Int
    let totalAuthRequests: Int
    let totalPayments: Int
    let totalPaymentAmount: Money?
    let lastActivityAt: Date?
    let activityThisMonth: Int

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case totalDataRequests = "total_data_requests"
        case totalDataStored = "total_data_stored"
        case totalAuthRequests = "total_auth_requests"
        case totalPayments = "total_payments"
        case totalPaymentAmount = "total_payment_amount"
        case lastActivityAt = "last_activity_at"
        case activityThisMonth = "activity_this_month"
    }
}

// MARK: - Service Request

/// Request from a service (for unified feed)
struct ServiceRequest: Codable, Identifiable, Equatable {
    let id: String
    let connectionId: String
    let type: ServiceRequestType
    let requestedFields: [String]?
    let requestedAction: String?
    let purpose: String?
    let amount: Money?
    let status: ServiceRequestStatus
    let requestedAt: Date
    let expiresAt: Date
    var respondedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id = "request_id"
        case connectionId = "connection_id"
        case type = "request_type"
        case requestedFields = "requested_fields"
        case requestedAction = "requested_action"
        case purpose
        case amount
        case status
        case requestedAt = "requested_at"
        case expiresAt = "expires_at"
        case respondedAt = "responded_at"
    }
}

/// Type of service request
enum ServiceRequestType: String, Codable {
    case data
    case auth
    case consent
    case payment

    var displayName: String {
        switch self {
        case .data: return "Data Request"
        case .auth: return "Authentication"
        case .consent: return "Consent Request"
        case .payment: return "Payment Request"
        }
    }

    var icon: String {
        switch self {
        case .data: return "doc.text.fill"
        case .auth: return "person.badge.key.fill"
        case .consent: return "checkmark.shield.fill"
        case .payment: return "creditcard.fill"
        }
    }
}

/// Status of a service request
enum ServiceRequestStatus: String, Codable {
    case pending
    case approved
    case denied
    case expired

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .denied: return "Denied"
        case .expired: return "Expired"
        }
    }
}

// MARK: - Notification Settings

/// Notification preferences for a service connection
struct ServiceNotificationSettings: Codable, Equatable {
    let connectionId: String
    var level: NotificationLevel
    var dataRequestsEnabled: Bool
    var authRequestsEnabled: Bool
    var paymentRequestsEnabled: Bool
    var messagesEnabled: Bool
    var bypassQuietHours: Bool

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case level
        case dataRequestsEnabled = "data_requests_enabled"
        case authRequestsEnabled = "auth_requests_enabled"
        case paymentRequestsEnabled = "payment_requests_enabled"
        case messagesEnabled = "messages_enabled"
        case bypassQuietHours = "bypass_quiet_hours"
    }

    static func defaultSettings(for connectionId: String) -> ServiceNotificationSettings {
        ServiceNotificationSettings(
            connectionId: connectionId,
            level: .all,
            dataRequestsEnabled: true,
            authRequestsEnabled: true,
            paymentRequestsEnabled: true,
            messagesEnabled: true,
            bypassQuietHours: false
        )
    }
}

/// Notification level
enum NotificationLevel: String, Codable {
    case all
    case important
    case muted

    var displayName: String {
        switch self {
        case .all: return "All Notifications"
        case .important: return "Important Only"
        case .muted: return "Muted"
        }
    }
}

// MARK: - Connection Health

/// Health metrics for a service connection
struct ServiceConnectionHealth: Codable, Equatable {
    let connectionId: String
    let status: ConnectionHealthStatus
    let lastActiveAt: Date?
    let contractStatus: ContractStatus
    let dataStorageUsed: Int64
    let dataStorageLimit: Int64
    let requestsThisHour: Int
    let requestLimit: Int
    let issues: [String]

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case status
        case lastActiveAt = "last_active_at"
        case contractStatus = "contract_status"
        case dataStorageUsed = "data_storage_used"
        case dataStorageLimit = "data_storage_limit"
        case requestsThisHour = "requests_this_hour"
        case requestLimit = "request_limit"
        case issues
    }

    var storageUsagePercent: Double {
        guard dataStorageLimit > 0 else { return 0 }
        return Double(dataStorageUsed) / Double(dataStorageLimit)
    }

    var requestUsagePercent: Double {
        guard requestLimit > 0 else { return 0 }
        return Double(requestsThisHour) / Double(requestLimit)
    }
}

/// Connection health status
enum ConnectionHealthStatus: String, Codable {
    case healthy
    case warning
    case critical

    var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    var color: String {
        switch self {
        case .healthy: return "#4CAF50"
        case .warning: return "#FF9800"
        case .critical: return "#F44336"
        }
    }

    var icon: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        }
    }
}

/// Contract status
enum ContractStatus: String, Codable {
    case current
    case updateAvailable = "update_available"
    case expired

    var displayName: String {
        switch self {
        case .current: return "Current"
        case .updateAvailable: return "Update Available"
        case .expired: return "Expired"
        }
    }
}

// MARK: - Trust Indicators

/// Trust signals for a service connection
struct ServiceTrustIndicators: Codable, Equatable {
    let organizationVerified: Bool
    let verificationType: VerificationType?
    let connectionAge: TimeInterval
    let totalInteractions: Int
    let lastActivity: Date?
    let contractVersion: Int
    let pendingContractUpdate: Bool
    let rateLimitViolations: Int
    let contractViolations: Int
    let hasExcessiveRequests: Bool

    enum CodingKeys: String, CodingKey {
        case organizationVerified = "organization_verified"
        case verificationType = "verification_type"
        case connectionAge = "connection_age"
        case totalInteractions = "total_interactions"
        case lastActivity = "last_activity"
        case contractVersion = "contract_version"
        case pendingContractUpdate = "pending_contract_update"
        case rateLimitViolations = "rate_limit_violations"
        case contractViolations = "contract_violations"
        case hasExcessiveRequests = "has_excessive_requests"
    }
}

// MARK: - Service Storage Record

/// Record of data stored by a service (for transparency)
struct ServiceStorageRecord: Codable, Identifiable {
    let id: String
    let connectionId: String
    let category: String
    let visibilityLevel: VisibilityLevel
    let label: String?
    let description: String?
    let dataType: String?
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id = "key"
        case connectionId = "connection_id"
        case category
        case visibilityLevel = "visibility_level"
        case label
        case description
        case dataType = "data_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
    }
}

/// Visibility level for stored data
enum VisibilityLevel: String, Codable {
    case hidden
    case metadata
    case viewable

    var displayName: String {
        switch self {
        case .hidden: return "Hidden"
        case .metadata: return "Metadata Only"
        case .viewable: return "Viewable"
        }
    }
}

// MARK: - Contract Update

/// Contract update notification
struct ContractUpdate: Codable, Equatable {
    let previousVersion: Int
    let newVersion: Int
    let changes: ContractChanges
    let reason: String
    let publishedAt: Date
    let requiredBy: Date?

    enum CodingKeys: String, CodingKey {
        case previousVersion = "previous_version"
        case newVersion = "new_version"
        case changes
        case reason
        case publishedAt = "published_at"
        case requiredBy = "required_by"
    }
}

/// Changes between contract versions
struct ContractChanges: Codable, Equatable {
    let addedFields: [FieldSpec]
    let removedFields: [String]
    let changedFields: [FieldSpec]
    let permissionChanges: [String]
    let rateLimitChanges: String?

    enum CodingKeys: String, CodingKey {
        case addedFields = "added_fields"
        case removedFields = "removed_fields"
        case changedFields = "changed_fields"
        case permissionChanges = "permission_changes"
        case rateLimitChanges = "rate_limit_changes"
    }

    var hasChanges: Bool {
        !addedFields.isEmpty || !removedFields.isEmpty || !changedFields.isEmpty ||
        !permissionChanges.isEmpty || rateLimitChanges != nil
    }
}

/// Historical record of contract versions
struct ContractVersion: Codable, Identifiable {
    let id: String
    let connectionId: String
    let contract: ServiceDataContract
    let acceptedAt: Date
    let supersededAt: Date?
    let changesSummary: String?

    enum CodingKeys: String, CodingKey {
        case id = "version_id"
        case connectionId = "connection_id"
        case contract
        case acceptedAt = "accepted_at"
        case supersededAt = "superseded_at"
        case changesSummary = "changes_summary"
    }
}

// MARK: - Offline Support

/// Queued action for offline support
struct OfflineServiceAction: Codable, Identifiable {
    let id: String
    let connectionId: String
    let actionType: OfflineActionType
    let payload: Data
    let createdAt: Date
    var retryCount: Int
    var lastAttemptAt: Date?
    var syncStatus: SyncStatus
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id = "action_id"
        case connectionId = "connection_id"
        case actionType = "action_type"
        case payload
        case createdAt = "created_at"
        case retryCount = "retry_count"
        case lastAttemptAt = "last_attempt_at"
        case syncStatus = "sync_status"
        case error
    }
}

/// Type of offline action
enum OfflineActionType: String, Codable {
    case requestResponse = "request_response"
    case revoke
    case contractAccept = "contract_accept"
    case updateSettings = "update_settings"

    var displayName: String {
        switch self {
        case .requestResponse: return "Request Response"
        case .revoke: return "Revoke Connection"
        case .contractAccept: return "Accept Contract"
        case .updateSettings: return "Update Settings"
        }
    }
}

/// Sync status for offline actions
enum SyncStatus: String, Codable {
    case pending
    case synced
    case failed

    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .synced: return "Synced"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Discovery Result

/// Result from discovering a service
struct ServiceDiscoveryResult: Codable {
    let serviceProfile: ServiceProfile
    let proposedContract: ServiceDataContract
    let missingRequiredFields: [FieldSpec]

    enum CodingKeys: String, CodingKey {
        case serviceProfile = "service_profile"
        case proposedContract = "proposed_contract"
        case missingRequiredFields = "missing_required_fields"
    }
}

// MARK: - Data Export

/// Exported data from a service connection
struct ServiceDataExport: Codable {
    let connectionId: String
    let serviceName: String
    let exportedAt: Date
    let format: String
    let data: Data

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case serviceName = "service_name"
        case exportedAt = "exported_at"
        case format
        case data
    }
}

// MARK: - Data Summary

/// Summary of data stored by a service
struct ServiceDataSummary: Codable, Equatable {
    let connectionId: String
    let totalItems: Int
    let totalSizeBytes: Int64
    let categories: [String: Int]
    let oldestItem: Date?
    let newestItem: Date?

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case totalItems = "total_items"
        case totalSizeBytes = "total_size_bytes"
        case categories
        case oldestItem = "oldest_item"
        case newestItem = "newest_item"
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSizeBytes)
    }
}
