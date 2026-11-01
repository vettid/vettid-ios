import Foundation

/// Background time from the system (on the iPhone, `UIApplication.beginBackgroundTask`), so that this package does not
/// call UIKit: the app supplies it, tests supply a fake.
public protocol BackgroundTasks: Sendable {
    /// Asks for time to finish work after the app left the foreground. [expiration] runs when the system takes the time
    /// back: it must end the task and start nothing. Returns the task's token; nil when the system gave none.
    @MainActor func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int?
    /// Ends a task begun by ``begin(name:expiration:)``. Called once per token.
    @MainActor func end(_ token: Int)
}
