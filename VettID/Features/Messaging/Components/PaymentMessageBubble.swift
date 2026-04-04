import SwiftUI

/// Renders BTC-related message content inside a conversation bubble.
struct PaymentMessageBubble: View {

    let contentType: MessageContentType
    let content: String
    let isFromMe: Bool
    var onPayRequest: ((PaymentRequest) -> Void)?

    var body: some View {
        switch contentType {
        case .btcAddress:
            btcAddressBubble
        case .paymentRequest:
            paymentRequestBubble
        case .btcPaymentReceipt:
            paymentReceiptBubble
        default:
            EmptyView()
        }
    }

    // MARK: - BTC Address

    private var btcAddressBubble: some View {
        VStack(spacing: 8) {
            if let address = parseBtcAddress() {
                QRCodeView(data: address.address, size: 120)

                Text(address.address)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let label = address.label {
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Copy Address") {
                    SecurePasteboard.copySecure(address.address, expiresIn: 30)
                }
                .font(.caption)
                .buttonStyle(.bordered)
            } else {
                Text("Unable to display address")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
    }

    // MARK: - Payment Request

    private var paymentRequestBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let request = parsePaymentRequest() {
                Label("Payment Request", systemImage: "bitcoinsign.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.orange)

                Text(String(format: "%.8f BTC", request.amountBtc))
                    .font(.headline.weight(.bold))

                Text("\(request.amountSats) sats")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let memo = request.memo, !memo.isEmpty {
                    Text(memo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !isFromMe {
                    Button("Pay") {
                        onPayRequest?(request)
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
                }
            } else {
                Text("Unable to display payment request")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
    }

    // MARK: - Payment Receipt

    private var paymentReceiptBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let receipt = parsePaymentReceipt() {
                Label("Payment Sent", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.green)

                Text(String(format: "%.8f BTC", receipt.amountBtc))
                    .font(.subheadline.weight(.bold))

                HStack {
                    Text("Fee:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(receipt.feeSats) sats")
                        .font(.caption)
                }

                Text(receipt.txid)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button("Copy TXID") {
                    SecurePasteboard.copySecure(receipt.txid, expiresIn: 30)
                }
                .font(.caption2)
            } else {
                Text("Unable to display payment receipt")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
    }

    // MARK: - Parsing

    private func parseBtcAddress() -> BtcAddress? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BtcAddress.self, from: data)
    }

    private func parsePaymentRequest() -> PaymentRequest? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PaymentRequest.self, from: data)
    }

    private func parsePaymentReceipt() -> BtcPaymentReceipt? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BtcPaymentReceipt.self, from: data)
    }
}
