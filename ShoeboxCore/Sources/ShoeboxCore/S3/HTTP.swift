import Foundation

/// Plain value type for a request, independent of URLRequest so signing and
/// the client are easy to test.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public var urlRequest: URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        return request
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request.urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key)] = String(describing: value)
                }
                continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }
            task.resume()
        }
    }
}
