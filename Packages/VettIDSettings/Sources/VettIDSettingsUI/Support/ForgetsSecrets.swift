#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// IOS-PLAN §6.3: typed secrets are dropped when the screen goes, when the app leaves the foreground, and when the
    /// iPhone locks.
    func forgetsSecrets(scenePhase: ScenePhase, _ forget: @escaping @MainActor () -> Void) -> some View {
        onDisappear { forget() }
            .onChange(of: scenePhase) { _, now in if now == .background { forget() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                forget()
            }
    }
}
#endif
