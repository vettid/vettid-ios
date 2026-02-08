import SwiftUI

// MARK: - Phone Number Input

/// Phone number input field with formatting
struct PhoneNumberInput: View {
    let label: String
    @Binding var phoneNumber: String
    var placeholder: String = "(555) 123-4567"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $phoneNumber)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .onChange(of: phoneNumber) { newValue in
                    phoneNumber = formatPhoneNumber(newValue)
                }
        }
    }

    /// Format phone number as (XXX) XXX-XXXX
    private func formatPhoneNumber(_ input: String) -> String {
        let digits = input.filter { $0.isNumber }
        var result = ""

        for (index, char) in digits.enumerated() {
            switch index {
            case 0:
                result.append("(")
                result.append(char)
            case 2:
                result.append(char)
                result.append(") ")
            case 5:
                result.append(char)
                result.append("-")
            case 9:
                result.append(char)
                // Stop at 10 digits
                return result
            default:
                result.append(char)
            }

            if index >= 9 { break }
        }

        return result
    }
}

// MARK: - Preview

#Preview {
    Form {
        PhoneNumberInput(
            label: "Phone Number",
            phoneNumber: .constant("(555) 123-4567")
        )
    }
}
