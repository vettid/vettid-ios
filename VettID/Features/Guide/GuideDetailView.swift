import SwiftUI

// MARK: - Guide Detail View

struct GuideDetailView: View {
    let guide: GuideContent
    let onDismiss: () -> Void

    @State private var navigateToGuide: GuideId?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Icon header
                    HStack {
                        Spacer()
                        Image(systemName: guide.icon)
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)
                        Spacer()
                    }
                    .padding(.vertical)

                    // Content blocks
                    ForEach(Array(guide.blocks.enumerated()), id: \.offset) { _, block in
                        guideBlock(block)
                    }

                    // Got it button
                    Button(action: onDismiss) {
                        Text("Got it")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 24)
                }
                .padding()
            }
            .navigationTitle(guide.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
            }
            .sheet(item: $navigateToGuide) { guideId in
                GuideDetailView(
                    guide: GuideCatalog.guide(for: guideId),
                    onDismiss: { navigateToGuide = nil }
                )
            }
        }
    }

    @ViewBuilder
    private func guideBlock(_ block: GuideContentBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.top, 8)

        case .paragraph(let text):
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\u{2022}")
                            .foregroundStyle(.blue)
                        Text(item)
                            .font(.body)
                    }
                }
            }
            .padding(.leading, 4)

        case .navigation(let title, let destination):
            Button(action: { navigateToGuide = destination }) {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text(title)
                }
                .font(.body)
                .foregroundStyle(.blue)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Guide List View

struct GuideListView: View {
    @State private var selectedGuide: GuideId?

    var body: some View {
        List(GuideCatalog.allGuides) { guide in
            Button(action: { selectedGuide = guide }) {
                HStack(spacing: 12) {
                    Image(systemName: guide.icon)
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                        .frame(width: 28)

                    Text(guide.title)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Guides")
        .sheet(item: $selectedGuide) { guideId in
            GuideDetailView(
                guide: GuideCatalog.guide(for: guideId),
                onDismiss: { selectedGuide = nil }
            )
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        GuideListView()
    }
}
