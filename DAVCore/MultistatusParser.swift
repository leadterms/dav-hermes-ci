import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses a WebDAV 207 Multi-Status body.
struct MultistatusParser {
    struct Entry {
        var href: String
        var resource: DAVResource
    }

    static func parse(_ data: Data) throws -> [Entry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { throw DAVError.badResponse }
        return delegate.entries
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []

        private var href: String?
        private var resource = DAVResource(path: "", isDirectory: false)
        private var propstatOK = true
        private var props: [String: String] = [:]
        private var isCollection = false
        private var sawResourceType = false
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "response":
                href = nil
                sawResourceType = false
                resource = DAVResource(path: "", isDirectory: false)
            case "propstat":
                props = [:]
                isCollection = false
                propstatOK = true
            case "collection":
                isCollection = true
            case "resourcetype":
                sawResourceType = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            switch name {
            case "href" where href == nil:
                href = value
            case "status":
                // e.g. "HTTP/1.1 200 OK"; properties in a 404 propstat are just missing.
                propstatOK = value.split(separator: " ").dropFirst().first == "200"
            case "getcontentlength", "getlastmodified", "creationdate", "getetag", "getcontenttype":
                props[name] = value
            case "propstat" where propstatOK:
                if isCollection { resource.isDirectory = true }
                if let size = props["getcontentlength"].flatMap(Int64.init) { resource.size = size }
                if let date = props["getlastmodified"].flatMap(Self.parseHTTPDate) { resource.modified = date }
                if let date = props["creationdate"].flatMap(Self.parseISODate) { resource.created = date }
                if let etag = props["getetag"], !etag.isEmpty { resource.etag = etag }
                if let type = props["getcontenttype"], !type.isEmpty { resource.contentType = type }
            case "response":
                if let href {
                    // Without a resourcetype, fall back to the trailing slash.
                    if !sawResourceType && href.hasSuffix("/") { resource.isDirectory = true }
                    entries.append(Entry(href: href, resource: resource))
                }
            default:
                break
            }
        }

        private static let httpDate: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter
        }()

        static func parseHTTPDate(_ string: String) -> Date? { httpDate.date(from: string) }

        static func parseISODate(_ string: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string)
        }
    }
}
