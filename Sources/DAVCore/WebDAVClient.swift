import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// A file or folder on a WebDAV server.
public struct DAVResource: Sendable, Hashable {
    /// Path relative to the account's base URL, without leading or trailing
    /// slashes; "" is the base folder itself.
    public var path: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    public var created: Date?
    public var etag: String?
    public var contentType: String?

    public var name: String { path.split(separator: "/").last.map(String.init) ?? "" }
}

public enum DAVError: LocalizedError, Sendable {
    case invalidURL
    case http(status: Int)
    case badResponse
    case ignored
    case tooManyEntries(count: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The server address isn't a valid URL."
        case .http(let status) where status == 401 || status == 403:
            "The server rejected the user name or password (HTTP \(status))."
        case .http(404): "Not found on the server (HTTP 404)."
        case .http(405): "The server doesn't allow that here (HTTP 405). Is this a WebDAV address?"
        case .http(let status): "The server answered HTTP \(status)."
        case .badResponse: "The server's reply isn't valid WebDAV."
        case .ignored: "The item is hidden by the ignore rules."
        case .tooManyEntries(let count):
            "The folder has \(count) items, more than this app lists at once. Narrow it down or add it to the ignore list."
        }
    }

    public var status: Int? {
        if case .http(let status) = self { return status }
        return nil
    }
}

