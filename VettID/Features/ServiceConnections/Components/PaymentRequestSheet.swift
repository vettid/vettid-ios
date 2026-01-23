import SwiftUI
import LocalAuthentication

/// Sheet displaying a payment request from a service
struct PaymentRequestSheet: View {
    let request: PaymentRequest
    @Binding var isPresented: Bool
    let onDecision: (PaymentDecision) async -> Void

    @State private var selectedMethod: PaymentMethod?
    @State private var isProcessing = false
    @State private var error: String?
    @State private var showingSuccess = false
    @State private var timeRemaining: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        NavigationView {
            if showingSuccess {
                paymentSuccessView
            } else {
                paymentFormView
            }
        }
        .onAppear {
            startExpirationTimer()
            // Pre-select first payment method if available
            if selectedMethod == nil, let first = request.availableMethods.first {
                selectedMethod = first
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
        .interactiveDismissDisabled(isProcessing)
    }

    // MARK: - Payment Form

    private var paymentFormView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    // Service header
                    serviceHeader

                    // Amount display
                    amountDisplay

                    // Subscription details if applicable
                    if let subscription = request.subscriptionDetails {
                        subscriptionCard(subscription)
                    }

                    Divider()
                        .padding(.horizontal)

                    // Payment methods
                    paymentMethodsSection

                    // Expiration
                    expirationBanner
                }
                .padding()
            }

            // Error message
            if let error = error {
                errorBanner(error)
            }

            // Action buttons
            actionButtons
                .padding()
                .background(Color(UIColor.systemBackground))
        }
        .navigationTitle("Payment Request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    isPresented = false
                }
                .disabled(isProcessing)
            }
        }
    }

    // MARK: - Service Header

    private var serviceHeader: some View {
        HStack(spacing: 16) {
            // Service logo
            if let logoUrl = request.serviceLogoUrl, let url = URL(string: logoUrl) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    servicePlaceholder
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                servicePlaceholder
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(request.serviceName)
                    .font(.headline)

                if request.domainVerified {
                    Label("Verified Merchant", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }

            Spacer()
        }
    }

    private var servicePlaceholder: some View {
        ZStack {
            Color(UIColor.secondarySystemBackground)
            Image(systemName: "building.2.fill")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Amount Display

    private var amountDisplay: some View {
        VStack(spacing: 8) {
            Text(request.formattedAmount)
                .font(.system(size: 48, weight: .bold, design: .rounded))

            Text(request.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let reference = request.reference {
                Text("Ref: \(reference)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Subscription Card

    private func subscriptionCard(_ subscription: SubscriptionDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.purple)
                Text("Subscription")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                detailRow(label: "Billing", value: subscription.billingPeriod.displayName)
                detailRow(label: "Amount", value: subscription.formattedAmount)
                if let nextBilling = subscription.nextBillingDate {
                    detailRow(label: "Next billing", value: nextBilling.formatted(date: .abbreviated, time: .omitted))
                }
                if subscription.canCancel {
                    Text("Cancel anytime")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.1))
        .cornerRadius(16)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }

    // MARK: - Payment Methods

    private var paymentMethodsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pay with")
                .font(.headline)

            if request.availableMethods.isEmpty {
                noPaymentMethodsView
            } else {
                ForEach(request.availableMethods) { method in
                    PaymentMethodRow(
                        method: method,
                        isSelected: selectedMethod?.id == method.id
                    ) {
                        selectedMethod = method
                    }
                }
            }

            // Add payment method link
            Button {
                // Navigate to add payment method
            } label: {
                Label("Add payment method", systemImage: "plus.circle")
                    .font(.subheadline)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noPaymentMethodsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "creditcard.trianglebadge.exclamationmark")
                .font(.title)
                .foregroundColor(.secondary)

            Text("No payment methods")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("Add Payment Method") {
                // Navigate to add payment method
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Expiration Banner

    private var expirationBanner: some View {
        HStack {
            Image(systemName: "clock")
                .foregroundColor(timeRemaining < 30 ? .red : .secondary)

            Text("Expires in \(formattedTimeRemaining)")
                .font(.caption)
                .foregroundColor(timeRemaining < 30 ? .red : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(timeRemaining < 30 ? Color.red.opacity(0.1) : Color(UIColor.tertiarySystemBackground))
        .cornerRadius(8)
    }

    private var formattedTimeRemaining: String {
        if timeRemaining <= 0 { return "Expired" }
        let minutes = Int(timeRemaining / 60)
        let seconds = Int(timeRemaining.truncatingRemainder(dividingBy: 60))
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button("Cancel") {
                Task {
                    await handleDecision(approved: false)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isProcessing || timeRemaining <= 0)

            Button {
                Task {
                    await handlePayment()
                }
            } label: {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text("Pay \(request.formattedAmount)")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedMethod == nil || isProcessing || timeRemaining <= 0)
        }
    }

    // MARK: - Success View

    private var paymentSuccessView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)

            VStack(spacing: 8) {
                Text("Payment Successful")
                    .font(.title2)
                    .fontWeight(.bold)

                Text(request.formattedAmount)
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)

                Text("Paid to \(request.serviceName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let method = selectedMethod {
                HStack {
                    Image(systemName: method.icon)
                    Text(method.displayName)
                    if let lastFour = method.lastFour {
                        Text("••••\(lastFour)")
                            .foregroundColor(.secondary)
                    }
                }
                .font(.subheadline)
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
            }

            Spacer()

            Button("Done") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .padding()
    }

    // MARK: - Actions

    private func startExpirationTimer() {
        timeRemaining = request.expiresAt.timeIntervalSinceNow

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            timeRemaining = request.expiresAt.timeIntervalSinceNow
            if timeRemaining <= 0 {
                timer?.invalidate()
            }
        }
    }

    private func handlePayment() async {
        guard let method = selectedMethod else { return }

        isProcessing = true
        error = nil

        // Require biometric authentication
        let context = LAContext()
        var authError: NSError?

        let canUseBiometrics = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &authError
        )

        let policy: LAPolicy = canUseBiometrics ?
            .deviceOwnerAuthenticationWithBiometrics :
            .deviceOwnerAuthentication

        do {
            let success = try await context.evaluatePolicy(
                policy,
                localizedReason: "Authenticate to pay \(request.formattedAmount) to \(request.serviceName)"
            )

            if success {
                // Process payment
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)

                // Show success state
                withAnimation {
                    showingSuccess = true
                }

                // Send decision
                await handleDecision(approved: true, method: method)
            } else {
                error = "Authentication failed"
                isProcessing = false
            }
        } catch {
            self.error = error.localizedDescription
            isProcessing = false
        }
    }

    private func handleDecision(approved: Bool, method: PaymentMethod? = nil) async {
        let decision = PaymentDecision(
            requestId: request.id,
            approved: approved,
            paymentMethodId: method?.id,
            decidedAt: Date()
        )

        await onDecision(decision)

        if !approved {
            isPresented = false
        }
    }
}

// MARK: - Payment Method Row

struct PaymentMethodRow: View {
    let method: PaymentMethod
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: method.icon)
                    .font(.title2)
                    .foregroundColor(method.type.color)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(method.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    if let lastFour = method.lastFour {
                        Text("••••\(lastFour)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(isSelected ? Color.blue.opacity(0.1) : Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Payment Types

/// Payment request from a service
struct PaymentRequest: Codable, Identifiable {
    let id: String
    let serviceId: String
    let serviceName: String
    let serviceLogoUrl: String?
    let domainVerified: Bool
    let amount: Decimal
    let currency: String
    let description: String
    let reference: String?
    let subscriptionDetails: SubscriptionDetails?
    let availableMethods: [PaymentMethod]
    let requestedAt: Date
    let expiresAt: Date

    var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currency) \(amount)"
    }

    enum CodingKeys: String, CodingKey {
        case id = "request_id"
        case serviceId = "service_id"
        case serviceName = "service_name"
        case serviceLogoUrl = "service_logo_url"
        case domainVerified = "domain_verified"
        case amount
        case currency
        case description
        case reference
        case subscriptionDetails = "subscription_details"
        case availableMethods = "available_methods"
        case requestedAt = "requested_at"
        case expiresAt = "expires_at"
    }
}

/// Subscription details for recurring payments
struct SubscriptionDetails: Codable {
    let billingPeriod: BillingPeriod
    let amount: Decimal
    let currency: String
    let nextBillingDate: Date?
    let canCancel: Bool

    var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currency) \(amount)"
    }

    enum CodingKeys: String, CodingKey {
        case billingPeriod = "billing_period"
        case amount
        case currency
        case nextBillingDate = "next_billing_date"
        case canCancel = "can_cancel"
    }
}

/// Billing period for subscriptions
enum BillingPeriod: String, Codable {
    case weekly
    case monthly
    case quarterly
    case yearly

    var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        }
    }
}

