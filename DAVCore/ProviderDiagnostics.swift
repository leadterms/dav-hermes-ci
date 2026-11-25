import Foundation

/// The last error the Files extension hit, written to the shared group so
/// the app can show it on screen. "Content unavailable" in the Files app
/// gives no detail; this is how the user sees the real cause without a
/// log stream.
public enum ProviderDiagnostics {
    private static func key(_ accountID: String) -> String { "lastProviderError.\(accountID)" }

    public struct Report {
        public let accountID: String
        public let domain: String
        public let code: Int
        public let message: String
        public let when: Date
    }

    public static func record(_ error: Error, forAccountID accountID: String) {
        // The raw error, not the File Provider mapping: DAVCore has no access
        // to the extension's mapper, and the original text is more useful to
        // the user anyway.
        let nsError = error as NSError
        AppGroup.defaults.set([
            "domain": nsError.domain,
            "code": nsError.code,
            "message": (error as? LocalizedError)?.errorDescription ?? nsError.localizedDescription,
            "time": Date().timeIntervalSince1970,
        ], forKey: key(accountID))
    }

    public static func lastError(forAccountID accountID: String) -> Report? {
        guard let raw = AppGroup.defaults.dictionary(forKey: key(accountID)),
              let message = raw["message"] as? String else { return nil }
        let time = raw["time"] as? TimeInterval ?? 0
        return Report(
            accountID: accountID,
            domain: raw["domain"] as? String ?? "",
            code: raw["code"] as? Int ?? 0,
            message: message,
            when: Date(timeIntervalSince1970: time))
    }

    public static func clear(forAccountID accountID: String) {
        AppGroup.defaults.removeObject(forKey: key(accountID))
    }
}
