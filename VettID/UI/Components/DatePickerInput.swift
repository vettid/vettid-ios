import SwiftUI

// MARK: - Date Picker Input

/// A date input field that supports MM/DD/YYYY format
struct DatePickerInput: View {
    let label: String
    @Binding var dateString: String
    var placeholder: String = "MM/DD/YYYY"

    @State private var showDatePicker = false
    @State private var selectedDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField(placeholder, text: $dateString)
                    .keyboardType(.numbersAndPunctuation)
                    .onChange(of: dateString) { newValue in
                        dateString = formatDateInput(newValue)
                    }

                Button {
                    if let date = parseDate(dateString) {
                        selectedDate = date
                    }
                    showDatePicker.toggle()
                } label: {
                    Image(systemName: "calendar")
                        .foregroundStyle(.blue)
                }
            }

            if showDatePicker {
                DatePicker(
                    "",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .onChange(of: selectedDate) { newDate in
                    let formatter = DateFormatter()
                    formatter.dateFormat = "MM/dd/yyyy"
                    dateString = formatter.string(from: newDate)
                    showDatePicker = false
                }
            }
        }
    }

    /// Auto-format date input as user types (inserts slashes)
    private func formatDateInput(_ input: String) -> String {
        let digits = input.filter { $0.isNumber }
        var result = ""

        for (index, char) in digits.enumerated() {
            if index == 2 || index == 4 {
                result.append("/")
            }
            if index >= 8 { break }
            result.append(char)
        }

        return result
    }

    private func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.date(from: string)
    }
}

// MARK: - Preview

#Preview {
    Form {
        DatePickerInput(
            label: "Date of Birth",
            dateString: .constant("01/15/1990")
        )
    }
}
