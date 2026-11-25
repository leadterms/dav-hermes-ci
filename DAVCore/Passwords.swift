import Foundation
#if canImport(Security)
import Security
#endif

/// Passwords that survive an app reinstall.
///
/// The Keychain copy is erased when the app is uninstalled, so after a
/// fresh install the editor would show an empty password and the File
/// Provider would authenticate with nothing. The app-group container is
/// *not* removed on uninstall, so a protected file in it is the durable
/// store the extension can read; the Keychain stays as a fast, best-effort
/// copy.
///
/// When the signing tool did not grant the app group (G-01), neither the
/// file nor the shared keychain item is possible, so a *plain* keychain
/// item (no access group, no entitlements) is kept as a last resort: it
/// still survives an uninstall, but only the main app can read it — the
/// Files extension stays without a password until a group is granted.
public enum Passwords {
    private static func url(for id: String) -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else { return nil }
        return container.appendingPathComponent("Passwords", isDirectory: true)
            .appendingPathComponent(id)
    }

    #if canImport(Security)
    /// The entitlement-free fallback item: no kSecAttrAccessGroup, so it needs
    /// no provisioning profile at all. Survives the app's uninstall.
    private static func plainKeychainQuery(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.crazyquark.davdrive.password",
            kSecAttrAccount as String: id,
        ]
    }

    private static func plainKeychainPassword(_ id: String) -> String? {
        var query = plainKeychainQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    #endif

    /// Shared keychain first (fast path), then the surviving app-group file,
    /// then the entitlement-free local keychain item.
    public static func password(for id: String) -> String? {
        if let keychain = Keychain.password(for: id) { return keychain }
        if let file = filePassword(for: id) { return file }
        #if canImport(Security)
        return plainKeychainPassword(id)
        #else
        return nil
        #endif
    }

    private static func filePassword(for id: String) -> String? {
        guard let url = url(for: id),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Store the durable app-group copy, then the Keychain. A missing
    /// keychain-access-groups entitlement only disables the copy; the file
    /// keeps the password usable. When the shared container is unavailable
    /// (G-01) the entitlement-free local keychain item keeps the password
    /// across reinstalls instead. Reports whether *something* durable was
    /// kept, so the caller can say so instead of failing silently.
    @discardableResult
    public static func write(_ password: String, for id: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        var kept = false
        if let url = url(for: id) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Usable while locked, after the first unlock, like the Keychain
            // item, so background File Provider sync keeps working.
            let dir = url.deletingLastPathComponent()
            let tmp = dir.appendingPathComponent("write-\(UUID().uuidString)")
            do {
                try data.write(to: tmp, options: .atomic)
                var attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
                attrs[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
                try FileManager.default.setAttributes(attrs, ofItemAtPath: tmp.path)
                try? FileManager.default.removeItem(at: url) // an older copy
                try FileManager.default.moveItem(at: tmp, to: url)
                kept = true
            } catch {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
        if !kept {
            #if canImport(Security)
            SecItemDelete(plainKeychainQuery(id) as CFDictionary)
            var item = plainKeychainQuery(id)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            kept = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
            #endif
        }
        Keychain.setPassword(password, for: id)
        return kept
    }

    public static func delete(for id: String) {
        Keychain.deletePassword(for: id)
        #if canImport(Security)
        SecItemDelete(plainKeychainQuery(id) as CFDictionary)
        #endif
        if let url = url(for: id) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Where a password can currently be read back, and whether the shared
    /// storage the durable copy lives in even exists on this install. The
    /// editor shows this so a missing prefill is self-explanatory instead of
    /// a mystery.
    public struct PasswordDiagnostic {
        public let inKeychain: Bool
        public let inFile: Bool
        public let inLocalKeychain: Bool
        public let groupID: String
        public let groupAvailable: Bool
    }

    public static func diagnostic(for id: String) -> PasswordDiagnostic {
        let keychain = Keychain.password(for: id) != nil
        var file = false
        var available = false
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) {
            available = true
            file = FileManager.default.fileExists(
                atPath: container.appendingPathComponent("Passwords", isDirectory: true)
                    .appendingPathComponent(id).path)
        }
        #if canImport(Security)
        let local = plainKeychainPassword(id) != nil
        #else
        let local = false
        #endif
        return .init(inKeychain: keychain, inFile: file, inLocalKeychain: local,
                     groupID: AppGroup.identifier, groupAvailable: available)
    }
}
