import Foundation
import CryptoKit

/// Thin wrapper so the rest of the code never imports CryptoKit directly.
enum Digest {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha256Hex(_ data: Data) -> String {
        sha256(data).hexString
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func hmacSHA256(key: Data, message: String) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// S3 DeleteObjects requires a Content-MD5 header.
    static func md5Base64(_ data: Data) -> String {
        Data(Insecure.MD5.hash(data: data)).base64EncodedString()
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
