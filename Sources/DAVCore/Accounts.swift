import Foundation
import Security

/// The app group shared by the app and its File Provider extension.
public enum AppGroup {
    /// The group the user's signing profile actually grants (verified from the
    /// profile: five `group.36bc655743a2bdd2.<n>` entry). A name the profile
    /// does not grant yields no container, which breaks both the durable
    /// password copy and the extension's access to the account.
    static let defaultIdentifier = "group.36bc655743a2bdd2.1"

    /// SideStore/AltStore rewrite app groups for the signing team and list the
    /// new names under ALTAppGroups in Info.plist, so prefer those; the first
    /// one with a real container wins.
    public static let identifier: String = {
        let listed = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        return listed.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
            ?? defaultIdentifier
    }()

    public static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }
}

/// A WebDAV server the user added, reachable by one or two addresses. The
/// password and any Cloudflare Access credentials live in the Keychain.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The address while on the same network as the server (http or https).
    public var lanURLString: String
    /// The fixed public endpoint (https only). Cloudflare Access, once added,
    /// only ever sits in front of this one.
    public var wanURLString: String
    public var username: String
    /// Cloudflare Access service token ID for the public endpoint. The matching
    /// secret is kept in the durable password store, not in this JSON.
    public var wanClientID: String
    /// Optional pinned certificate for a self-signed LAN address: the host of
    /// that address must present exactly this certificate.
    public var pinnedCertificate: Data?

    public init(id: String = UUID().uuidString, name: String,
                lanURLString: String = "", wanURLString: String = "",
                username: String, wanClientID: String = "",
                pinnedCertificate: Data? = nil) {
        self.id = id
        self.name = name
        self.lanURLString = lanURLString
        self.wanURLString = wanURLString
        self.username = username
        self.wanClientID = wanClientID
        self.pinnedCertificate = pinnedCertificate
    }

    // MARK: URLs

    /// A URL that must exist (non-nil) for the account to be usable.
    public var lanURL: URL? { Self.parse(lanURLString, httpsOnly: false) }
    /// https only: the public endpoint never degrades to plain http.
    public var wanURL: URL? { Self.parse(wanURLString, httpsOnly: true) }

    public var hasLAN: Bool { !lanURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasWAN: Bool { !wanURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static func parse(_ string: String, httpsOnly: Bool) -> URL? {
        var string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.isEmpty { return nil }
        if !string.contains("://") { string = "https://" + string }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              url.host() != nil else { return nil }
        if httpsOnly, scheme != "https" { return nil }
        if !["http", "https"].contains(scheme) { return nil }
        return url
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case id, name, lanURLString, wanURLString, username, wanClientID, pinnedCertificate
        /// Pre-dual-endpoint accounts stored one `urlString`; it was the public
        /// address, so it migrates to the WAN endpoint.
        case legacyURL = "urlString"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        wanClientID = try container.decodeIfPresent(String.self, forKey: .wanClientID) ?? ""
        lanURLString = try container.decodeIfPresent(String.self, forKey: .lanURLString) ?? ""
        wanURLString = try container.decodeIfPresent(String.self, forKey: .wanURLString) ?? ""
        pinnedCertificate = try container.decodeIfPresent(Data.self, forKey: .pinnedCertificate)
        if lanURLString.isEmpty && wanURLString.isEmpty {
            wanURLString = try container.decodeIfPresent(String.self, forKey: .legacyURL) ?? ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(lanURLString, forKey: .lanURLString)
        try container.encode(wanURLString, forKey: .wanURLString)
        try container.encode(username, forKey: .username)
        try container.encode(wanClientID, forKey: .wanClientID)
        try container.encodeIfPresent(pinnedCertificate, forKey: .pinnedCertificate)
    }
}

/// Accounts as JSON in the app group's defaults, readable by the extension.
public enum AccountStore {
    private static let key = "accounts"

    public static func load() -> [Account] {
        guard let data = AppGroup.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    public static func save(_ accounts: [Account]) {
        AppGroup.defaults.set(try? JSONEncoder().encode(accounts), forKey: key)
    }

    public static func account(id: String) -> Account? { load().first { $0.id == id } }

    // MARK: Cloudflare Access
    //
    // A public endpoint behind Cloudflare Access answers 302 to a login page
    // unless the request carries a service token; those two headers are what
    // "logging in" means for a WebDAV client there. Only the public endpoint
    // ever gets them, so the LAN address stays untouched.

    /// Key suffix for the token secret in the durable password store.
    public static func cfSecretKey(_ id: String) -> String { id + ".cfsecret" }

    public static func cfSecret(for id: String) -> String {
        Passwords.password(for: cfSecretKey(id)) ?? ""
    }

    @discardableResult
    public static func setCFSecret(_ secret: String, for id: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Passwords.delete(for: cfSecretKey(id))
            return true
        }
        return Passwords.write(trimmed, for: cfSecretKey(id))
    }

    // MARK: Browser login (e-mail OTP)
    //
    // Cloudflare Access also lets a human log in in a browser: after the OTP
    // the zone sets its session cookie, and a request carrying that cookie is
    // authenticated without a service token. The app's embedded web view
    // performs that login and the cookies are kept here, durably.

    public static func cfCookieKey(_ id: String) -> String { id + ".cfcookie" }

    /// One "name=value" per line, as the web view handed them over.
    public static func cfCookies(for id: String) -> [String] {
        guard let text = Passwords.password(for: cfCookieKey(id)) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    @discardableResult
    public static func setCFCookies(_ cookies: [String], for id: String) -> Bool {
        let clean = cookies.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty else {
            Passwords.delete(for: cfCookieKey(id))
            return true
        }
        return Passwords.write(clean.joined(separator: "\n"), for: cfCookieKey(id))
    }

    /// The Cookie header value for the cookies a browser login produced.
    public static func cfCookieHeader(_ cookies: [String]) -> [String: String] {
        guard !cookies.isEmpty else { return [:] }
        return ["Cookie": cookies.joined(separator: "; ")]
    }

    /// The headers a Cloudflare Access service token adds, or empty when the
    /// account has no token configured.
    public static func cfAccessHeaders(clientID: String, secret: String) -> [String: String] {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !secret.isEmpty else { return [:] }
        return [
            "CF-Access-Client-Id": clientID,
            "CF-Access-Client-Secret": secret,
        ]
    }

    /// The endpoint(s) an account is reachable at, in preference order.
    public static func endpoints(forAccountID id: String) throws -> [Endpoint] {
        guard let account = account(id: id) else { throw DAVError.invalidURL }
        let password = Passwords.password(for: id) ?? ""
        var endpoints: [Endpoint] = []
        if let url = account.lanURL {
            endpoints.append(Endpoint(url: url, username: account.username, password: password,
                                      isWan: false, pinnedCertificate: account.pinnedCertificate))
        }
        if let url = account.wanURL {
            var headers = cfAccessHeaders(clientID: account.wanClientID, secret: cfSecret(for: id))
            headers.merge(cfCookieHeader(cfCookies(for: id))) { current, _ in current }
            endpoints.append(Endpoint(url: url, username: account.username, password: password,
                                      isWan: true, cfAccessHeaders: headers))
        }
        guard !endpoints.isEmpty else { throw DAVError.invalidURL }
        return endpoints
    }

    /// One client per call, so edits to the account (URLs, ignore rules, the
    /// later Cloudflare credentials) apply right away. Starts from the last
    /// known good endpoint, then falls back to the other one per request.
    public static func client(forAccountID id: String) throws -> WebDAVClient {
        let endpoints = try endpoints(forAccountID: id)
        let preferred: EndpointMode
        if let remembered = EndpointStore.lastGood(forAccountID: id),
           endpoints.contains(where: { $0.isWan == (remembered == .wan) }) {
            preferred = remembered
        } else {
            preferred = .wan // the public endpoint is the safe default
        }
        return WebDAVClient(endpoints: endpoints, startMode: preferred) { mode in
            EndpointStore.remember(mode, forAccountID: id)
        }
    }
}

/// Passwords in a Keychain access group both targets share (the app group).
public enum Keychain {
    private static let service = "io.github.crazyquark.davdrive.account"

    private static func query(_ id: String) -> [String: Any] {
        // No kSecAttrAccessGroup: an app group name is not a keychain access
        // group, and the signing profile only grants keychain groups shaped
        // "<TEAMID>.*". Without the attribute the item lives in the app's own
        // default keychain group, which the profile always grants, so the app
        // can always keep and read it. The extension reads the shared app
        // group file instead.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    public static func password(for id: String) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setPassword(_ password: String, for id: String) -> OSStatus {
        SecItemDelete(query(id) as CFDictionary)
        var item = query(id)
        item[kSecValueData as String] = Data(password.utf8)
        // The extension may run while the device is locked (after first unlock).
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil)
    }

    public static func deletePassword(for id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
