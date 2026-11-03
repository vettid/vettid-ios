#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
import VettIDData
import VettIDDataTesting
@testable import VettIDItems
@testable import VettIDItemsUI
import VettIDUI

// Fixtures stay on one line each.
// swiftlint:disable line_length

/// The tags screen: every state of the list, each dialog and the colour picker rendered; the form's values under a
/// preview; the picker's slots. Mirrors the tag tests of vettid-android's `SharingScreensTest`.
@MainActor
@Suite struct TagsScreensTests {
    let registry = TagRegistry(version: 1, tags: [TagView(tag: "@profile", items: 2), TagView(tag: "medical", items: 3, rules: ["r1"]), TagView(tag: "travel", items: 1, color: TagColors.stored[3], description: "Trips")])

    @Test func everyStateRenders() {
        var loading = TagsState()
        loading.loading = true
        var loaded = TagsState(registry: registry)
        loaded.loading = false
        var empty = TagsState(registry: TagRegistry(version: 1, tags: []))
        empty.loading = false
        var failed = loaded
        failed.error = .inUse
        var limited = loaded
        limited.error = .limit
        limited.limit = VaultLimit("tag_registry", max: 512)
        for s in [loading, loaded, empty, failed, limited] {
            #expect(height(TagsScreen(state: s, actions: TagsActions())) > 0)
        }
    }

    /// Tags that could not be read are never "No tags yet": the failure with "Try again"; with tags listed, the failure is
    /// said above them.
    @Test func aFailedReadIsNotTheEmptyState() {
        var unread = TagsState()
        unread.loading = false
        unread.loadFailure = LoadFailure(.network)
        #expect(TagsScreen.phase(unread) == .failed && !TagsScreen.canCreate(unread))
        unread.loadFailure = nil
        #expect(TagsScreen.phase(unread) == .empty)
        unread.loading = true
        #expect(TagsScreen.phase(unread) == .loading && !TagsScreen.canCreate(unread))
        var listed = TagsState(registry: registry)
        listed.loading = false
        listed.loadFailure = LoadFailure(.network)
        #expect(TagsScreen.phase(listed) == .rows && TagsScreen.canCreate(listed))
        #expect(height(TagsScreen(state: listed, actions: TagsActions())) > 0)
        #expect(ItemsStrings.errorList == "Your vault could not be read" && ItemsStrings.retry == "Try again")
        // Refused while the vault was on hold: the tags are not read again by themselves, so "Try again" stays.
        #expect(LoadFailedNotice.offersRetry(LoadFailure(.ownerCheckRequired), retriesByItself: TagsScreen.retriesByItself))
        #expect(!LoadFailedNotice.offersRetry(LoadFailure(.ownerCheckRequired), retriesByItself: ItemsScreen.retriesByItself))
    }

    @Test func everyDialogRenders() {
        let travel = registry.tags[2], medical = registry.tags[1]
        let dialogs: [TagDialog] = [
            .create(), .create(name: "!no", description: ""), .edit(tag: medical, name: "medical", description: ""),
            .confirmRename(tag: "travel", into: "trips", change: TagChange(version: 1, items: 1, sharesTotal: 1)),
            .confirmDelete(tag: "travel", change: TagChange(version: 1, items: 4)), .colour(travel), .profileColour,
        ]
        for d in dialogs {
            var s = TagsState(registry: registry)
            s.loading = false
            s.dialog = d
            #expect(height(TagsScreen(state: s, actions: TagsActions())) > 0, "\(d)")
            #expect(height(TagSheet(state: s, actions: TagsActions())) > 0, "\(d)")
        }
        #expect(height(TagForm(values: TagFormValues(.edit(tag: medical, name: "medical", description: "x"), registry: registry), busy: false, actions: TagsActions())) > 0)
        #expect(height(TagColourPicker(tag: travel, busy: true, actions: TagsActions())) > 0)
    }

    @Test func theFormShowsWhatItEditsAndAPreviewNeverABlankForm() {
        let medical = registry.tags[1], travel = registry.tags[2]
        let edit = TagFormValues(.edit(tag: medical, name: "health", description: "Doctors"), registry: registry)
        #expect(edit.title == "Edit tag" && edit.name == "health" && edit.description == "Doctors" && edit.tag == medical)
        #expect(TagFormValues(.create(), registry: registry).title == "New tag" && TagFormValues(.create(), registry: registry).tag == nil)
        // Under a preview: the tag it is about, as the registry has it (a rename's new name), never "New tag".
        let delete = TagFormValues(.confirmDelete(tag: "travel", change: TagChange(version: 1, items: 0)), registry: registry)
        #expect(delete.title == "Edit tag" && delete.name == "travel" && delete.description == "Trips" && delete.tag == travel)
        let rename = TagFormValues(.confirmRename(tag: "travel", into: "trips", change: TagChange(version: 1, items: 1)), registry: registry)
        #expect(rename.title == "Edit tag" && rename.name == "trips" && rename.tag == travel)
    }

    @Test func thePickerChecksTheShownSlot() {
        // A stored palette colour shows its slot; without one, the hash slot; @profile has none.
        #expect(TagColors.shownSlot("travel", stored: TagColors.stored[3]) == 3)
        #expect(TagColors.shownSlot("medical", stored: nil) == TagColors.index("medical"))
        #expect(TagColors.shownSlot("@profile", stored: nil) == -1)
        #expect(ItemsText.colourNames.count == TagColors.names.count && TagColorsPicker.perRowFits)
    }

    @Test func theRouteRendersOverAFake() async {
        let sharing = FakeSharing()
        sharing.registry = registry
        #expect(height(TagsRoute(sharing: sharing, onBack: {})) > 0)
    }

    /// The view's height laid out on an iPhone's screen, as the other packages' render tests measure it.
    private func height(_ view: some View) -> CGFloat {
        UIHostingController(rootView: view.vettIDTheme(.dark)).sizeThatFits(in: CGSize(width: 390, height: 844)).height
    }
}

/// The picker lays the palette out in rows of five.
enum TagColorsPicker {
    static var perRowFits: Bool { TagColors.names.count % TagColourPicker.perRow == 0 }
}

// swiftlint:enable line_length
#endif
