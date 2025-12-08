import Foundation
import BackgroundTasks
import Network

/// Background task scheduler for automatic backups
final class BackupBackgroundTask {

    // MARK: - Constants

    static let identifier = "dev.vettid.backup"
    private static let settingsKey = "BackupSettings"

    // MARK: - Shared Instance

    static let shared = BackupBackgroundTask()

    // MARK: - Properties

    private let pathMonitor = NWPathMonitor()
    private var isOnWifi = false

    // MARK: - Initialization

    private init() {
        setupNetworkMonitoring()
    }

    // MARK: - Registration

    /// Register the background task with the system
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            shared.handleBackupTask(processingTask)
        }
    }

    // MARK: - Scheduling

    /// Schedule the next backup based on settings
    func schedule(settings: BackupSettings) {
        guard settings.autoBackupEnabled else {
            cancel()
            return
        }

        let request = BGProcessingTaskRequest(identifier: BackupBackgroundTask.identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        // Calculate next backup time
        request.earliestBeginDate = calculateNextBackupDate(settings)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("Scheduled backup task for: \(request.earliestBeginDate?.description ?? "unknown")")
        } catch {
            print("Failed to schedule backup task: \(error)")
        }

        // Save settings for task handler
        saveSettings(settings)
    }

    /// Cancel scheduled backup
    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackupBackgroundTask.identifier)
    }

    // MARK: - Task Handling

    private func handleBackupTask(_ task: BGProcessingTask) {
        // Load settings
        guard let settings = loadSettings() else {
            task.setTaskCompleted(success: false)
            return
        }

        // Check WiFi requirement
        if settings.wifiOnly && !isOnWifi {
            // Reschedule for later
            schedule(settings: settings)
            task.setTaskCompleted(success: false)
            return
        }

        // Set expiration handler
        task.expirationHandler = {
            // Clean up if needed
        }

        // Perform backup
        Task {
            let success = await performBackup(includeMessages: settings.includeMessages)

            // Schedule next backup
            schedule(settings: settings)

            task.setTaskCompleted(success: success)
        }
    }

    /// Perform the actual backup
    private func performBackup(includeMessages: Bool) async -> Bool {
        // This would need access to auth token provider
        // In practice, you'd retrieve stored credentials
        // For now, return success as placeholder
        return true
    }

    // MARK: - Date Calculation

    /// Calculate the next backup date based on settings
    private func calculateNextBackupDate(_ settings: BackupSettings) -> Date {
        let calendar = Calendar.current
        var dateComponents = DateComponents()

        // Parse backup time
        let timeParts = settings.backupTimeUtc.split(separator: ":")
        if timeParts.count == 2 {
            dateComponents.hour = Int(timeParts[0])
            dateComponents.minute = Int(timeParts[1])
        } else {
            dateComponents.hour = 3
            dateComponents.minute = 0
        }

        // Find next occurrence
        var nextDate = calendar.nextDate(
            after: Date(),
            matching: dateComponents,
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(86400)

        // Adjust for frequency
        switch settings.backupFrequency {
        case .daily:
            break // Already set for next day

        case .weekly:
            // Find next Sunday at specified time
            if let weekday = calendar.dateComponents([.weekday], from: nextDate).weekday, weekday != 1 {
                let daysUntilSunday = (8 - weekday) % 7
                nextDate = calendar.date(byAdding: .day, value: daysUntilSunday, to: nextDate) ?? nextDate
            }

        case .monthly:
            // First day of next month at specified time
            if let month = calendar.dateComponents([.month, .year], from: nextDate).month,
               let year = calendar.dateComponents([.month, .year], from: nextDate).year {
                var components = DateComponents()
                components.year = year
                components.month = month + 1
                components.day = 1
                components.hour = dateComponents.hour
                components.minute = dateComponents.minute
                if let date = calendar.date(from: components) {
                    nextDate = date
                }
            }
        }

        return nextDate
    }

    // MARK: - Network Monitoring

    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.isOnWifi = path.usesInterfaceType(.wifi)
        }
        pathMonitor.start(queue: DispatchQueue.global())
    }

    // MARK: - Settings Persistence

    private func saveSettings(_ settings: BackupSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: BackupBackgroundTask.settingsKey)
        }
    }

    private func loadSettings() -> BackupSettings? {
        guard let data = UserDefaults.standard.data(forKey: BackupBackgroundTask.settingsKey),
              let settings = try? JSONDecoder().decode(BackupSettings.self, from: data) else {
            return nil
        }
        return settings
    }
}

// MARK: - App Delegate Integration

extension BackupBackgroundTask {

    /// Call from AppDelegate didFinishLaunchingWithOptions
    static func setup() {
        register()
    }

    /// Schedule backup when settings change
    static func updateSchedule(with settings: BackupSettings) {
        shared.schedule(settings: settings)
    }
}
