import Foundation

/// The account-local folder that stands in for the server-side trash.
/// It is always hidden from the normal tree; only the trash container shows it.
public enum Trash {
    public static let path = ".davtrash"

    public static func isInside(_ path: String) -> Bool {
        path == Trash.path || path.hasPrefix(Trash.path + "/")
    }

    /// Where `path` is moved when it is trashed. A timestamp suffix keeps the
    /// name unique when two items trashed at different times would collide.
    public static func moveTarget(for path: String) -> String {
        path.hasPrefix(Trash.path + "/") ? path : Trash.path + "/" + path
    }

    /// A unique trash target: suffixes the last component when taken.
    public static func uniqueMoveTarget(for path: String, isTaken: @escaping (String) async -> Bool) async -> String {
        var target = moveTarget(for: path)
        if await isTaken(target) {
            let stamp = String(Int(Date().timeIntervalSince1970))
            if let lastSlash = target.lastIndex(of: "/") {
                target = String(target[...lastSlash]) + stamp + "-" + String(target[target.index(after: lastSlash)...])
            } else {
                target = stamp + "-" + target
            }
        }
        return target
    }
}
