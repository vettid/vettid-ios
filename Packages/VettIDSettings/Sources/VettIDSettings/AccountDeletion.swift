import Foundation

/// Where a member deletes the VettID account (email and membership), as opposed to the vault ("Delete vault"): the
/// environment's account site, at `/account/delete/` (a member who is not signed in is sent to the sign-in first).
/// "Delete your VettID account" in Settings opens it, and is hidden when there is no page (nil).
public enum AccountDeletion {
    public static let path = "/account/delete/"

    /// The deletion page on [origin], the environment's account site (`https://account.vettid.org` in Release,
    /// `https://account.staging.vettid.org` in Staging).
    public static func url(origin: String) -> URL? {
        URL(string: origin + path)
    }
}
