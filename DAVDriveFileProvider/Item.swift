import DAVCore
import FileProvider
import UniformTypeIdentifiers

/// Items are identified by their path relative to the account's base folder,
/// with the base folder itself being the root container.
extension NSFileProviderItemIdentifier {
    init(path: String) {
        self = path.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(path)
    }

    /// nil for the trash and the working set, which don't exist on the server.
    var path: String? {
        switch self {
        case .rootContainer: ""
        case .trashContainer, .workingSet: nil
        default: rawValue
        }
    }
}

enum Paths {
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }
}

/// Subclassed by TrashItem, which reports the trash container as its parent.
class Item: NSObject, NSFileProviderItem {
    let resource: DAVResource
    private let rootName: String

    init(_ resource: DAVResource, rootName: String) {
        self.resource = resource
        self.rootName = rootName
    }

    var itemIdentifier: NSFileProviderItemIdentifier { .init(path: resource.path) }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        resource.path.isEmpty ? .rootContainer : .init(path: Paths.parent(of: resource.path))
    }

    var filename: String { resource.path.isEmpty ? rootName : resource.name }

    var contentType: UTType {
        if resource.isDirectory { return .folder }
        return UTType(filenameExtension: (resource.name as NSString).pathExtension)
            ?? resource.contentType.flatMap { UTType(mimeType: $0) }
            ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading]
        if resource.isDirectory {
            capabilities.formUnion([.allowsContentEnumerating, .allowsAddingSubItems])
        } else {
            capabilities.insert(.allowsWriting)
        }
        if !resource.path.isEmpty {
            // Delete moves the item into the account's own .davtrash folder
            // (see FileProviderExtension.deleteItem), so a mistaken delete can
            // be undone from the Files trash.
            capabilities.formUnion([.allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsTrashing])
        }
        return capabilities
    }

    var documentSize: NSNumber? { resource.size.map { NSNumber(value: $0) } }
    var contentModificationDate: Date? { resource.modified }
    var creationDate: Date? { resource.created ?? resource.modified }

    /// The ETag when the server sends one, else size and modification date.
    var itemVersion: NSFileProviderItemVersion {
        let content = resource.etag
            ?? "\(resource.size ?? -1)-\(resource.modified?.timeIntervalSince1970 ?? 0)"
        let metadata = content + "|" + resource.path
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data(metadata.utf8))
    }
}
