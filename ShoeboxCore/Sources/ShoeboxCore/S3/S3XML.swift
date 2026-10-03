import Foundation

public struct ListObjectsResult: Equatable, Sendable {
    public struct Object: Equatable, Sendable {
        public var key: String
        public var size: Int64
    }

    public var objects: [Object] = []
    public var commonPrefixes: [String] = []
    public var isTruncated = false
    public var nextContinuationToken: String?
}

public struct DeleteObjectsResult: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public var key: String
        public var code: String
        public var message: String
    }

    public var deleted: [String] = []
    public var errors: [Failure] = []
}

public struct S3Error: Error, Equatable, Sendable, CustomStringConvertible {
    public var status: Int
    public var code: String
    public var message: String

    public var description: String {
        code.isEmpty ? "HTTP \(status)" : "HTTP \(status) \(code): \(message)"
    }
}

/// Minimal XML → flat element events. S3 responses are shallow, so we track
/// the element path and collect text per leaf.
final class S3XMLReader: NSObject, XMLParserDelegate {
    typealias Handler = (_ path: [String], _ text: String) -> Void
    typealias OpenHandler = (_ path: [String]) -> Void

    private(set) var path: [String] = []
    private(set) var sawElement = false
    private var text = ""
    private let onLeaf: Handler
    private let onOpen: OpenHandler

    init(onOpen: @escaping OpenHandler = { _ in }, onLeaf: @escaping Handler) {
        self.onOpen = onOpen
        self.onLeaf = onLeaf
    }

    static func read(_ data: Data, onOpen: @escaping OpenHandler = { _ in }, onLeaf: @escaping Handler) -> Bool {
        let reader = S3XMLReader(onOpen: onOpen, onLeaf: onLeaf)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        // Some XMLParser builds accept truncated documents; require every
        // opened element to be closed and at least one element seen.
        return parser.parse() && reader.path.isEmpty && reader.sawElement
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        path.append(elementName)
        sawElement = true
        text = ""
        onOpen(path)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        onLeaf(path, text)
        text = ""
        path.removeLast()
    }
}

enum S3XML {
    static func parseList(_ data: Data) throws -> ListObjectsResult {
        var result = ListObjectsResult()
        var currentKey: String?
        var currentSize: Int64 = 0
        let ok = S3XMLReader.read(data, onOpen: { path in
            if path.last == "Contents" { currentKey = nil; currentSize = 0 }
        }, onLeaf: { path, text in
            switch path.suffix(2) {
            case ["Contents", "Key"]: currentKey = text
            case ["Contents", "Size"]: currentSize = Int64(text) ?? 0
            case ["CommonPrefixes", "Prefix"]: result.commonPrefixes.append(text)
            case ["ListBucketResult", "IsTruncated"]: result.isTruncated = text == "true"
            case ["ListBucketResult", "NextContinuationToken"]: result.nextContinuationToken = text.isEmpty ? nil : text
            default:
                if path.last == "Contents", let key = currentKey {
                    result.objects.append(.init(key: key, size: currentSize))
                }
            }
        })
        guard ok else { throw S3Error(status: 200, code: "MalformedXML", message: "Could not parse ListObjectsV2 response") }
        return result
    }

    static func parseDelete(_ data: Data) throws -> DeleteObjectsResult {
        var result = DeleteObjectsResult()
        var key = "", code = "", message = ""
        let ok = S3XMLReader.read(data, onOpen: { path in
            if path.last == "Error" || path.last == "Deleted" { key = ""; code = ""; message = "" }
        }, onLeaf: { path, text in
            switch path.suffix(2) {
            case ["Deleted", "Key"], ["Error", "Key"]: key = text
            case ["Error", "Code"]: code = text
            case ["Error", "Message"]: message = text
            default:
                if path.suffix(2) == ["DeleteResult", "Deleted"] { result.deleted.append(key) }
                if path.suffix(2) == ["DeleteResult", "Error"] { result.errors.append(.init(key: key, code: code, message: message)) }
            }
        })
        guard ok else { throw S3Error(status: 200, code: "MalformedXML", message: "Could not parse DeleteObjects response") }
        return result
    }

    static func parseError(status: Int, _ data: Data) -> S3Error {
        var code = "", message = ""
        _ = S3XMLReader.read(data, onLeaf: { path, text in
            switch path.suffix(2) {
            case ["Error", "Code"]: code = text
            case ["Error", "Message"]: message = text
            default: break
            }
        })
        return S3Error(status: status, code: code, message: message)
    }

    static func deleteBody(keys: [String]) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Quiet>true</Quiet>"
        for key in keys {
            xml += "<Object><Key>\(escape(key))</Key></Object>"
        }
        xml += "</Delete>"
        return Data(xml.utf8)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}
