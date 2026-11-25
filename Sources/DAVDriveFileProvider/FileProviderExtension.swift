import DAVCore
import FileProvider
import UniformTypeIdentifiers

/// One instance per domain; each domain is one account (domain ID = account ID).
/// Info.plist names this class, so keep the Objective-C name stable.
@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let manager: NSFileProviderManager?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        manager = NSFileProviderManager(for: domain)
        super.init()
        // Proof the extension process exists at all: the Files app records no
        // error when the extension simply never launches.
        ProviderDiagnostics.mark("E-OK 已启动 init")
    }

    private func record(_ error: Error) {
        ProviderDiagnostics.record(error, forAccountID: domain.identifier.rawValue)
    }

    func invalidate() {
        ProviderDiagnostics.mark("E-OFF 已退出 invalidate")
    }

    /// Built per call so edits to the account in the app apply right away.
    private func client() throws -> WebDAVClient {
        do {
            return try AccountStore.client(forAccountID: domain.identifier.rawValue)
        } catch {
            record(error)
            throw NSFileProviderError(.notAuthenticated)
        }
    }

    private var rootName: String { domain.displayName }

    private func item(_ resource: DAVResource) -> Item { Item(resource, rootName: rootName) }

    /// Runs `work` in a task tied to a cancellable Progress.
    private func run(_ progress: Progress = Progress(totalUnitCount: 1),
                     _ work: @escaping (Progress) async -> Void) -> Progress {
        let task = Task {
            await work(progress)
            progress.completedUnitCount = progress.totalUnitCount
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    // MARK: Items

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run { [self] _ in
            guard let path = identifier.path else {
                return completionHandler(nil, NSFileProviderError(.noSuchItem))
            }
            do {
                var resource = try await client().stat(path)
                resource.isDirectory = resource.isDirectory || path.isEmpty
                completionHandler(item(resource), nil)
            } catch {
                record(error)
                completionHandler(nil, FileProviderErrors.map(error))
            }
        }
    }

    func fetchContents(for identifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        run(Progress(totalUnitCount: 100)) { [self] progress in
            guard let path = identifier.path, !path.isEmpty else {
                return completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            }
            do {
                let client = try client()
                let resource = try await client.stat(path)
                let directory = try manager?.temporaryDirectoryURL() ?? FileManager.default.temporaryDirectory
                let destination = directory.appending(path: UUID().uuidString)
                try await client.download(path, to: destination, progress: progress)
                completionHandler(destination, item(resource), nil)
            } catch {
                record(error)
                completionHandler(nil, nil, FileProviderErrors.map(error))
            }
        }
    }

    func createItem(basedOn template: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        run(Progress(totalUnitCount: 100)) { [self] progress in
            guard let parent = template.parentItemIdentifier.path else {
                // Nothing can be put in the (nonexistent) trash.
                return completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            }
            let path = Paths.join(parent, template.filename)
            let isFolder = template.contentType == .folder
            do {
                let client = try client()
                if let existing = try? await client.stat(path) {
                    // On a re-import after a reset the item is expected to be there;
                    // otherwise never overwrite: Files then picks a free name.
                    guard options.contains(.mayAlreadyExist) else { throw NSFileProviderError(.filenameCollision) }
                    return completionHandler(item(existing), [], false, nil)
                }
                if isFolder {
                    try await client.createFolder(path)
                } else if template.contentType == .symbolicLink || template.contentType == .aliasFile {
                    throw NSFileProviderError(.noSuchItem)
                } else {
                    try await client.upload(path, from: url, modified: template.contentModificationDate ?? nil, progress: progress)
                }
                var resource = try await client.stat(path)
                resource.isDirectory = resource.isDirectory || isFolder
                completionHandler(item(resource), [], false, nil)
            } catch DAVError.http(status: 405) where isFolder {
                // MKCOL on something that appeared meanwhile.
                completionHandler(nil, [], false, NSFileProviderError(.filenameCollision))
            } catch {
                let error = await changeError(error)
                record(error)
                completionHandler(nil, [], false, error)
            }
        }
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        run(Progress(totalUnitCount: 100)) { [self] progress in
            guard var path = item.itemIdentifier.path, !path.isEmpty,
                  let newParent = item.parentItemIdentifier.path else {
                return completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            }
            let isFolder = item.contentType == .folder
            do {
                let client = try client()
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newPath = Paths.join(newParent, item.filename)
                    if newPath != path {
                        // Servers disagree on the status for a taken name (412, 400...).
                        if (try? await client.stat(newPath)) != nil {
                            throw NSFileProviderError(.filenameCollision)
                        }
                        do {
                            try await client.move(path, to: newPath, isDirectory: isFolder)
                        } catch DAVError.http(status: 412) {
                            // The name was taken between the check and the MOVE.
                            throw NSFileProviderError(.filenameCollision)
                        }
                        path = newPath
                    }
                }
                if changedFields.contains(.contents), !isFolder {
                    try await uploadContents(path: path, from: newContents, item: item,
                                             baseVersion: version, options: options,
                                             client: client, progress: progress)
                }
                var resource = try await client.stat(path)
                resource.isDirectory = resource.isDirectory || isFolder
                // Dates and other metadata can't be set over plain WebDAV; the
                // server's values win.
                completionHandler(self.item(resource), [], false, nil)
            } catch {
                let error = await changeError(error)
                record(error)
                completionHandler(nil, [], false, error)
            }
        }
    }

    /// Uploads new contents without silently overwriting a newer server
    /// version. The base version the system handed us (an ETag when the server
    /// sends one, else a size/mtime pair) is compared with the server's state
    /// now; with `.failOnConflict` a changed file fails as a write conflict so
    /// the system keeps both copies instead of one winning silently.
    private func uploadContents(path: String, from newContents: URL?, item: NSFileProviderItem,
                                baseVersion: NSFileProviderItemVersion,
                                options: NSFileProviderModifyItemOptions,
                                client: WebDAVClient, progress: Progress) async throws {
        // `contentVersion` is a plain `Data` in the 26-generation SDKs and an
        // optional `Data` in newer ones; `as? Data` keeps both compiling.
        let base = (baseVersion.contentVersion as? Data).flatMap { String(data: $0, encoding: .utf8) }
        let current = try await client.stat(path)
        let conflicted = Self.versionChanged(base: base, current: current)
        if conflicted, options.contains(.failOnConflict) {
            throw Self.conflictError()
        }
        // Second gate on the server: claim only the version we just saw.
        let ifMatch = conflicted ? nil : current.etag
        do {
            try await client.upload(path, from: newContents,
                                    modified: item.contentModificationDate ?? nil,
                                    ifMatch: ifMatch, progress: progress)
        } catch DAVError.http(status: 412) {
            // The version moved between our stat and the PUT: that is a
            // version conflict, not a file name collision.
            throw Self.conflictError()
        }
    }

    /// The write-conflict error. The documented iOS 26 code is
    /// `.localVersionConflictingWithServer` (stable across the 26-generation
    /// SDKs; the very latest SDKs additionally expose the `.fileWriteConflict`
    /// spelling).
    private static func conflictError() -> NSFileProviderError {
        NSFileProviderError(.localVersionConflictingWithServer)
    }

    /// Whether the server's state differs from the base version. The base is an
    /// ETag when the server sent one, otherwise Item.itemVersion's size/mtime.
    private static func versionChanged(base: String?, current: DAVResource) -> Bool {
        guard let base, !base.isEmpty else { return false }
        if let etag = current.etag { return etag != base }
        let fallback = "\(current.size ?? -1)-\(current.modified?.timeIntervalSince1970 ?? 0)"
        return base != fallback
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        run { [self] _ in
            guard let path = identifier.path, !path.isEmpty else {
                return completionHandler(NSFileProviderError(.noSuchItem))
            }
            do {
                let client = try client()
                let resource = try await client.stat(path)
                if Trash.isInside(path) {
                    // Emptying the trash: that one is permanent.
                    try await client.delete(path, isDirectory: resource.isDirectory)
                } else {
                    // A normal delete moves the item into the account's own
                    // .davtrash folder (keeping its path), so Files' trash can
                    // restore it. Nothing is destroyed until the trash is emptied.
                    _ = try? await client.createFolder(Trash.path)
                    let target = await Trash.uniqueMoveTarget(for: path) { candidate in
                        (try? await client.stat(candidate)) != nil
                    }
                    try await client.move(path, to: target, isDirectory: resource.isDirectory)
                }
                completionHandler(nil)
            } catch DAVError.http(status: 404) {
                completionHandler(nil) // already gone
            } catch {
                let error = await changeError(error)
                record(error)
                completionHandler(error)
            }
        }
    }

    /// Servers refuse a change the account may not make with 401 or 403
    /// (copyparty answers a rename without its "m" permission with 401). If the
    /// login itself still works, report a permission error for this one item;
    /// "not authenticated" would pause syncing for the whole server.
    private func changeError(_ error: Error) async -> Error {
        if case DAVError.http(let status) = error, status == 401 || status == 403,
           let client = try? client(), (try? await client.stat("")) != nil {
            return CocoaError(.fileWriteNoPermission)
        }
        return FileProviderErrors.map(error)
    }

    // MARK: Enumeration

    func enumerator(for identifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let accountID = domain.identifier.rawValue
        ProviderDiagnostics.mark("E-OK 列举 \(identifier == .rootContainer ? "/" : (identifier.path ?? "?"))")
        do {
            if identifier == .trashContainer {
                return TrashEnumerator(client: try client(), rootName: rootName, accountID: accountID)
            }
            guard let path = identifier.path else { return EmptyEnumerator() }
            return FolderEnumerator(path: path, client: try client(), rootName: rootName, accountID: accountID)
        } catch {
            record(error)
            throw error
        }
    }
}

