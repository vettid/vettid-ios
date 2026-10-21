import Foundation

/// The Vault's texts: vettid-android `feature/items` `strings.xml` and `strings_sharing.xml`, word for word, under their
/// string names (the whole of both in this package's table; here the accessors of the screens built so far). Android's
/// plural `items_rule_uses` is `items_rule_uses_plural` here, since one table cannot hold a string and a plural of one
/// name (chosen; not in the spec).
public enum ItemsStrings {
    /// The table's bundle (for the tests' check of every key).
    public static var bundle: Bundle { .module }

    public static var ok: String { String(localized: "items_ok", defaultValue: "OK", bundle: .module) }

    public static var cancel: String { String(localized: "items_cancel", defaultValue: "Cancel", bundle: .module) }

    public static var save: String { String(localized: "items_save", defaultValue: "Save", bundle: .module) }

    public static var delete: String { String(localized: "items_delete", defaultValue: "Delete", bundle: .module) }

    public static var tagProfile: String { String(localized: "items_tag_profile", defaultValue: "Shared profile", bundle: .module) }

    public static var tagHint: String {
        String(
            localized: "items_tag_hint",
            defaultValue: """
                Lowercase letters, digits, spaces, hyphens (-) and underscores (_), up to 32 characters.
                """,
            bundle: .module
        )
    }

    public static var problemTag: String {
        String(
            localized: "items_problem_tag",
            defaultValue: """
                Tags use lowercase letters, digits, spaces, hyphens (-) and underscores (_), and start with a letter \
                or digit
                """,
            bundle: .module
        )
    }

    public static var errorItem: String { String(localized: "items_error_item", defaultValue: "Something went wrong", bundle: .module) }

    public static var errorLimitItems: String {
        String(
            localized: "items_error_limit_items",
            defaultValue: """
                Your vault is full: it holds at most 2,000 items
                """,
            bundle: .module
        )
    }

    public static var errorLimitCritical: String {
        String(
            localized: "items_error_limit_critical",
            defaultValue: """
                Your credential is full: it holds at most 1,000 critical items
                """,
            bundle: .module
        )
    }

    public static var errorLimitProfile: String {
        String(
            localized: "items_error_limit_profile",
            defaultValue: """
                Your shared profile is full: at most 32 items, within its size limit
                """,
            bundle: .module
        )
    }

    public static var errorLimit: String {
        String(localized: "items_error_limit", defaultValue: "A limit of your vault would be exceeded", bundle: .module)
    }

    public static var errorConflict: String {
        String(
            localized: "items_error_conflict",
            defaultValue: """
                This item was changed on another device. Go back, open it again and repeat your change.
                """,
            bundle: .module
        )
    }

    public static var errorNotFound: String {
        String(localized: "items_error_not_found", defaultValue: "This item is no longer in your vault", bundle: .module)
    }

    public static var errorRefused: String {
        String(
            localized: "items_error_refused",
            defaultValue: """
                Your vault refused this item. Check its fields and try again.
                """,
            bundle: .module
        )
    }

    public static var tagsManage: String { String(localized: "items_tags_manage", defaultValue: "Manage tags", bundle: .module) }

    public static var tagsTitle: String { String(localized: "items_tags_title", defaultValue: "Tags", bundle: .module) }

    public static var tagsNew: String { String(localized: "items_tags_new", defaultValue: "New tag", bundle: .module) }

    public static var tagsEdit: String { String(localized: "items_tags_edit", defaultValue: "Edit tag", bundle: .module) }

    public static var tagsName: String { String(localized: "items_tags_name", defaultValue: "Tag", bundle: .module) }

    public static var tagsDescription: String {
        String(localized: "items_tags_description", defaultValue: "Description (optional)", bundle: .module)
    }

    public static var tagsDelete: String { String(localized: "items_tags_delete", defaultValue: "Delete tag", bundle: .module) }

    public static var tagsRename: String { String(localized: "items_tags_rename", defaultValue: "Rename", bundle: .module) }

    public static func tagsRenameTitle(_ a: String, _ b: String) -> String {
        String(localized: "items_tags_rename_title", defaultValue: "Rename \(a) to \(b)?", bundle: .module)
    }

