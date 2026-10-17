import SwiftUI

/// The SF Symbols that stand in for the Material Icons Outlined of the Android app (IOS-PLAN §3): one glyph per
/// meaning, named after the Material icon it replaces. Add a case here rather than naming a symbol in a screen.
public enum VettIDSymbol: String, CaseIterable, Sendable {
    // Navigation and bars
    case menu = "line.3.horizontal" // Menu
    case back = "chevron.backward" // ArrowBack (iOS back chevron)
    case search = "magnifyingglass" // Search
    case close = "xmark" // Close
    case notifications = "bell" // Notifications
    case chevronForward = "chevron.forward" // KeyboardArrowRight
    case moreHoriz = "ellipsis" // MoreHoriz

    // Destinations
    case messages = "bubble.left" // ChatBubbleOutline
    case connections = "person.2" // People
    case approvals = "checkmark.circle" // TaskAlt
    case vault = "archivebox" // Inventory2
    case history = "clock.arrow.circlepath" // History
    case settings = "gearshape" // Settings

    // Actions
    case star = "star.fill" // Star
    case starOutline = "star" // StarOutline
    case edit = "square.and.pencil" // Edit
    case reply = "arrowshape.turn.up.left" // Reply
    case qrCode = "qrcode" // QrCode2
    case delete = "trash" // Delete
    case show = "eye" // Visibility
    case hide = "eye.slash" // VisibilityOff

    // Settings rows
    case key = "key" // Key
    case verifiedUser = "checkmark.shield" // VerifiedUser
    case lock = "lock" // Lock
    case storage = "externaldrive" // Storage

    // States
    case info = "info.circle" // Info
    case checkCircle = "checkmark.circle.fill" // CheckCircle
    case errorOutline = "exclamationmark.circle" // ErrorOutline
    case warning = "exclamationmark.triangle" // WarningAmber
    case reportProblem = "exclamationmark.octagon" // ReportProblem
    case radioUnchecked = "circle" // RadioButtonUnchecked

    public var image: Image { Image(systemName: rawValue) }
}