/// Payment method
struct PaymentMethod: Codable, Identifiable {
    let id: String
    let type: PaymentMethodType
    let displayName: String
    let lastFour: String?
    let expiryMonth: Int?
    let expiryYear: Int?
    let isDefault: Bool

    var icon: String {
        type.icon
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case displayName = "display_name"
        case lastFour = "last_four"
        case expiryMonth = "expiry_month"
        case expiryYear = "expiry_year"
        case isDefault = "is_default"
    }
}

/// Payment method types
enum PaymentMethodType: String, Codable {
    case card
    case bankAccount = "bank_account"
    case applePay = "apple_pay"
    case crypto

    var icon: String {
        switch self {
        case .card: return "creditcard.fill"
        case .bankAccount: return "building.columns.fill"
        case .applePay: return "applelogo"
        case .crypto: return "bitcoinsign.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .card: return .blue
        case .bankAccount: return .green
        case .applePay: return .primary
        case .crypto: return .orange
        }
    }
}

/// Payment decision
struct PaymentDecision: Codable {
    let requestId: String
    let approved: Bool
    let paymentMethodId: String?
    let decidedAt: Date

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case approved
        case paymentMethodId = "payment_method_id"
        case decidedAt = "decided_at"
    }
}

// MARK: - Preview

#if DEBUG
struct PaymentRequestSheet_Previews: PreviewProvider {
    static var previews: some View {
        PaymentRequestSheet(
            request: PaymentRequest(
                id: "pay-123",
                serviceId: "service-123",
                serviceName: "Example Store",
                serviceLogoUrl: nil,
                domainVerified: true,
                amount: 49.99,
                currency: "USD",
                description: "Premium subscription - First month",
                reference: "ORD-12345",
                subscriptionDetails: SubscriptionDetails(
                    billingPeriod: .monthly,
                    amount: 9.99,
                    currency: "USD",
                    nextBillingDate: Date().addingTimeInterval(86400 * 30),
                    canCancel: true
                ),
                availableMethods: [
                    PaymentMethod(
                        id: "pm-1",
                        type: .card,
                        displayName: "Visa",
                        lastFour: "4242",
                        expiryMonth: 12,
                        expiryYear: 2027,
                        isDefault: true
                    ),
                    PaymentMethod(
                        id: "pm-2",
                        type: .applePay,
                        displayName: "Apple Pay",
                        lastFour: nil,
                        expiryMonth: nil,
                        expiryYear: nil,
                        isDefault: false
                    )
                ],
                requestedAt: Date(),
                expiresAt: Date().addingTimeInterval(300)
            ),
            isPresented: .constant(true),
            onDecision: { _ in }
        )
    }
}
#endif
