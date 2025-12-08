import SwiftUI

/// View for executing a handler with dynamic input form
struct HandlerExecutionView: View {
    let handler: HandlerDetailResponse
    let authTokenProvider: () -> String?

    @StateObject private var viewModel: HandlerExecutionViewModel
    @Environment(\.dismiss) private var dismiss

    init(handler: HandlerDetailResponse, authTokenProvider: @escaping () -> String?) {
        self.handler = handler
        self.authTokenProvider = authTokenProvider
        self._viewModel = StateObject(wrappedValue: HandlerExecutionViewModel(authTokenProvider: authTokenProvider))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Handler info header
                    handlerHeader

                    Divider()

                    // Dynamic input form
                    DynamicInputForm(
                        schema: handler.inputSchema,
                        values: $viewModel.inputValues
                    )

                    // Execute button
                    executeButton

                    // Result display
                    if let result = viewModel.result {
                        ExecutionResultView(result: result)
                    }

                    // Error display
                    if let error = viewModel.errorMessage, viewModel.result == nil {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Execute Handler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var handlerHeader: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: handler.iconUrl ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                default:
                    Image(systemName: "cube.box")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(Color(.systemGray6))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(handler.name)
                    .font(.headline)
                Text("v\(handler.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var executeButton: some View {
        Button(action: {
            Task {
                await viewModel.execute(handlerId: handler.id)
            }
        }) {
            if viewModel.isExecuting {
                HStack {
                    ProgressView()
                        .tint(.white)
                    Text("Executing...")
                }
                .frame(maxWidth: .infinity)
            } else {
                Label("Execute", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(viewModel.isExecuting)
    }
}

// MARK: - Dynamic Input Form

struct DynamicInputForm: View {
    let schema: [String: AnyCodableValue]
    @Binding var values: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if schema.isEmpty {
                Text("No input required")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                Text("Input")
                    .font(.headline)

                ForEach(sortedFields, id: \.key) { field in
                    DynamicInputField(
                        key: field.key,
                        schema: field.value,
                        value: Binding(
                            get: { values[field.key] ?? "" },
                            set: { values[field.key] = $0 }
                        )
                    )
                }
            }
        }
    }

    private var sortedFields: [(key: String, value: AnyCodableValue)] {
        schema.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
    }
}

// MARK: - Dynamic Input Field

struct DynamicInputField: View {
    let key: String
    let schema: AnyCodableValue
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formatLabel(key))
                .font(.subheadline)
                .fontWeight(.medium)

            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)

            if let description = fieldDescription {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatLabel(_ key: String) -> String {
        // Convert snake_case or camelCase to Title Case
        key.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    private var placeholder: String {
        // Try to get placeholder from schema
        if let dict = schema.value as? [String: Any],
           let placeholder = dict["placeholder"] as? String {
            return placeholder
        }
        return "Enter \(formatLabel(key).lowercased())"
    }

    private var fieldDescription: String? {
        if let dict = schema.value as? [String: Any],
           let desc = dict["description"] as? String {
            return desc
        }
        return nil
    }
}

// MARK: - Execution Result View

struct ExecutionResultView: View {
    let result: ExecuteHandlerResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status header
            HStack {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)

                Text(result.status.capitalized)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(result.executionTimeMs)ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Output
            if let output = result.output, !output.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(formatOutput(output))
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(4)
                    }
                }
            }

            // Error
            if let error = result.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Error")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var statusIcon: String {
        switch result.status {
        case "success": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        case "timeout": return "clock.badge.exclamationmark"
        default: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch result.status {
        case "success": return .green
        case "error": return .red
        case "timeout": return .orange
        default: return .secondary
        }
    }

    private func formatOutput(_ output: [String: AnyCodableValue]) -> String {
        // Convert to pretty-printed JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(output),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "Unable to display output"
    }
}

// MARK: - Previews

#if DEBUG
struct HandlerExecutionView_Previews: PreviewProvider {
    static var previews: some View {
        Text("HandlerExecutionView Preview")
    }
}
#endif
