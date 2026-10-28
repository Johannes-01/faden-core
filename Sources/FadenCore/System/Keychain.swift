import Foundation
import Security

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus

    public var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(text)"
    }
}

/// Whether a usable API key is stored. A missing key and a Keychain that can't be read are told apart,
/// so the app only asks the user to add a key when there really is none.
public enum APIKeyStatus: Equatable, Sendable {
    case present
    /// No item, or a blank one.
    case missing
    /// The Keychain returned this error, e.g. access was denied after a rebuild changed the signature.
    case unreadable(OSStatus)

    public var isPresent: Bool { self == .present }

    /// The line the popover shows, nil when a key is present.
    public var problem: String? {
        switch self {
        case .present: nil
        case .missing: "No API key — add one in Settings"
        case .unreadable(let status): "Couldn't read the API key from the Keychain (\(status))"
        }
    }
}

/// The Anthropic API key, stored as a generic password item in the login Keychain.
public enum Keychain {
    static let service = FadenCore.identifier
    static let defaultAccount = "anthropic-api-key"

    /// The stored key, or nil for "not found" and for any Keychain error. Use `readResult()` to tell them apart.
    public static func read() -> String? { read(account: defaultAccount) }
    /// The stored key, or nil when there is none (`errSecItemNotFound`). Other failures throw `KeychainError`.
    public static func readResult() throws -> String? { try readResult(account: defaultAccount) }
    public static func write(_ key: String) throws { try write(key, account: defaultAccount) }
    public static func delete() throws { try delete(account: defaultAccount) }

    /// The one "is a key stored?" check, shared by the popover and Settings.
    public static func keyStatus() -> APIKeyStatus { keyStatus(reading: readResult) }

    static func keyStatus(reading: () throws -> String?) -> APIKeyStatus {
        do {
            let key = try reading()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return key.isEmpty ? .missing : .present
        } catch let error as KeychainError {
            return .unreadable(error.status)
        } catch {
            return .unreadable(errSecInternalError)
        }
    }

    static func read(account: String) -> String? {
        (try? readResult(account: account)) ?? nil
    }

    static func readResult(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try value(status: status, result: result)
    }

    /// Maps a `SecItemCopyMatching` outcome: the key, nil for "not found", or a thrown `KeychainError`.
    static func value(status: OSStatus, result: CFTypeRef?) throws -> String? {
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw KeychainError(status: errSecDecode)
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    static func write(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        default:
            throw KeychainError(status: update)
        }
    }

    /// Deleting an item that doesn't exist is not an error.
    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
