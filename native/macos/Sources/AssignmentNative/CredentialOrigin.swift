import Foundation
import Security


enum CredentialStoreError: LocalizedError {
    case insecureOrigin
    case invalidOrigin
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .insecureOrigin:
            "Saved credentials are available only for HTTPS websites."
        case .invalidOrigin:
            "The website does not have a valid host."
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain returned error \(status)."
        }
    }
}


enum CredentialOrigin {
    static func value(for url: URL) throws -> String {
        guard url.scheme?.lowercased() == "https" else {
            throw CredentialStoreError.insecureOrigin
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw CredentialStoreError.invalidOrigin
        }
        let normalizedHost = host.contains(":") ? "[\(host)]" : host
        let port = url.port.flatMap { $0 == 443 ? nil : $0 }
        return "https://\(normalizedHost)\(port.map { ":\($0)" } ?? "")"
    }
}
