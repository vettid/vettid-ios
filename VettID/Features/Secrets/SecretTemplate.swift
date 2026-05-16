import Foundation

// MARK: - Template Field

struct TemplateField {
    let name: String
    let type: SecretType
    let placeholder: String
    let inputHint: FieldInputHint

    init(name: String, type: SecretType = .text, placeholder: String = "", inputHint: FieldInputHint = .text) {
        self.name = name
        self.type = type
        self.placeholder = placeholder
        self.inputHint = inputHint
    }
}

// MARK: - Secret Template

struct SecretTemplate: Identifiable {
    let id = UUID().uuidString
    let name: String
    let description: String
    let category: SecretCategory
    let iconName: String
    let fields: [TemplateField]
}

// MARK: - Pre-defined Templates

extension SecretTemplate {
    static let driversLicense = SecretTemplate(
        name: "Driver's License",
        description: "Store your driver's license details",
        category: .driversLicense,
        iconName: "car.fill",
        fields: [
            TemplateField(name: "License Number", type: .accountNumber, placeholder: "DL number"),
            TemplateField(name: "State", type: .text, placeholder: "Issuing state", inputHint: .state),
            TemplateField(name: "Issue Date", type: .text, placeholder: "MM/DD/YYYY", inputHint: .date),
            TemplateField(name: "Expiration Date", type: .text, placeholder: "MM/YYYY", inputHint: .expiryDate),
            TemplateField(name: "Date of Birth", type: .text, placeholder: "MM/DD/YYYY", inputHint: .date),
            TemplateField(name: "Class", type: .text, placeholder: "License class")
        ]
    )

    static let passport = SecretTemplate(
        name: "Passport",
        description: "Store your passport information",
        category: .passport,
        iconName: "airplane",
        fields: [
            TemplateField(name: "Passport Number", type: .accountNumber, placeholder: "Passport number"),
            TemplateField(name: "Country", type: .text, placeholder: "Issuing country", inputHint: .country),
            TemplateField(name: "Expiration Date", type: .text, placeholder: "MM/YYYY", inputHint: .expiryDate),
            TemplateField(name: "Date of Birth", type: .text, placeholder: "MM/DD/YYYY", inputHint: .date),
            TemplateField(name: "Place of Birth", type: .text, placeholder: "City, Country")
        ]
    )

    static let bankAccount = SecretTemplate(
        name: "Bank Account",
        description: "Store your bank account details",
        category: .bankAccount,
        iconName: "building.columns.fill",
        fields: [
            TemplateField(name: "Bank Name", type: .text, placeholder: "Bank name"),
            TemplateField(name: "Account Number", type: .accountNumber, placeholder: "Account number", inputHint: .number),
            TemplateField(name: "Routing Number", type: .accountNumber, placeholder: "Routing number", inputHint: .number),
            TemplateField(name: "Account Type", type: .text, placeholder: "Checking / Savings")
        ]
    )

    static let creditCard = SecretTemplate(
        name: "Credit Card",
        description: "Store your credit card information",
        category: .creditCard,
        iconName: "creditcard.fill",
        fields: [
            TemplateField(name: "Card Number", type: .accountNumber, placeholder: "Card number", inputHint: .number),
            TemplateField(name: "Cardholder Name", type: .text, placeholder: "Name on card"),
            TemplateField(name: "Expiration Date", type: .text, placeholder: "MM/YYYY", inputHint: .expiryDate),
            TemplateField(name: "CVV", type: .pin, placeholder: "CVV", inputHint: .pin),
            TemplateField(name: "PIN", type: .pin, placeholder: "Card PIN", inputHint: .pin)
        ]
    )

    static let cryptoWallet = SecretTemplate(
        name: "Crypto Wallet",
        description: "Store your cryptocurrency wallet details with per-coin groups",
        category: .cryptocurrency,
        iconName: "bitcoinsign.circle.fill",
        fields: [
            TemplateField(name: "Wallet Name", type: .text, placeholder: "Wallet name"),
            TemplateField(name: "Seed Phrase", type: .seedPhrase, placeholder: "Recovery seed phrase", inputHint: .password),
            TemplateField(name: "Public Address", type: .publicKey, placeholder: "Wallet address"),
            TemplateField(name: "Coin Name", type: .text, placeholder: "e.g. Bitcoin, Ethereum"),
            TemplateField(name: "Coin Address", type: .publicKey, placeholder: "Coin-specific address"),
            TemplateField(name: "Derivation Path", type: .text, placeholder: "e.g. m/44'/0'/0'/0/0")
        ]
    )

    static let insurance = SecretTemplate(
        name: "Insurance",
        description: "Store your insurance policy details",
        category: .insurance,
        iconName: "shield.checkered",
        fields: [
            TemplateField(name: "Provider", type: .text, placeholder: "Insurance company"),
            TemplateField(name: "Policy Number", type: .accountNumber, placeholder: "Policy number"),
            TemplateField(name: "Group Number", type: .accountNumber, placeholder: "Group number"),
            TemplateField(name: "Expiration Date", type: .text, placeholder: "MM/YYYY", inputHint: .expiryDate)
        ]
    )

    static let socialSecurity = SecretTemplate(
        name: "Social Security",
        description: "Store your Social Security Number",
        category: .ssn,
        iconName: "number.square.fill",
        fields: [
            TemplateField(name: "SSN", type: .accountNumber, placeholder: "XXX-XX-XXXX", inputHint: .number)
        ]
    )

