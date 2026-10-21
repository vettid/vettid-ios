import Foundation

// The Vault's texts, continued (``ItemsStrings``).
public extension ItemsStrings {
    static var noFieldsYet: String {
        String(
            localized: "items_no_fields_yet",
            defaultValue: """
                No fields yet. Add the details you want to keep, such as a membership number.
                """,
            bundle: .module
        )
    }

    static var fields: String { String(localized: "items_fields", defaultValue: "Fields", bundle: .module) }

    static var cdChooseKind: String {
        String(localized: "items_cd_choose_kind", defaultValue: "Choose the type of field", bundle: .module)
    }

    static func cdFieldOptions(_ a: String) -> String {
        String(localized: "items_cd_field_options", defaultValue: "Options for \(a)", bundle: .module)
    }

    static func fieldKindKept(_ a: String) -> String {
        String(localized: "items_field_kind_kept", defaultValue: "\(a) · Kept as it is. Type to replace it.", bundle: .module)
    }

    static var fieldRename: String { String(localized: "items_field_rename", defaultValue: "Rename…", bundle: .module) }

    static var fieldChangeType: String {
        String(localized: "items_field_change_type", defaultValue: "Change type…", bundle: .module)
    }

    static var fieldTypeFixed: String {
        String(localized: "items_field_type_fixed", defaultValue: "A saved field keeps its type", bundle: .module)
    }

    static var fieldMoveUp: String { String(localized: "items_field_move_up", defaultValue: "Move up", bundle: .module) }

    static var fieldMoveDown: String { String(localized: "items_field_move_down", defaultValue: "Move down", bundle: .module) }

    static var fieldRemove: String { String(localized: "items_field_remove", defaultValue: "Remove", bundle: .module) }

    static var addField: String { String(localized: "items_add_field", defaultValue: "Add a field", bundle: .module) }

    static var fieldNamePrompt: String {
        String(localized: "items_field_name_prompt", defaultValue: "What is this field called?", bundle: .module)
    }

    static var fieldType: String { String(localized: "items_field_type", defaultValue: "Type", bundle: .module) }

    static var fieldAddConfirm: String { String(localized: "items_field_add_confirm", defaultValue: "Add", bundle: .module) }

    static var fieldRenameTitle: String {
        String(localized: "items_field_rename_title", defaultValue: "Rename the field", bundle: .module)
    }

    static var fieldRenameConfirm: String {
        String(localized: "items_field_rename_confirm", defaultValue: "Rename", bundle: .module)
    }

    static func fieldTypeTitle(_ a: String) -> String {
        String(localized: "items_field_type_title", defaultValue: "Type of \(a)", bundle: .module)
    }

    static var fieldTypeConfirm: String { String(localized: "items_field_type_confirm", defaultValue: "Change", bundle: .module) }

    static var categoryNew: String { String(localized: "items_category_new", defaultValue: "New category…", bundle: .module) }

    static var categoryNewTitle: String {
        String(localized: "items_category_new_title", defaultValue: "New category", bundle: .module)
    }

    static var categoryNewName: String {
        String(localized: "items_category_new_name", defaultValue: "Category name", bundle: .module)
    }

    static var categoryNewHint: String {
        String(localized: "items_category_new_hint", defaultValue: "Such as Loyalty cards", bundle: .module)
    }

    static func categorySavedAs(_ a: String) -> String {
        String(localized: "items_category_saved_as", defaultValue: "Saved as \(a)", bundle: .module)
    }

    static func categoryExisting(_ a: String) -> String {
        String(localized: "items_category_existing", defaultValue: "That is the \(a) category", bundle: .module)
    }

    static var categoryProblemEmpty: String {
        String(localized: "items_category_problem_empty", defaultValue: "Use letters a–z or digits", bundle: .module)
    }

    static var categoryProblemDigit: String {
        String(localized: "items_category_problem_digit", defaultValue: "Start with a letter", bundle: .module)
    }