    public static func tagsDeleteTitle(_ a: String) -> String {
        String(localized: "items_tags_delete_title", defaultValue: "Delete the tag \(a)?", bundle: .module)
    }

    public static var tagsEmptyTitle: String { String(localized: "items_tags_empty_title", defaultValue: "No tags yet", bundle: .module) }

    public static var tagsEmptyBody: String {
        String(
            localized: "items_tags_empty_body",
            defaultValue: """
                Tags organise your items and decide what you share with each connection
                """,
            bundle: .module
        )
    }

    public static var tagProfileNote: String {
        String(
            localized: "items_tag_profile_note",
            defaultValue: """
                Every connection sees these items in your profile
                """,
            bundle: .module
        )
    }

    public static var tagsEditColour: String { String(localized: "items_tags_edit_colour", defaultValue: "Edit colour", bundle: .module) }

    public static func tagsCdColour(_ a: String) -> String {
        String(localized: "items_tags_cd_colour", defaultValue: "Edit the colour of \(a)", bundle: .module)
    }

    public static func tagsColourTitle(_ a: String) -> String {
        String(localized: "items_tags_colour_title", defaultValue: "Colour of \(a)", bundle: .module)
    }

    public static var tagsColourProfileTitle: String {
        String(localized: "items_tags_colour_profile_title", defaultValue: "Shared profile", bundle: .module)
    }

    public static var tagsColourProfile: String {
        String(localized: "items_tags_colour_profile", defaultValue: "Your shared profile always uses your colour", bundle: .module)
    }

    public static func tagsCdColourSelected(_ a: String) -> String {
        String(localized: "items_tags_cd_colour_selected", defaultValue: "\(a), selected", bundle: .module)
    }

    public static var tagColourRed: String { String(localized: "items_tag_colour_red", defaultValue: "Red", bundle: .module) }

    public static var tagColourOrange: String { String(localized: "items_tag_colour_orange", defaultValue: "Orange", bundle: .module) }

    public static var tagColourGreen: String { String(localized: "items_tag_colour_green", defaultValue: "Green", bundle: .module) }

    public static var tagColourTeal: String { String(localized: "items_tag_colour_teal", defaultValue: "Teal", bundle: .module) }

    public static var tagColourBlue: String { String(localized: "items_tag_colour_blue", defaultValue: "Blue", bundle: .module) }

    public static var tagColourIndigo: String { String(localized: "items_tag_colour_indigo", defaultValue: "Indigo", bundle: .module) }

    public static var tagColourViolet: String { String(localized: "items_tag_colour_violet", defaultValue: "Violet", bundle: .module) }

    public static var tagColourPink: String { String(localized: "items_tag_colour_pink", defaultValue: "Pink", bundle: .module) }

    public static var tagColourBrown: String { String(localized: "items_tag_colour_brown", defaultValue: "Brown", bundle: .module) }

    public static var tagColourSlate: String { String(localized: "items_tag_colour_slate", defaultValue: "Slate", bundle: .module) }

    public static func tagItems(_ a: Int) -> String {
        String(localized: "items_tag_items", defaultValue: "\(a) items", bundle: .module)
    }

    public static func tagRules(_ a: Int) -> String {
        String(localized: "items_tag_rules", defaultValue: "used by \(a) sharing rules", bundle: .module)
    }

    public static func tagsUsedByRules(_ a: Int) -> String {
        String(
            localized: "items_tags_used_by_rules",
            defaultValue: """
                \(a) sharing rules use this tag: it cannot be deleted while they do, and renaming it changes the \
                rules too.
                """,
            bundle: .module
        )
    }

    public static func tagsChangeItems(_ a: Int) -> String {
        String(localized: "items_tags_change_items", defaultValue: "This changes \(a) items.", bundle: .module)
    }

    public static func tagsChangeShared(_ a: Int) -> String {
        String(localized: "items_tags_change_shared", defaultValue: "\(a) items are then shared automatically.", bundle: .module)
    }

    public static func tagsChangeAsked(_ a: Int) -> String {
        String(localized: "items_tags_change_asked", defaultValue: "You will be asked about sharing \(a) items.", bundle: .module)
    }
}
