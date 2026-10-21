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
    case help = "questionmark.circle" // HelpOutline

    // Actions
    case star = "star.fill" // Star
    case starOutline = "star" // StarOutline
    case edit = "square.and.pencil" // Edit
    case reply = "arrowshape.turn.up.left" // Reply
    case send = "paperplane" // Send (a message)
    case qrCode = "qrcode" // QrCode2
    case qrCodeScanner = "qrcode.viewfinder" // QrCodeScanner
    case personAdd = "person.badge.plus" // PersonAdd
    case personRemove = "person.badge.minus" // PersonRemove
    case contentCopy = "doc.on.doc" // ContentCopy
    case contentPaste = "doc.on.clipboard" // ContentPaste
    case share = "square.and.arrow.up" // Share
    case download = "square.and.arrow.down" // Download (save a photo to the phone)
    case image = "photo" // Image (a photo, the composer's photo button)
    case photoCamera = "camera" // PhotoCamera
    case cameraSwitch = "arrow.triangle.2.circlepath.camera" // Cameraswitch
    case zoomIn = "plus.magnifyingglass" // ZoomIn (the profile photo's round frame)
    case zoomOut = "minus.magnifyingglass" // ZoomOut
    case face = "face.smiling" // Face (the stand-in for the live camera)
    case delete = "trash" // Delete
    case show = "eye" // Visibility
    case hide = "eye.slash" // VisibilityOff

    // Settings rows
    case key = "key" // Key
    case verifiedUser = "checkmark.shield" // VerifiedUser
    case lock = "lock" // Lock
    case storage = "externaldrive" // Storage
    case lockOpen = "lock.open" // LockOpen
    case faceID = "faceid" // Fingerprint (the app lock with Face ID or Touch ID)
    case passcode = "circle.grid.3x3" // Pin (the app lock with the passcode)
    case timer = "timer" // Timer
    case schedule = "clock" // Schedule
    case pauseCircle = "pause.circle" // PauseCircleOutline
    case openInNew = "arrow.up.forward.square" // OpenInNew
    case tag = "number" // Tag
    case label = "tag" // Label (a tag of the Vault)
    case palette = "paintpalette" // Palette (a tag's colour)
    case add = "plus" // Add
    case check = "checkmark" // Check
    case update = "arrow.triangle.2.circlepath" // Update
    case systemUpdate = "arrow.down.circle" // SystemUpdate (a vault release update)
    case restore = "arrow.counterclockwise" // Restore
    case restartAlt = "arrow.counterclockwise.circle" // RestartAlt (a new credential)
    case devices = "laptopcomputer.and.iphone" // Devices
    case person = "person" // Person
    case badge = "person.text.rectangle" // Badge (the shared profile: an ID card)
    case email = "envelope" // Email
    case groups = "person.3" // Groups
    case cardMembership = "creditcard" // CardMembership
    case gavel = "building.columns" // Gavel
    case howToVote = "checkmark.rectangle" // HowToVote
    case password = "rectangle.and.pencil.and.ellipsis" // Password
    case shield = "shield" // Shield
    case sync = "arrow.2.circlepath" // Sync
    case lockClock = "lock.badge.clock" // LockClock
    case backup = "icloud.and.arrow.up" // Backup
    case screenshot = "camera.viewfinder" // Screenshot
    case darkMode = "moon" // DarkMode (the theme)
    case security = "lock.shield" // Security
    case privacyTip = "hand.raised" // PrivacyTip
    case keyboard = "keyboard" // Keyboard

    // The Notifications screen (feed kinds' icons and the rows' actions)
    case archive = "tray.and.arrow.down" // Archive
    case unarchive = "tray.and.arrow.up" // Unarchive
    case doneAll = "checklist.checked" // DoneAll
    case markRead = "envelope.open" // MarkEmailRead
    case markUnread = "envelope.badge" // MarkEmailUnread
    case block = "nosign" // Block
    case location = "mappin.and.ellipse" // LocationOn
    case agent = "cpu" // SmartToy
    case accountCircle = "person.crop.circle" // AccountCircle
    case eventNote = "list.bullet.rectangle" // EventNote
    case moreVert = "ellipsis.circle" // MoreVert

    // States
    case info = "info.circle" // Info
    case checkCircle = "checkmark.circle.fill" // CheckCircle
    case errorOutline = "exclamationmark.circle" // ErrorOutline
    case warning = "exclamationmark.triangle" // WarningAmber
    case reportProblem = "exclamationmark.octagon" // ReportProblem
    case radioUnchecked = "circle" // RadioButtonUnchecked
    case radioChecked = "largecircle.fill.circle" // RadioButtonChecked
    case checkBox = "checkmark.square.fill" // CheckBox
    case checkBoxOutline = "square" // CheckBoxOutlineBlank

    public var image: Image { Image(systemName: rawValue) }
}
