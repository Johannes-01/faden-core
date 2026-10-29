import FadenCore
import FadenTranscription
import Foundation
import Security

enum CLIError: Error, Equatable, LocalizedError {
    /// No style matches; carries the argument and the ids there are.
    case unknownStyle(String, [String])
    /// Several styles start with the argument; carries it and their ids.
    case ambiguousStyle(String, [String])
    /// No API key in the environment or the Keychain.
    case missingKey
    /// The Keychain returned this error reading the key.
    case keyUnreadable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unknownStyle(let arg, let ids): "No note style \"\(arg)\". Styles: \(ids.joined(separator: ", "))"
        case .ambiguousStyle(let arg, let ids): "\"\(arg)\" matches several styles: \(ids.joined(separator: ", "))"
        case .missingKey: "No Anthropic API key: set ANTHROPIC_API_KEY, or use --subscription to go through the claude CLI"
        case .keyUnreadable(let status):
            "Couldn't read the API key from the Keychain (\(status)); set ANTHROPIC_API_KEY instead"
        }
    }
}

/// Which style file a `--style` argument means.
enum StyleChoice {
    /// The id equal to `arg`, or the one id starting with `arg-` (so `C` means `C-red-line`), ignoring case.
    static func id(for arg: String, among ids: [String]) throws -> String {
        if let exact = ids.first(where: { $0.caseInsensitiveCompare(arg) == .orderedSame }) { return exact }
        let prefix = arg.lowercased() + "-"
        let matches = ids.filter { $0.lowercased().hasPrefix(prefix) }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw CLIError.unknownStyle(arg, ids)
        default: throw CLIError.ambiguousStyle(arg, matches)
        }
    }
}

/// Where the notes and check calls go.
enum ClientChoice {
    /// The local `claude` CLI with `subscription`; otherwise the API with `ANTHROPIC_API_KEY`, or else the key
    /// the app stored in the Keychain. Throws without a key, so nothing is transcribed for a run that can't finish.
    static func make(subscription: Bool, environment: [String: String],
                     keychain: () throws -> String? = Keychain.readResult) throws -> MessageSending {
        if subscription { return ClaudeCLIClient() }
        if let key = environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return AnthropicClient(apiKey: key)
        }
        let key: String
        do {
            key = try keychain()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            throw CLIError.keyUnreadable((error as? KeychainError)?.status ?? errSecInternalError)
        }
        guard !key.isEmpty else { throw CLIError.missingKey }
        return AnthropicClient(apiKey: key)
    }
}

extension TranscriptionModel {
    /// The model a state was transcribed with (`PipelineState.transcriptionModel` holds the variant), if known.
    init?(variant: String) {
        guard let model = Self.allCases.first(where: { $0.whisperKitVariant == variant }) else { return nil }
        self = model
    }
}
