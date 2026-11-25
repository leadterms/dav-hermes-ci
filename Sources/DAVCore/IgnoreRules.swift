import Foundation

/// Names that never show up in the tree and are never expanded.
///
/// Why: a folder like `node_modules` or `.git` can hold tens of thousands of
/// entries; the File Provider extension lists a whole folder per request and
/// its memory is capped, so unfiltered build trees are the main OOM risk.
/// The rules only hide server content — nothing about the server is stored
/// locally beyond what the system materializes on demand.
public struct IgnoreRules: Sendable {
    /// Directory names, matched at any depth; the directory itself is hidden
    /// and never expanded.
    public let directories: Set<String>
    /// File names, matched at any depth.
    public let files: Set<String>

    public init(directories: Set<String>, files: Set<String>) {
        self.directories = directories
        self.files = files
    }

    /// The built-in list: common build/source-control trees, plus the trash.
    public static let standard = IgnoreRules(
        directories: [
            "node_modules", ".git", ".hg", ".svn",
            ".build", "build", "dist", "out", "target", "DerivedData",
            ".next", ".nuxt", ".gradle", ".m2", "__pycache__",
            ".venv", "venv", "env", "Pods", ".idea", ".vscode",
            Trash.path,
        ],
        files: [".DS_Store"]
    )

    /// The rules in force: a user override (hosted in the app, shared via the
    /// app group) or the standard list.
    public static func load() -> IgnoreRules {
        guard AppGroup.defaults.object(forKey: "ignoreDirectories") != nil else { return .standard }
        return IgnoreRules(
            directories: Set(AppGroup.defaults.stringArray(forKey: "ignoreDirectories") ?? []),
            files: Set(AppGroup.defaults.stringArray(forKey: "ignoreFiles") ?? [])
        )
    }

    public static func saveDirectories(_ names: [String]) {
        AppGroup.defaults.set(names, forKey: "ignoreDirectories")
    }

    public static func saveFiles(_ names: [String]) {
        AppGroup.defaults.set(names, forKey: "ignoreFiles")
    }

    // MARK: Matching

    /// A child entry in a listing: hidden when its own name is ignored.
    public func isIgnored(_ name: String, isDirectory: Bool) -> Bool {
        isDirectory ? directories.contains(name) : files.contains(name)
    }

    /// A full path: hidden when any component is an ignored directory or the
    /// final component is an ignored file name. The trash is exempt — its
    /// contents are reachable through the trash container.
    public func isIgnoredPath(_ path: String) -> Bool {
        if Trash.isInside(path) { return false }
        let components = path.split(separator: "/").map(String.init)
        for name in components.dropLast() where directories.contains(name) {
            return true
        }
        return components.last.map { files.contains($0) } ?? false
    }
}
