import DAVCore
import FileProvider

/// Lists one folder. The server can't report changes, so asking for changes
/// always answers "anchor expired", which makes the system list the folder
/// again and work out the differences itself.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let path: String
    private let client: WebDAVClient
    private let rootName: String
    private let accountID: String
    private var task: Task<Void, Never>?

    init(path: String, client: WebDAVClient, rootName: String, accountID: String) {
        self.path = path
        self.client = client
        self.rootName = rootName
        self.accountID = accountID
    }

    func invalidate() { task?.cancel() }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        task = Task {
            do {
                let items = try await client.list(path)
                    .filter { !$0.path.isEmpty }
                    .map { Item($0, rootName: rootName) }
                // One page is enough; the system splits the batch as it likes.
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                ProviderDiagnostics.record(error, forAccountID: accountID)
                observer.finishEnumeratingWithError(FileProviderErrors.map(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(SyncAnchor.now)
    }
}

/// The working set and the trash: always empty, never any changes.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("0".utf8)))
    }
}

enum SyncAnchor {
    static var now: NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
    }
}

/// The trash container: lists what the account's own .davtrash folder holds.
/// Items report the trash as their parent, so Files shows them under Trash and
/// can move them back out again.
final class TrashEnumerator: NSObject, NSFileProviderEnumerator {
    private let client: WebDAVClient
    private let rootName: String
    private let accountID: String
    private var task: Task<Void, Never>?

    init(client: WebDAVClient, rootName: String, accountID: String) {
        self.client = client
        self.rootName = rootName
        self.accountID = accountID
    }

    func invalidate() { task?.cancel() }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        task = Task {
            do {
                let children = try await client.list(Trash.path)
                let items = children.map { child -> Item in
                    var resource = child
                    resource.path = Paths.join(Trash.path, child.path)
                    return TrashItem(resource, rootName: rootName)
                }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch DAVError.http(status: 404) {
                // No .davtrash folder on the server yet: the trash is empty.
                observer.finishEnumerating(upTo: nil)
            } catch {
                ProviderDiagnostics.record(error, forAccountID: accountID)
                observer.finishEnumeratingWithError(FileProviderErrors.map(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(SyncAnchor.now)
    }
}

/// A trashed item: same server path (inside .davtrash), shown under Trash.
final class TrashItem: Item {
    override var parentItemIdentifier: NSFileProviderItemIdentifier { .trashContainer }
}