enum FileProviderErrors {
    /// Maps errors to the File Provider errors the system knows how to handle.
    static func map(_ error: Error) -> Error {
        if error is NSFileProviderError || (error as NSError).domain == NSFileProviderErrorDomain { return error }
        if error is CancellationError { return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
        switch error {
        case DAVError.ignored:
            return NSFileProviderError(.noSuchItem)
        case DAVError.tooManyEntries:
            // A folder too large to list in one go: report it instead of
            // letting the extension run out of memory.
            return NSFileProviderError(.serverUnreachable)
        case DAVError.http(let status):
            // Only errors about the whole server may pause syncing; anything
            // about one item must stay a per-item error.
            switch status {
            case 401: return NSFileProviderError(.notAuthenticated)
            case 403, 423: return CocoaError(.fileWriteNoPermission)
            case 404, 409: return NSFileProviderError(.noSuchItem)
            case 412: return NSFileProviderError(.filenameCollision)
            case 507: return NSFileProviderError(.insufficientQuota)
            case 500...: return NSFileProviderError(.serverUnreachable)
            default: return CocoaError(.fileWriteUnknown)
            }
        case let error as URLError:
            switch error.code {
            case .cancelled: return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            case .notConnectedToInternet, .networkConnectionLost: return NSFileProviderError(.cannotSynchronize)
            case .userAuthenticationRequired: return NSFileProviderError(.notAuthenticated)
            default: return NSFileProviderError(.serverUnreachable)
            }
        default:
            return error
        }
    }
}
