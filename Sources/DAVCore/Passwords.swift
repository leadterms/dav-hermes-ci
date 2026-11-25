import Foundation

/// Passwords that survive an app reinstall.
///
/// The Keychain copy is erased when the app is uninstalled, so after a
/// fresh install the editor would show an empty password and the File
/// Provider would authenticate with nothing. The app-group container is
/// *not* removed on uninstall, so a protected file in it is the durable
/// store; the Keychain stays as a fast, best-effort copy.
public enum Passwords {
    private static func url(for id: String) -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else { return nil }
        return container.appendingPathComponent("Passwords", isDirectory: true)
            .appendingPathComponent(id)
    }

    /// Keychain first (fast path), then the surviving app-group file.
    public static func password(for id: String) -> String? {
        if let keychain = Keychain.password(for: id) { return keychain }
        guard let url = url(for: id),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Store the durable app-group copy, then the Keychain. A missing
    /// keychain-access-groups entitlement only disables the copy; the file
    /// keeps the password usable.
    public static func write(_ password: String, for id: String) {
        guard let url = url(for: id) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = password.data(using: .utf8) {
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
            } catch {
                try? FileManager.default.removeItem(at: tmp)
            }
        }
        Keychain.setPassword(password, for: id)
    }

    public static func delete(for id: String) {
        Keychain.deletePassword(for: id)
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
        return .init(inKeychain: keychain, inFile: file,
                     groupID: AppGroup.identifier, groupAvailable: available)
    }
}
