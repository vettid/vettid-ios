import Foundation

/// Represents different types of deep links the app can handle
enum DeepLink: Equatable {
    /// Enrollment with a session token: vettid://enroll?token={session_token}
    case enroll(token: String)

    /// Connect via invitation code: vettid://connect?code={invite_code}
    case connect(code: String)

    /// Open a conversation: vettid://message?connection={connection_id}
    case message(connectionId: String)

    /// Open vault status: vettid://vault
    case vault

    /// Unknown or invalid deep link
    case unknown
}

/// Handles parsing and routing of deep links
@MainActor
class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()

    /// The currently pending deep link to be handled
    @Published var pendingDeepLink: DeepLink?

    /// Whether a deep link is currently being processed
    @Published var isProcessing = false

    private init() {}

    /// Parse a URL into a DeepLink
    /// Supports both custom scheme (vettid://) and universal links (https://vettid.dev/)
    func parse(url: URL) -> DeepLink {
        // Handle custom scheme: vettid://
        if url.scheme == "vettid" {
            return parseCustomScheme(url: url)
        }

        // Handle universal links: https://vettid.dev/
        if url.scheme == "https" && (url.host == "vettid.dev" || url.host == "www.vettid.dev") {
            return parseUniversalLink(url: url)
        }

        return .unknown
    }

    /// Handle an incoming deep link URL
    func handle(url: URL) {
        let deepLink = parse(url: url)

        guard deepLink != .unknown else {
            print("DeepLinkHandler: Unknown deep link: \(url)")
            return
        }

        print("DeepLinkHandler: Handling deep link: \(deepLink)")
        pendingDeepLink = deepLink
    }

    /// Clear the pending deep link after it has been handled
    func clearPendingDeepLink() {
        pendingDeepLink = nil
    }

    // MARK: - Private Parsing Methods

    private func parseCustomScheme(url: URL) -> DeepLink {
        guard let host = url.host else { return .unknown }

        let queryParams = parseQueryParameters(url: url)

        switch host {
        case "enroll":
            if let token = queryParams["token"], !token.isEmpty {
                return .enroll(token: token)
            }
        case "connect":
            if let code = queryParams["code"], !code.isEmpty {
                return .connect(code: code)
            }
        case "message":
            if let connectionId = queryParams["connection"], !connectionId.isEmpty {
                return .message(connectionId: connectionId)
            }
        case "vault":
            return .vault
        default:
            break
        }

        return .unknown
    }

    private func parseUniversalLink(url: URL) -> DeepLink {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let queryParams = parseQueryParameters(url: url)

        guard !pathComponents.isEmpty else { return .unknown }

        switch pathComponents[0] {
        case "enroll":
            if let token = queryParams["token"], !token.isEmpty {
                return .enroll(token: token)
            }
        case "connect":
            if let code = queryParams["code"], !code.isEmpty {
                return .connect(code: code)
            }
            // Also support /connect/{code} format
            if pathComponents.count > 1 {
                return .connect(code: pathComponents[1])
            }
        case "message":
            if let connectionId = queryParams["connection"], !connectionId.isEmpty {
                return .message(connectionId: connectionId)
            }
        case "vault":
            return .vault
        default:
            break
        }

        return .unknown
    }

    private func parseQueryParameters(url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return [:]
        }

        var params: [String: String] = [:]
        for item in queryItems {
            params[item.name] = item.value ?? ""
        }
        return params
    }
}