    static var categoryNewConfirm: String {
        String(localized: "items_category_new_confirm", defaultValue: "Use it", bundle: .module)
    }

    static var addressStreet: String { String(localized: "items_address_street", defaultValue: "Street", bundle: .module) }

    static var addressStreet2: String {
        String(localized: "items_address_street2", defaultValue: "Street (second line)", bundle: .module)
    }

    static var addressPostalCode: String {
        String(localized: "items_address_postal_code", defaultValue: "Postal code", bundle: .module)
    }

    static var addressCity: String { String(localized: "items_address_city", defaultValue: "City", bundle: .module) }

    static var addressRegion: String { String(localized: "items_address_region", defaultValue: "Region", bundle: .module) }

    static var addressCountry: String { String(localized: "items_address_country", defaultValue: "Country code", bundle: .module) }

    static func sizeLeft(_ a: Int, _ b: Int) -> String {
        String(localized: "items_size_left", defaultValue: "Room left: \(a) of \(b) KB", bundle: .module)
    }

    static func sizeLeftAtLeast(_ a: Int, _ b: Int) -> String {
        String(localized: "items_size_left_at_least", defaultValue: "Room left: at least \(a) of \(b) KB", bundle: .module)
    }

    static func sizeOver(_ a: Int, _ b: Int) -> String {
        String(localized: "items_size_over", defaultValue: "Too large: \(a) KB over the \(b) KB an item holds", bundle: .module)
    }

    static var fieldKeptPlaceholder: String {
        String(localized: "items_field_kept_placeholder", defaultValue: "Kept (hidden)", bundle: .module)
    }

    static var notesKept: String {
        String(
            localized: "items_notes_kept",
            defaultValue: """
                Your notes are kept as they are. Type to replace them.
                """,
            bundle: .module
        )
    }

    static var notesKeptPlaceholder: String {
        String(localized: "items_notes_kept_placeholder", defaultValue: "Kept (hidden)", bundle: .module)
    }

    static var notesRemove: String { String(localized: "items_notes_remove", defaultValue: "Remove the notes", bundle: .module) }

    static var problemsTitle: String { String(localized: "items_problems_title", defaultValue: "Check the item", bundle: .module) }

    static var discardTitle: String {
        String(localized: "items_discard_title", defaultValue: "Discard changes to this item?", bundle: .module)
    }

    static var discardBody: String {
        String(localized: "items_discard_body", defaultValue: "What you typed is not saved.", bundle: .module)
    }

    static var discard: String { String(localized: "items_discard", defaultValue: "Discard", bundle: .module) }

    static var keepEditing: String { String(localized: "items_keep_editing", defaultValue: "Keep editing", bundle: .module) }

    static var errorSave: String { String(localized: "items_error_save", defaultValue: "Not saved", bundle: .module) }

    static var problemNameEmpty: String {
        String(localized: "items_problem_name_empty", defaultValue: "Give the item a name", bundle: .module)
    }

    static var problemNameLong: String {
        String(localized: "items_problem_name_long", defaultValue: "The name is too long (at most 128 bytes)", bundle: .module)
    }

    static var problemBadCharacter: String {
        String(localized: "items_problem_bad_character", defaultValue: "Remove control characters", bundle: .module)
    }

    static var problemCategory: String {
        String(localized: "items_problem_category", defaultValue: "Choose a category", bundle: .module)
    }

    static var problemLabelEmpty: String {
        String(localized: "items_problem_label_empty", defaultValue: "Give the field a label", bundle: .module)
    }

    static var problemLabelLong: String {
        String(localized: "items_problem_label_long", defaultValue: "The label is too long (at most 64 bytes)", bundle: .module)
    }

    static var problemValueLong: String {
        String(localized: "items_problem_value_long", defaultValue: "The value is too long", bundle: .module)
    }

    static var problemNotesLong: String {
        String(localized: "items_problem_notes_long", defaultValue: "The notes are too long (at most 16 KB)", bundle: .module)
    }

