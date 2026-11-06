import Foundation

/// Where a member deletes the VettID account (email and membership), as opposed to the vault ("Delete vault"). The account
/// site's deletion page does not exist yet: while this is nil Settings shows no "Delete your VettID account" row. Set it to the
/// page's address once the page is live (chosen; not in the spec: the address is the owner's to give).
public enum AccountDeletion {
    public static let url: URL? = nil
}
