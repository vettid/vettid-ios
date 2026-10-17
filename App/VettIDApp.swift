import SwiftUI

@main
struct VettIDApp: App {
    var body: some Scene {
        WindowGroup {
            SkeletonView(environment: .current)
        }
    }
}

/// Placeholder until the screens of IOS-PLAN §4 arrive.
struct SkeletonView: View {
    let environment: AppEnvironment

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: "VettID")
                .font(.largeTitle.bold())
            Text(verbatim: environment.kind.rawValue)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
