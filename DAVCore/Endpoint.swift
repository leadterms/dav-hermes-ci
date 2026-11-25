import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// One way to reach an account's WebDAV root: the on-LAN address, or the
/// fixed public endpoint behind Cloudflare (WAN). An account has one or both.
public struct Endpoint: Hashable, Sendable {
    /// Normalized so relative paths resolve inside the folder.
    public let url: URL
    public let username: String
    public let password: String
    /// The Cloudflare-protected endpoint: https only. It is also the only
    /// endpoint the (later) Cloudflare Access credentials get sent to.
    public let isWan: Bool
    /// A pinned certificate (PEM or DER). When set, the endpoint's host must
    /// present exactly this certificate on top of normal validation.
    public let pinnedCertificate: Data?
    /// Headers the Cloudflare Access layer adds to this endpoint's requests.
    /// Empty until the login/service-token work lands; declared now so the
    /// single injection point exists.
    public let cfAccessHeaders: [String: String]

    public init(url: URL, username: String, password: String, isWan: Bool,
                pinnedCertificate: Data? = nil, cfAccessHeaders: [String: String] = [:]) {
        // A trailing slash makes the base a folder, so relative paths resolve inside it.
        self.url = url.path.hasSuffix("/") ? url : url.appending(path: "", directoryHint: .isDirectory)
        self.username = username
        self.password = password
        self.isWan = isWan
        self.pinnedCertificate = pinnedCertificate
        self.cfAccessHeaders = cfAccessHeaders
    }

    /// Basic-auth header value, or nil when the endpoint needs no credentials.
    var basicAuthorization: String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// Answers whether this endpoint currently accepts connections: any HTTP
    /// answer (even 401/302) proves reachability.
    public static func probe(_ endpoint: Endpoint, timeout: TimeInterval = 2) async -> Bool {
        var request = URLRequest(url: endpoint.url, timeoutInterval: timeout)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        if let basic = endpoint.basicAuthorization {
            request.setValue(basic, forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // Anything below 600 is a real server answer (302 to Cloudflare's
            // login page counts: the endpoint is reachable).
            return http.statusCode < 600
        } catch {
            return false
        }
    }
}

/// Which endpoint a client prefers. Persisted per account so a short-lived
/// File Provider extension can start from the last known good one.
public enum EndpointMode: String, Codable, Sendable {
    case lan, wan

    public var other: EndpointMode { self == .lan ? .wan : .lan }
}

/// The shared "last known good endpoint" per account (app group defaults).
public enum EndpointStore {
    private static func key(_ accountID: String) -> String { "lastGoodEndpoint.\(accountID)" }

    public static func lastGood(forAccountID id: String) -> EndpointMode? {
        guard let raw = AppGroup.defaults.string(forKey: key(id)) else { return nil }
        return EndpointMode(rawValue: raw)
    }

    public static func remember(_ mode: EndpointMode, forAccountID id: String) {
        AppGroup.defaults.set(mode.rawValue, forKey: key(id))
    }

    public static func forget(_ accountID: String) {
        AppGroup.defaults.removeObject(forKey: key(accountID))
    }
}
