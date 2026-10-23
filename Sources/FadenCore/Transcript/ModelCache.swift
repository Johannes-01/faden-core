import Foundation

/// Where WhisperKit 1.1.x keeps downloaded models, used to tell "downloading the speech model"
/// apart from "transcribing". WhisperKit (via its Hub client) downloads
/// `argmaxinc/whisperkit-coreml` variant `<v>` into
/// `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-<v>/`.
/// A model counts as present when the config and every Core ML model's compiled data and weights
/// are there; a partial download is not.
public enum ModelCache {
    public static var defaultBase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/huggingface", isDirectory: true)
    }

    static let requiredFiles = [
        "config.json",
        "MelSpectrogram.mlmodelc/coremldata.bin",
        "MelSpectrogram.mlmodelc/weights/weight.bin",
        "AudioEncoder.mlmodelc/coremldata.bin",
        "AudioEncoder.mlmodelc/weights/weight.bin",
        "TextDecoder.mlmodelc/coremldata.bin",
        "TextDecoder.mlmodelc/weights/weight.bin",
    ]

    public static func folder(variant: String, base: URL = ModelCache.defaultBase) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)", isDirectory: true)
    }

    public static func isDownloaded(variant: String, base: URL = ModelCache.defaultBase) -> Bool {
        let folder = folder(variant: variant, base: base)
        return requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}