    static var problemFields: String {
        String(localized: "items_problem_fields", defaultValue: "At most 64 fields", bundle: .module)
    }

    static var problemTags: String { String(localized: "items_problem_tags", defaultValue: "At most 16 tags", bundle: .module) }

    static var problemTag: String {
        String(
            localized: "items_problem_tag",
            defaultValue: """
                Tags use lowercase letters, digits, spaces, hyphens (-) and underscores (_), and start with a letter \
                or digit
                """,
            bundle: .module
        )
    }

    static var problemProfile: String {
        String(
            localized: "items_problem_profile",
            defaultValue: """
                Only standard items can be in your shared profile
                """,
            bundle: .module
        )
    }

    static var problemSize: String {
        String(
            localized: "items_problem_size",
            defaultValue: """
                The item is too large (at most 64 KB, or 12 KB for a critical item)
                """,
            bundle: .module
        )
    }

    static var errorLimitItems: String {
        String(
            localized: "items_error_limit_items",
            defaultValue: """
                Your vault is full: it holds at most 2,000 items
                """,
            bundle: .module
        )
    }

    static var errorLimitCritical: String {
        String(
            localized: "items_error_limit_critical",
            defaultValue: """
                Your credential is full: it holds at most 1,000 critical items
                """,
            bundle: .module
        )
    }

    static var errorLimitProfile: String {
        String(
            localized: "items_error_limit_profile",
            defaultValue: """
                Your shared profile is full: at most 32 items, within its size limit
                """,
            bundle: .module
        )
    }

    static var errorLimit: String {
        String(localized: "items_error_limit", defaultValue: "A limit of your vault would be exceeded", bundle: .module)
    }

    static var errorConflict: String {
        String(
            localized: "items_error_conflict",
            defaultValue: """
                This item was changed on another device. Go back, open it again and repeat your change.
                """,
            bundle: .module
        )
    }

    static var errorNotFound: String {
        String(localized: "items_error_not_found", defaultValue: "This item is no longer in your vault", bundle: .module)
    }

    static var errorRefused: String {
        String(
            localized: "items_error_refused",
            defaultValue: """
                Your vault refused this item. Check its fields and try again.
                """,
            bundle: .module
        )
    }

    static var tagsManage: String { String(localized: "items_tags_manage", defaultValue: "Manage tags", bundle: .module) }

    static var tagsTitle: String { String(localized: "items_tags_title", defaultValue: "Tags", bundle: .module) }

    static var tagsNew: String { String(localized: "items_tags_new", defaultValue: "New tag", bundle: .module) }

    static var tagsEdit: String { String(localized: "items_tags_edit", defaultValue: "Edit tag", bundle: .module) }

    static var tagsName: String { String(localized: "items_tags_name", defaultValue: "Tag", bundle: .module) }

    static var tagsDescription: String {
        String(localized: "items_tags_description", defaultValue: "Description (optional)", bundle: .module)
    }

    static var tagsDelete: String { String(localized: "items_tags_delete", defaultValue: "Delete tag", bundle: .module) }

    static var tagsRename: String { String(localized: "items_tags_rename", defaultValue: "Rename", bundle: .module) }

    static func tagsRenameTitle(_ a: String, _ b: String) -> String {
        String(localized: "items_tags_rename_title", defaultValue: "Rename \(a) to \(b)?", bundle: .module)
    }

    static func tagsDeleteTitle(_ a: String) -> String {
        String(localized: "items_tags_delete_title", defaultValue: "Delete the tag \(a)?", bundle: .module)
    }

    static var tagsEmptyTitle: String { String(localized: "items_tags_empty_title", defaultValue: "No tags yet", bundle: .module) }

    static var tagsEmptyBody: String {
        String(
            localized: "items_tags_empty_body",
            defaultValue: """
                Tags organise your items and decide what you share with each connection
                """,
            bundle: .module
        )
    }

