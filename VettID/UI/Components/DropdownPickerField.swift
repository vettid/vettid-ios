import SwiftUI

// MARK: - Dropdown Picker Field

/// A generic dropdown picker for selecting from a list of options
struct DropdownPickerField<T: Hashable & CustomStringConvertible>: View {
    let label: String
    let options: [T]
    @Binding var selection: T
    var placeholder: String = "Select..."

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(option.description).tag(option)
            }
        }
    }
}

// MARK: - String Dropdown Picker

/// Simplified dropdown for String options
struct StringDropdownPicker: View {
    let label: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        Picker(label, selection: $selection) {
            Text("Select...").tag("")
            ForEach(options, id: \.self) { option in
                Text(option).tag(option)
            }
        }
    }
}

// MARK: - Country Picker

/// Pre-built country picker
struct CountryPicker: View {
    @Binding var selection: String

    private static let countries = [
        "United States", "Canada", "United Kingdom", "Australia",
        "Germany", "France", "Japan", "Brazil", "India", "Mexico",
        "Spain", "Italy", "Netherlands", "Sweden", "Switzerland",
        "South Korea", "Singapore", "New Zealand", "Ireland", "Norway"
    ].sorted()

    var body: some View {
        StringDropdownPicker(
            label: "Country",
            options: Self.countries,
            selection: $selection
        )
    }
}

// MARK: - US State Picker

/// Pre-built US state picker
struct USStatePicker: View {
    @Binding var selection: String

    private static let states = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
        "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
        "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
        "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
        "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY"
    ]

    var body: some View {
        StringDropdownPicker(
            label: "State",
            options: Self.states,
            selection: $selection
        )
    }
}

// MARK: - Preview

#Preview {
    Form {
        CountryPicker(selection: .constant("United States"))
        USStatePicker(selection: .constant("CA"))
    }
}
