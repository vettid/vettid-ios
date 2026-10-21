#if os(iOS)
import SwiftUI
import VettIDData
import VettIDSettings
import VettIDUI

/// The items connections see in the shared profile (VAULT-MESSAGING §10.8: `data` items tagged `@profile`, at most 32):
/// each opens or is taken out; "Add an item from your vault" lists the standard items that could join. Mirrors
/// vettid-android `ProfileItemsCard` and `ProfileItemPicker`.
struct ProfileItemsCard: View {
    @Environment(\.vettIDColors) private var colors
    @Environment(\.vettIDCovered) private var covered
    let state: SharedProfileState
    let actions: SharedProfileActions

    var body: some View {
        DetailCard {
            Text(ProfileStrings.itemsTitle).vettIDFont(.labelLarge)
            Text(ProfileStrings.items).vettIDFont(.bodySmall).foregroundStyle(colors.onSurfaceVariant)
            if state.profileItems.isEmpty {
                Text(ProfileStrings.itemsNone).foregroundStyle(colors.onSurfaceVariant).accessibilityIdentifier("profile_items_none")
            }
            ForEach(state.profileItems, id: \.itemID) { i in
                HStack {
                    Button { actions.onOpenItem?(i.itemID) } label: {
                        Text(i.name).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Spacing.touchTarget)
                    ProfileTextButton(ProfileStrings.itemsRemove, enabled: !state.itemsBusy) { actions.onRemoveItem(i) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("profile_item_\(i.itemID)")
            }
            let canAdd = !state.itemsBusy && !state.candidates.isEmpty && state.profileItems.count < SharedProfileViewModel.maxProfileItems
            ProfileTextButton(ProfileStrings.itemsAdd, enabled: canAdd) { actions.onPickItem(true) }
                .accessibilityIdentifier("profile_items_add")
        }
        .accessibilityIdentifier("profile_items")
        .sheet(isPresented: uncovered(Binding(get: { state.pickingItem }, set: { actions.onPickItem($0) }), covered: covered)) {
            ProfileItemPicker(state: state, actions: actions)
                .presentationDetents([.medium, .large])
                .presentationBackground(colors.surfaceContainerLow.color)
        }
    }
}

/// "Add to your shared profile": the standard items not in it yet.
struct ProfileItemPicker: View {
    @Environment(\.vettIDColors) private var colors
    let state: SharedProfileState
    let actions: SharedProfileActions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ProfileStrings.itemsPick).vettIDFont(.titleMedium).accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.candidates, id: \.itemID) { i in
                        Button { actions.onAddItem(i) } label: {
                            Text(i.name).vettIDFont(.bodyLarge).foregroundStyle(colors.onSurface)
                                .frame(maxWidth: .infinity, minHeight: Spacing.touchTarget, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("profile_item_pick_\(i.itemID)")
                    }
                }
            }
            HStack {
                Spacer()
                ProfileTextButton(SettingsStrings.cancel) { actions.onPickItem(false) }
            }
        }
        .padding(Spacing.xl)
        .accessibilityIdentifier("profile_items_pick")
    }
}
#endif