    static var tagProfileNote: String {
        String(
            localized: "items_tag_profile_note",
            defaultValue: """
                Every connection sees these items in your profile
                """,
            bundle: .module
        )
    }

    static var tagsEditColour: String { String(localized: "items_tags_edit_colour", defaultValue: "Edit colour", bundle: .module) }

    static func tagsCdColour(_ a: String) -> String {
        String(localized: "items_tags_cd_colour", defaultValue: "Edit the colour of \(a)", bundle: .module)
    }

    static func tagsColourTitle(_ a: String) -> String {
        String(localized: "items_tags_colour_title", defaultValue: "Colour of \(a)", bundle: .module)
    }

    static var tagsColourProfileTitle: String {
        String(localized: "items_tags_colour_profile_title", defaultValue: "Shared profile", bundle: .module)
    }

    static var tagsColourProfile: String {
        String(localized: "items_tags_colour_profile", defaultValue: "Your shared profile always uses your colour", bundle: .module)
    }

    static func tagsCdColourSelected(_ a: String) -> String {
        String(localized: "items_tags_cd_colour_selected", defaultValue: "\(a), selected", bundle: .module)
    }

    static var tagColourRed: String { String(localized: "items_tag_colour_red", defaultValue: "Red", bundle: .module) }

    static var tagColourOrange: String { String(localized: "items_tag_colour_orange", defaultValue: "Orange", bundle: .module) }

    static var tagColourGreen: String { String(localized: "items_tag_colour_green", defaultValue: "Green", bundle: .module) }

    static var tagColourTeal: String { String(localized: "items_tag_colour_teal", defaultValue: "Teal", bundle: .module) }

    static var tagColourBlue: String { String(localized: "items_tag_colour_blue", defaultValue: "Blue", bundle: .module) }

    static var tagColourIndigo: String { String(localized: "items_tag_colour_indigo", defaultValue: "Indigo", bundle: .module) }

    static var tagColourViolet: String { String(localized: "items_tag_colour_violet", defaultValue: "Violet", bundle: .module) }

    static var tagColourPink: String { String(localized: "items_tag_colour_pink", defaultValue: "Pink", bundle: .module) }

    static var tagColourBrown: String { String(localized: "items_tag_colour_brown", defaultValue: "Brown", bundle: .module) }

    static var tagColourSlate: String { String(localized: "items_tag_colour_slate", defaultValue: "Slate", bundle: .module) }

    static func tagItems(_ a: Int) -> String {
        String(localized: "items_tag_items", defaultValue: "\(a) items", bundle: .module)
    }

    static func tagRules(_ a: Int) -> String {
        String(localized: "items_tag_rules", defaultValue: "used by \(a) sharing rules", bundle: .module)
    }

    static func tagsUsedByRules(_ a: Int) -> String {
        String(
            localized: "items_tags_used_by_rules",
            defaultValue: """
                \(a) sharing rules use this tag: it cannot be deleted while they do, and renaming it changes the \
                rules too.
                """,
            bundle: .module
        )
    }

    static func tagsChangeItems(_ a: Int) -> String {
        String(localized: "items_tags_change_items", defaultValue: "This changes \(a) items.", bundle: .module)
    }

    static func tagsChangeShared(_ a: Int) -> String {
        String(localized: "items_tags_change_shared", defaultValue: "\(a) items are then shared automatically.", bundle: .module)
    }

    static func tagsChangeAsked(_ a: Int) -> String {
        String(localized: "items_tags_change_asked", defaultValue: "You will be asked about sharing \(a) items.", bundle: .module)
    }

    static var sharingThisConnection: String {
        String(localized: "items_sharing_this_connection", defaultValue: "this connection", bundle: .module)
    }

    static func ruleName(_ a: String) -> String {
        String(localized: "items_rule_name", defaultValue: "your “\(a)” rule", bundle: .module)
    }

    static var impactTitle: String { String(localized: "items_impact_title", defaultValue: "Sharing", bundle: .module) }
}