/// A small WebDAV client: PROPFIND, GET, PUT, MKCOL, DELETE and MOVE.
///
/// An account may be reachable at two endpoints: the on-LAN address and the
/// fixed public (Cloudflare) address. Every request goes to the preferred one;
/// a network-level failure switches to the other and retries once. HTTP
/// answers (4xx/5xx) never switch — the address was reached.
public final class WebDAVClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoints: [Endpoint]
    private let byHost: [String: Endpoint]
    private let ignoreRules: IgnoreRules
    private let lock = NSLock()
    private var mode: EndpointMode
    private let onModeChange: ((EndpointMode) -> Void)?
    private var session: URLSession!

    /// A folder listing beyond this many (visible) entries fails with a clear
    /// error instead of exhausting the File Provider extension's memory.
    public static let maxEntries = 20_000

    public init(endpoints: [Endpoint], startMode: EndpointMode,
                ignoreRules: IgnoreRules = .load(),
                onModeChange: ((EndpointMode) -> Void)? = nil) {
        precondition(!endpoints.isEmpty, "A client needs at least one endpoint")
        self.endpoints = endpoints
        self.byHost = Dictionary(endpoints.map { ($0.url.host() ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        self.ignoreRules = ignoreRules
        self.onModeChange = onModeChange
        // The preferred mode must exist; otherwise use whichever endpoint does.
        if endpoints.contains(where: { $0.isWan == (startMode == .wan) }) {
            self.mode = startMode
        } else {
            self.mode = endpoints.contains(where: { !$0.isWan }) ? .lan : .wan
        }
        super.init()
        let configuration = URLSessionConfiguration.default
        // An upper bound; requests carry their own timeout (URLRequest defaults to
        // 60 s, slow folder operations ask for more).
        configuration.timeoutIntervalForRequest = Self.slowOperationTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: Endpoints

    public var currentMode: EndpointMode {
        lock.lock(); defer { lock.unlock() }
        return mode
    }

    private func endpoint(for wanted: EndpointMode) -> Endpoint {
        endpoints.first { $0.isWan == (wanted == .wan) } ?? endpoints[0]
    }

    private func switchMode(to newMode: EndpointMode) {
        lock.lock()
        let changed = mode != newMode
        mode = newMode
        lock.unlock()
        if changed { onModeChange?(newMode) }
    }

    /// Runs `work` against the preferred endpoint; on a network-level failure
    /// (no answer at all) it retries once against the other one.
    private func perform<T>(_ work: (Endpoint) async throws -> T) async throws -> T {
        let preferred = currentMode
        do {
            return try await work(endpoint(for: preferred))
        } catch {
            guard endpoints.count > 1, Self.isNetworkLevel(error) else { throw error }
            let fallback = preferred.other
            let value = try await work(endpoint(for: fallback))
            switchMode(to: fallback)
            return value
        }
    }

    /// No connection at all: the address could not be reached. Redirects we
    /// refused count too (they surface as `.cancelled`).
    static func isNetworkLevel(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .timedOut, .resourceUnavailable,
             .dataNotAllowed, .cancelled:
            return true
        default:
            return false
        }
    }

    // MARK: URLs

    public func url(for path: String, isDirectory: Bool, endpoint: Endpoint) -> URL {
        if path.isEmpty { return endpoint.url }
        return endpoint.url.appending(path: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    // MARK: Requests

    /// The resource at `path` itself.
    public func stat(_ path: String) async throws -> DAVResource {
        try checkNotIgnored(path)
        return try await perform { endpoint in
            // No trailing slash: servers answer for a folder too (or redirect to
            // "folder/", which keeps the method, see below), while "file/" can 404.
            let resources = try await self.propfind(path, depth: "0", isDirectory: path.isEmpty, endpoint: endpoint)
            guard let resource = resources.first(where: { $0.path == path }) ?? resources.first else {
                throw DAVError.badResponse
            }
            return resource
        }
    }

    /// The direct children of the folder at `path`, minus ignored names.
    public func list(_ path: String) async throws -> [DAVResource] {
        try checkNotIgnored(path)
        return try await perform { endpoint in
            let children = try await self.propfind(path, depth: "1", isDirectory: true, endpoint: endpoint)
                .filter { $0.path != path }
            let visible = children.filter { !self.ignoreRules.isIgnored($0.name, isDirectory: $0.isDirectory) }
            if visible.count > Self.maxEntries {
                throw DAVError.tooManyEntries(count: visible.count)
            }
            return visible
        }
    }

    /// Downloads the file at `path` into `destination` (which must not exist).
    public func download(_ path: String, to destination: URL, progress: Progress? = nil) async throws {
        try await perform { endpoint in
            let request = self.makeRequest("GET", self.url(for: path, isDirectory: false, endpoint: endpoint), endpoint: endpoint)
            #if canImport(FoundationNetworking)
            // swift-corelibs-foundation (Linux, used for tests) writes the body
            // twice when a download has a task delegate.
            let (temporary, response) = try await self.session.download(for: request)
            #else
            let (temporary, response) = try await self.session.download(for: request, delegate: ProgressDelegate(progress))
            #endif
            try self.check(response)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// Uploads `file` (or an empty file when nil) to `path`, replacing what's
    /// there. `ifMatch` sends the ETag the upload is based on, so the server
    /// rejects an upload whose base version is gone (412).
    public func upload(_ path: String, from file: URL?, modified: Date? = nil,
                       ifMatch: String? = nil, progress: Progress? = nil) async throws {
        try await perform { endpoint in
            var request = self.makeRequest("PUT", self.url(for: path, isDirectory: false, endpoint: endpoint), endpoint: endpoint)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
            // ownCloud, Nextcloud and copyparty keep this as the file's modification
            // date; copyparty also only replaces an existing file when it is sent.
            let mtime = modified
                ?? file.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                ?? Date()
            request.setValue(String(Int(mtime.timeIntervalSince1970)), forHTTPHeaderField: "X-OC-Mtime")
            let response: URLResponse
            if let file {
                (_, response) = try await self.session.upload(for: request, fromFile: file, delegate: ProgressDelegate(progress))
            } else {
                (_, response) = try await self.session.upload(for: request, from: Data())
            }
            try self.check(response)
        }
    }

    /// Folder operations can make a server walk or reindex the whole tree
    /// before it answers (copyparty waits for a running rescan), so give them
    /// longer than the 60 s other requests get.
    static let slowOperationTimeout: TimeInterval = 300

    public func createFolder(_ path: String) async throws {
        try await perform { endpoint in
            var request = self.makeRequest("MKCOL", self.url(for: path, isDirectory: true, endpoint: endpoint), endpoint: endpoint)
            request.timeoutInterval = Self.slowOperationTimeout
            _ = try await self.send(request)
        }
    }

    public func delete(_ path: String, isDirectory: Bool) async throws {
        try await perform { endpoint in
            var request = self.makeRequest("DELETE", self.url(for: path, isDirectory: isDirectory, endpoint: endpoint), endpoint: endpoint)
            request.timeoutInterval = Self.slowOperationTimeout
            _ = try await self.send(request)
        }
    }

    public func move(_ path: String, to newPath: String, isDirectory: Bool) async throws {
        try await perform { endpoint in
            var request = self.makeRequest("MOVE", self.url(for: path, isDirectory: isDirectory, endpoint: endpoint), endpoint: endpoint)
            request.timeoutInterval = Self.slowOperationTimeout
            request.setValue(self.url(for: newPath, isDirectory: isDirectory, endpoint: endpoint).absoluteString,
                             forHTTPHeaderField: "Destination")
            request.setValue("F", forHTTPHeaderField: "Overwrite")
            _ = try await self.send(request)
        }
    }

    // MARK: Connection test

    /// Used by the app's editor: tries each endpoint in order and reports the
    /// mode that answered plus the number of items at the root.
    public static func testConnection(endpoints: [Endpoint]) async throws -> (mode: EndpointMode, items: Int) {
        var lastError: Error = DAVError.invalidURL
        for endpoint in endpoints {
            do {
                let client = WebDAVClient(endpoints: [endpoint],
                                          startMode: endpoint.isWan ? .wan : .lan,
                                          ignoreRules: .load())
                let root = try await client.stat("")
                guard root.isDirectory else { throw DAVError.badResponse }
                let items = try await client.list("").count
                return (endpoint.isWan ? .wan : .lan, items)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Plumbing

    private func checkNotIgnored(_ path: String) throws {
        if ignoreRules.isIgnoredPath(path) { throw DAVError.ignored }
    }

    private func propfind(_ path: String, depth: String, isDirectory: Bool,
                          endpoint: Endpoint) async throws -> [DAVResource] {
        var request = makeRequest("PROPFIND", url(for: path, isDirectory: isDirectory, endpoint: endpoint), endpoint: endpoint)
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop>
        <d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:creationdate/><d:getetag/><d:getcontenttype/>
        </d:prop></d:propfind>
        """.utf8)
        let (data, response) = try await session.data(for: request)
        try check(response)
        let basePath = endpoint.url.path(percentEncoded: false)
        return try MultistatusParser.parse(data).compactMap { entry in
            guard let path = Self.relativePath(href: entry.href, basePath: basePath) else { return nil }
            var resource = entry.resource
            resource.path = path
            return resource
        }
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    private func makeRequest(_ method: String, _ url: URL, endpoint: Endpoint) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let authorization = endpoint.basicAuthorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        // Cloudflare Access rides only on the public endpoint; empty until the
        // login / service-token work lands (single injection point).
        for (name, value) in endpoint.cfAccessHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw DAVError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw DAVError.http(status: http.statusCode) }
    }

    /// Turns an href (absolute URL or absolute path, percent-encoded) into a
    /// path relative to the base folder, or nil when it lies outside it.
    static func relativePath(href: String, basePath: String) -> String? {
        let path: String
        if let url = URL(string: href), url.scheme != nil {
            path = url.path(percentEncoded: false)
        } else {
            path = href.removingPercentEncoding ?? href
        }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.isEmpty { return trimmed }
        if trimmed == base { return "" }
        guard trimmed.hasPrefix(base + "/") else { return nil }
        return String(trimmed.dropFirst(base.count + 1))
    }

    /// URLSession turns redirected requests into GETs; WebDAV requests must
    /// keep their method, headers and body (servers redirect "folder" to "folder/").
    /// Redirects to another host are refused outright: credentials (Basic now,
    /// Cloudflare Access later) must never leave the host they were made for.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest, let url = request.url else {
            return completionHandler(request)
        }
        guard url.host() == original.url?.host() else {
            return completionHandler(nil)
        }
        guard original.httpMethod != "GET" else {
            return completionHandler(request)
        }
        var redirected = original
        redirected.url = url
        completionHandler(redirected)
    }

    /// A pinned certificate, when the account has one, must be presented by the
    /// endpoint's host on top of normal validation. Nothing else is trusted.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let host = task.originalRequest?.url?.host(),
           let pinned = byHost[host]?.pinnedCertificate,
           let trust = challenge.protectionSpace.serverTrust,
           let certificate = Self.certificate(from: pinned),
           Self.verifies(trust: trust, certificate: certificate) {
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }

    #if canImport(Security)
    /// Parses a PEM ("-----BEGIN CERTIFICATE-----") or DER certificate.
    private static func certificate(from data: Data) -> SecCertificate? {
        var der = data
        if let text = String(data: data, encoding: .utf8), text.contains("BEGIN CERTIFICATE") {
            let base64 = text
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            guard let decoded = Data(base64Encoded: base64) else { return nil }
            der = decoded
        }
        guard !der.isEmpty, let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return certificate
    }

    /// The pinned certificate is the only accepted anchor: the server's
    /// certificate must match it (self-signed) or chain to it.
    ///
    /// Built from certificate-parsing APIs only, because DAVCore compiles with
    /// APPLICATION_EXTENSION_API_ONLY: YES, which excludes the trust-anchor
    /// manipulation APIs (`SecTrustCreate(_:anchors:)`, and on older SDKs
    /// `SecTrustSetPinnedCertificates`/`SecTrustSetAnchorOnly` entirely).
    ///
    /// A presented certificate whose DER bytes equal the pinned certificate's
    /// DER bytes is the trusted anchor — a self-signed leaf, or the
    /// self-signed root/CA the server serves in its chain (standard practice
    /// for a private/self-signed CA; if a server omits its root, install the
    /// root on that server side). An exact DER-byte match is the acceptance
    /// test — the pinned certificate is the only trusted anchor, and it is
    /// inside the server's presented chain (a self-signed root/CA must be
    /// served in the chain, since no system trust store contains it). No
    /// separate validity check: an expired/reissued pin simply stops matching
    /// and is rejected until the user imports the new certificate.
    private static func verifies(trust: SecTrust, certificate: SecCertificate) -> Bool {
        let pinned = SecCertificateCopyData(certificate) as Data
        for i in 0..<SecTrustGetCertificateCount(trust) {
            guard let chainCert = SecTrustGetCertificateAtIndex(trust, i) else { continue }
            if SecCertificateCopyData(chainCert) as Data == pinned {
                return true
            }
        }
        return false
    }
    #endif
}

/// Feeds byte counts of one transfer into a `Progress`.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: Progress?
    init(_ progress: Progress?) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        update(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    private func update(_ done: Int64, _ total: Int64) {
        guard let progress, total > 0 else { return }
        progress.totalUnitCount = total
        progress.completedUnitCount = done
    }
}
