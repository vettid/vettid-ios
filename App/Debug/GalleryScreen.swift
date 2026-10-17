#if DEBUG
import SwiftUI
import VettIDUI

/// Debug-only component gallery: every VettIDUI component with sample data, in the current theme. Sample text is
/// hard-coded on purpose (never shipped: Debug and DevStack only, and the release check refuses its title).
/// Mirrors vettid-android `app/src/debugTools/…/GalleryScreen.kt`, section by section.
struct GalleryScreen: View {
    @Binding var themeMode: ThemeMode
    let onBack: @MainActor () -> Void

    @Environment(\.vettIDColors) private var colors
    @State private var showSheet = false
    @State private var showDialog = false
    @State private var favorites: Set<String> = ["Bob Okafor"]
    @State private var unread = false
    @State private var lockOn = true
    @State private var query = "pass"
    @State private var searchOpen = true

    var body: some View {
        DetailScaffold(onBack: onBack) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LargeTitle("Component gallery")
                    WrapLayout(spacing: Spacing.s) {
                        ForEach(ThemeMode.allCases, id: \.self) { mode in
                            VettIDFilterChip(mode.rawValue.capitalized, selected: mode == themeMode) { themeMode = mode }
                        }
                    }
                    .padding(.horizontal, Spacing.gutter)

                    brand
                    typography

                    section("Top app bar")
                    frame {
                        VettIDTopAppBar(title: "Messages", accountName: "Mesmer", onMenu: {}, onAvatar: {}, onSearch: {})
                    }

                    section("Notifications bell (0.1.23): none, 3 unread, urgent")
                    frame {
                        VStack(spacing: 0) {
                            ForEach([(0, false), (3, false), (2, true)], id: \.0) { n, urgent in
                                VettIDTopAppBar(
                                    title: "Messages",
                                    accountName: "Mesmer",
                                    bell: NotificationBell(unread: n, urgent: urgent) {},
                                    onMenu: {},
                                    onAvatar: {}
                                )
                            }
                        }
                    }

                    section("Top bar search")
                    frame {
                        SearchTopBar(
                            TopBarSearchState(
                                query: $query,
                                opened: $searchOpen,
                                label: "Search your vault",
                                placeholder: "Search by name or tag"
                            ),
                            autoFocus: false
                        )
                    }

                    section("Navigation drawer")
                    VettIDDrawerSheet(
                        sections: [
                            [
                                DrawerItem(key: "m", label: "Messages", icon: .messages),
                                DrawerItem(key: "c", label: "Connections", icon: .connections),
                                DrawerItem(key: "a", label: "Approvals", icon: .approvals, badge: 3),
                            ],
                            [
                                DrawerItem(key: "i", label: "Vault", icon: .vault),
                                DrawerItem(key: "h", label: "History", icon: .history),
                            ],
                            [DrawerItem(key: "s", label: "Settings", icon: .settings)],
                        ],
                        selectedKey: "m",
                        versionLabel: "VettID 2.0.0-a0 (100)"
                    ) { _ in }
                    .frame(height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, Spacing.gutter)

                    section("List rows")
                    ForEach(Array(Self.sampleRows.enumerated()), id: \.offset) { i, row in
                        VettIDListRow(title: row.0, supporting: row.1, meta: row.2, emphasized: i == 0, onTap: {})
                    }

                    section("Connection rows (star = favourite)")
                    ForEach(Self.sampleConnections, id: \.0) { name, status in
                        ConnectionRow(
                            name: name,
                            favorite: favorites.contains(name),
                            supporting: status,
                            onFavoriteChange: { fav in
                                if fav { favorites.insert(name) } else { favorites.remove(name) }
                            },
                            onTap: {}
                        )
                    }

                    section("Empty state + floating controls")
                    frame(height: 460) {
                        EmptyState(
                            icon: .messages,
                            title: "No messages",
                            message: "Conversations with your connections appear here"
                        )
                        // Room for the floating controls, as a list screen leaves under its content.
                        .padding(.bottom, 88)
                        .overlay(alignment: .bottom) {
                            BottomFloatingControls {
                                FloatingFilterChip("Unread", selected: $unread)
                            } trailing: {
                                VettIDFab(.edit, label: "New message") {}
                            }
                        }
                    }

                    detailSample
                    settingsSample

                    section("Avatar sheet")
                    AvatarSheetContent(name: "Mesmer", detail: "mesmer@vettid.org", optionsHeader: "Options") {
                        SettingsGroup {
                            SettingsRow("Lock vault", icon: .lock, showChevron: false) {}
                            SettingsDivider()
                            SettingsRow("Open account portal", icon: .settings, showChevron: false) {}
                        }
                    }
                    .frame(height: 420)
                    .background(colors.groupedBackground, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
                    .padding(.horizontal, Spacing.gutter)

                    section("Forms (A3): strength meter, buttons")
                    forms

                    section("Notices, steps and the urgent banner (A3)")
                    notices

                    section("Conversation (A4): day divider, bubbles")
                    DayDivider("4 Oct 2026")
                    MessageBubble(
                        "Are we still on for Saturday?",
                        outgoing: false,
                        meta: "09:12",
                        accessibilityLabel: "Sam: Are we still on for Saturday? 09:12"
                    )
                    MessageBubble(
                        "Yes, 10am at the market.",
                        outgoing: true,
                        meta: "09:14 · Read",
                        accessibilityLabel: "You: Yes, 10am at the market. 09:14, Read"
                    )

                    section("Invitation QR code and safety code (A4)")
                    VStack(spacing: Spacing.l) {
                        QrCode(Self.galleryQR, accessibilityLabel: "Sample QR code", size: 200)
                        SafetyCode("042817")
                    }
                    .frame(maxWidth: .infinity)

                    badges
                    Spacer().frame(height: Spacing.xxxl * 2)
                }
            }
        }
        .avatarSheet(isPresented: $showSheet) {
            AvatarSheetContent(name: "Mesmer", detail: "mesmer@vettid.org", optionsHeader: "Options") {
                SettingsGroup {
                    SettingsRow("Lock vault", icon: .lock, showChevron: false) {}
                }
            }
        }
        .confirmDialog(
            isPresented: $showDialog,
            title: "Remove Alice?",
            message: "Alice will no longer be able to message you or read what you share.",
            confirmLabel: "Remove",
            destructive: true
        ) {}
        .accessibilityIdentifier("component_gallery")
    }

    // MARK: Sections

    private var brand: some View {
        Group {
            section("Brand and colour")
            HStack(spacing: Spacing.xl) {
                RookLogo(height: 48)
                // Follows the theme: gold wordmark on dark, the kit's on-light file (blue wordmark) on light.
                VettIDLogo()
            }
            .padding(.horizontal, Spacing.gutter)
            Spacer().frame(height: Spacing.l)
            swatches
        }
    }

    private var typography: some View {
        Group {
            section("Typography")
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Headline · Plus Jakarta Sans").vettIDFont(.headlineMedium)
                Text(verbatim: "Title · Messages").vettIDFont(.titleLarge)
                Text(verbatim: "Body large · Inter, list title 16pt").vettIDFont(.bodyLarge)
                Text(verbatim: "Body medium · preview line, 14pt").vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
                Text(verbatim: "Label · chips and buttons").vettIDFont(.labelLarge)
            }
            .padding(.horizontal, Spacing.gutter)
        }
    }

    private var detailSample: some View {
        Group {
            section("Detail screen")
            frame(height: 520) {
                VStack(spacing: 0) {
                    VettIDBackTopBar(onBack: {}) {
                        IconButton(.starOutline, label: "Star") {}
                    }
                    CenteredTitle("Dinner on Friday")
                    DetailCard {
                        // Tile, sender and date in a row, or the sender under the tile at the largest text sizes.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Spacing.l) {
                                InitialTile("Alice Moreau", size: 40)
                                sender.fixedSize()
                                Spacer(minLength: Spacing.s)
                                date
                            }
                            VStack(alignment: .leading, spacing: Spacing.s) {
                                HStack { InitialTile("Alice Moreau", size: 40); Spacer(); date }
                                sender
                            }
                        }
                        Spacer().frame(height: Spacing.l)
                        Text(verbatim: "Are we still on for Friday? I booked a table for eight.").vettIDFont(.bodyLarge)
                    }
                    // Room for the pill bar, as a detail screen leaves under its content.
                    Spacer(minLength: 88)
                }
                .overlay(alignment: .bottom) {
                    FloatingPillActionBar([
                        PillAction(.reply, label: "Reply") {},
                        PillAction(.qrCode, label: "Show safety code") {},
                        PillAction(.delete, label: "Delete") { showDialog = true },
                        PillAction(.moreHoriz, label: "More") {},
                    ])
                }
            }
        }
    }

    private var sender: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "Alice Moreau").vettIDFont(.bodyLarge)
            Text(verbatim: "Connection · verified").vettIDFont(.bodyMedium).foregroundStyle(colors.onSurfaceVariant)
        }
    }

    private var date: some View {
        Text(verbatim: "Oct 3").vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
    }

    private var settingsSample: some View {
        Group {
            section("Settings groups")
            VStack(spacing: 0) {
                SettingsGroup {
                    SettingsAccountRow(name: "Mesmer", detail: "mesmer@vettid.org") {}
                    SettingsDivider()
                    SettingsRow("Pair a device", icon: .qrCode) {}
                    SettingsDivider()
                    SettingsRow("Credential password", icon: .key) {}
                }
                SettingsSectionHeader("Security")
                SettingsGroup {
                    SettingsRow("Attestation", icon: .verifiedUser, tag: "New") {}
                    SettingsDivider()
                    SettingsSwitchRow("Biometric app lock", isOn: $lockOn, icon: .lock)
                    SettingsDivider()
                    SettingsRow("Vault status", icon: .storage, supporting: "Running · release 2026.10.1") {}
                }
            }
            .padding(.vertical, Spacing.s)
            .background(colors.groupedBackground)
        }
    }

    private var forms: some View {
        VStack(spacing: Spacing.m) {
            StrengthMeter(level: 1, label: "Weak")
            StrengthMeter(level: 3, label: "Good")
            PasswordRuleLine("Use at least 12 characters.", passes: false, hint: "Three or four unrelated words work well.")
            PasswordRuleLine("Strong enough.", passes: true)
            PrimaryButton("Primary action") {}
            PrimaryButton("Busy", busy: true) {}
            PrimaryButton("Delete my vault", destructive: true) {}
            SecondaryButton("Secondary action") {}
        }
        .padding(.horizontal, Spacing.gutter)
    }

    private var notices: some View {
        VStack(spacing: Spacing.m) {
            UrgentBanner("Your credential was presented by another device", actionLabel: "Review") {}
            InfoBanner("The vault service is paused for maintenance. Try again later.")
            InfoBanner("A new vault release is available (release 5).", actionLabel: "Update now", onDismiss: {})
            VStack(spacing: Spacing.m) {
                ForEach(NoticeKind.allCases, id: \.self) { k in
                    NoticeCard(k, title: "Notice: \(String(describing: k))", message: "One or two lines of explanation.")
                }
                StepList([
                    ("Verifying the vault service", .done),
                    ("Creating your vault", .active),
                    ("Connecting securely", .pending),
                    ("Confirming", .failed),
                ])
            }
            .padding(.horizontal, Spacing.gutter)
            SettingsGroup {
                SettingsInfoRow("Info row", value: "A read-only value")
            }
        }
    }

    private var badges: some View {
        Group {
            section("Badges, tags, tiles, buttons")
            WrapLayout(spacing: Spacing.m) {
                CountBadge(3)
                CountBadge(120)
                TagLabel("New")
                InitialTile("Alice", size: 40)
                InitialTile("Bob", size: 40, style: .favorite)
                InitialTile("Mesmer", size: 40, style: .ownAccount)
                // A non-person row (History) and a shared profile photo (§10.8; an unreadable one shows the initial).
                InitialTile("History", size: 40, icon: .history)
                InitialTile("Photo", size: 40, style: .ownAccount, photo: ProfilePhotos.decode(Self.galleryPhoto))
                InitialTile("Broken", size: 40, photo: ProfilePhotos.decode("bm90IGFuIGltYWdl"))
            }
            .padding(.horizontal, Spacing.gutter)
            Spacer().frame(height: Spacing.l)
            // Item tags in their own colours (one per tag, `@profile` gold), a removable tag, "✕ Clear" and a top bar
            // text action.
            WrapLayout(spacing: Spacing.s) {
                TagChip("Shared profile", tag: "@profile")
                ForEach(["travel", "money", "medical", "identity", "crypto", "family", "work", "home", "car", "school"], id: \.self) {
                    TagChip($0)
                }
                RemovableTagChip("travel", tag: "travel", removeLabel: "Remove tag travel") {}
                ClearFiltersChip {}
                TopBarTextAction("Save item") {}
                TopBarTextAction("Save item", busy: true) {}
            }
            .padding(.horizontal, Spacing.gutter)
            FilterChipRow(filtering: true, onClear: {}) {
                ForEach(["Standard", "Secret", "Critical", "Category", "Tag"], id: \.self) { label in
                    VettIDFilterChip(label, selected: label == "Secret") {}
                }
            }
            Spacer().frame(height: Spacing.l)
            // Side by side, or one above the other at the largest text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.m) { sheetButtons }
                VStack(spacing: Spacing.m) { sheetButtons }
            }
            .padding(.horizontal, Spacing.gutter)
        }
    }

    @ViewBuilder
    private var sheetButtons: some View {
        PrimaryButton("Open sheet") { showSheet = true }.fixedSize(horizontal: true, vertical: false)
        SecondaryButton("Confirm dialog") { showDialog = true }.fixedSize(horizontal: true, vertical: false)
    }

    private var swatches: some View {
        let c = colors
        let all: [(String, ThemeColor)] = [
            ("screen", c.background), ("drawer", c.surfaceContainerLow), ("grouped", c.groupedBackground),
            ("card", c.card), ("container", c.surfaceContainer), ("high", c.surfaceContainerHigh),
            ("gold fill", c.primaryContainer), ("gold content", c.primary), ("tile", c.tile),
            ("favourite", c.favoriteTile), ("error", c.error), ("outline", c.outline),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 4), spacing: Spacing.s) {
            ForEach(all, id: \.0) { name, color in
                VStack(alignment: .leading, spacing: 0) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(c.outline, lineWidth: 1))
                        .frame(height: 44)
                    Text(verbatim: name).vettIDFont(.labelSmall).foregroundStyle(c.onSurfaceVariant)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
            }
        }
        .padding(.horizontal, Spacing.gutter)
    }

    // MARK: Helpers

    private func section(_ title: String) -> some View {
        Text(title)
            .vettIDFont(.titleSmall)
            .foregroundStyle(colors.primary)
            .padding(.leading, Spacing.gutter + Spacing.xs)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.m)
    }

    private func frame<Content: View>(height: CGFloat? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(minHeight: height)
            .background(colors.background)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(colors.outline, lineWidth: 1))
            .padding(.horizontal, Spacing.gutter)
    }

    private static let sampleConnections = [
        ("Alice Moreau", "Active · verified"),
        ("Bob Okafor", "Active"),
        ("Clinic — Dr. Chen", "Pending"),
    ]

    private static let sampleRows = [
        ("Alice Moreau", "Are we still on for Friday?", "10:42"),
        ("Bob Okafor", "Shared: Insurance card (expires 2027)", "Oct 2"),
        ("Clinic — Dr. Chen", "Requests: allergies, blood type", "Sep 28"),
    ]

    /// A made-up invitation payload (VAULT-MESSAGING §6.4 shape; not a real claim).
    private static let galleryQR =
        #"{"v":2,"t":"c","r":"https://relay.example","c":"abcdefghijklmnopqrstuvwxyz","h":"x","k":"y","e":1791100000}"#

    /// An 8×8 PNG in four colour blocks.
    private static let galleryPhoto =
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAH0lEQVR4nGP4f1AVjrz9TsARAxUl5Of1wdF/JEBFCQCiLXjhwCs13wAAAABJRU5ErkJggg=="
}

/// Lays children out in rows, wrapping to the next row when one is full (Compose's `FlowRow`).
struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, origin) in rows(bounds.width, subviews).origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
#endif