    static let wifiNetwork = SecretTemplate(
        name: "WiFi Network",
        description: "Store WiFi network credentials",
        category: .wifi,
        iconName: "wifi",
        fields: [
            TemplateField(name: "Network Name (SSID)", type: .text, placeholder: "Network name"),
            TemplateField(name: "Password", type: .password, placeholder: "WiFi password", inputHint: .password)
        ]
    )

    static let sshKey = SecretTemplate(
        name: "SSH Key",
        description: "Store your SSH key pair",
        category: .ssh,
        iconName: "terminal",
        fields: [
            TemplateField(name: "Key Name", type: .text, placeholder: "Key name or label"),
            TemplateField(name: "Private Key", type: .privateKey, placeholder: "Private key contents", inputHint: .password),
            TemplateField(name: "Public Key", type: .publicKey, placeholder: "Public key contents"),
            TemplateField(name: "Passphrase", type: .password, placeholder: "Key passphrase", inputHint: .password)
        ]
    )

    static let vpnConfiguration = SecretTemplate(
        name: "VPN Configuration",
        description: "Store your VPN connection details",
        category: .vpn,
        iconName: "network.badge.shield.half.filled",
        fields: [
            TemplateField(name: "VPN Name", type: .text, placeholder: "Connection name"),
            TemplateField(name: "Server", type: .text, placeholder: "Server address"),
            TemplateField(name: "Username", type: .text, placeholder: "Username"),
            TemplateField(name: "Password", type: .password, placeholder: "Password", inputHint: .password),
            TemplateField(name: "Protocol", type: .text, placeholder: "e.g. OpenVPN, WireGuard, IKEv2")
        ]
    )

    static let totpToken = SecretTemplate(
        name: "TOTP Token",
        description: "Store a time-based one-time password token",
        category: .totp,
        iconName: "clock.badge.checkmark",
        fields: [
            TemplateField(name: "Service Name", type: .text, placeholder: "Service or app name"),
            TemplateField(name: "Secret", type: .token, placeholder: "TOTP secret key", inputHint: .password),
            TemplateField(name: "Issuer", type: .text, placeholder: "Issuer name"),
            TemplateField(name: "Digits", type: .text, placeholder: "6", inputHint: .number),
            TemplateField(name: "Period", type: .text, placeholder: "30", inputHint: .number)
        ]
    )

    static let loyaltyCard = SecretTemplate(
        name: "Loyalty Card",
        description: "Store your loyalty or rewards program details",
        category: .loyalty,
        iconName: "giftcard",
        fields: [
            TemplateField(name: "Program Name", type: .text, placeholder: "Program or store name"),
            TemplateField(name: "Member Number", type: .accountNumber, placeholder: "Membership number"),
            TemplateField(name: "Tier", type: .text, placeholder: "Membership tier"),
            TemplateField(name: "Expiry Date", type: .text, placeholder: "MM/YYYY", inputHint: .expiryDate)
        ]
    )

    static let vehicleRegistration = SecretTemplate(
        name: "Vehicle Registration",
        description: "Store your vehicle registration details",
        category: .vehicle,
        iconName: "car.side",
        fields: [
            TemplateField(name: "Make", type: .text, placeholder: "Vehicle make"),
            TemplateField(name: "Model", type: .text, placeholder: "Vehicle model"),
            TemplateField(name: "Year", type: .text, placeholder: "Year", inputHint: .number),
            TemplateField(name: "VIN", type: .accountNumber, placeholder: "Vehicle identification number"),
            TemplateField(name: "License Plate", type: .text, placeholder: "Plate number"),
            TemplateField(name: "Registration Expiry", type: .text, placeholder: "MM/YYYY", inputHint: .expiryDate)
        ]
    )

    static let taxId = SecretTemplate(
        name: "Tax ID",
        description: "Store your tax identification number",
        category: .tax,
        iconName: "doc.text.fill",
        fields: [
            TemplateField(name: "Tax ID Type", type: .text, placeholder: "e.g. SSN, EIN, ITIN"),
            TemplateField(name: "Tax ID Number", type: .accountNumber, placeholder: "ID number", inputHint: .password),
            TemplateField(name: "Issuing Country", type: .text, placeholder: "Country", inputHint: .country)
        ]
    )

    static let allTemplates: [SecretTemplate] = [
        .driversLicense, .passport, .bankAccount, .creditCard,
        .cryptoWallet, .insurance, .socialSecurity, .wifiNetwork,
        .sshKey, .vpnConfiguration, .totpToken, .loyaltyCard,
        .vehicleRegistration, .taxId
    ]
}

// MARK: - Template Helper

extension SecretTemplate {
    /// Create a MinorSecret from this template with filled field values
    func createSecret(fieldValues: [String: String]) -> MinorSecret {
        let secretFields = fields.map { templateField in
            SecretField(
                name: templateField.name,
                value: fieldValues[templateField.name] ?? "",
                type: templateField.type,
                placeholder: templateField.placeholder,
                inputHint: templateField.inputHint
            )
        }

        return MinorSecret(
            name: name,
            category: category,
            type: .text,
            fields: secretFields,
            syncStatus: .pending
        )
    }
}
