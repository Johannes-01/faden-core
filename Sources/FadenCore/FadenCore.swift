import Foundation

public enum FadenCore {
    static let resourceBundleName = "Faden_FadenCore.bundle"

    /// The bundle holding the prompts and styles. Use this instead of `Bundle.module`.
    ///
    /// SwiftPM's generated accessor only looks at the .app root and at the absolute `.build` path, and traps
    /// when neither exists. `scripts/bundle.sh` puts the bundle in `Contents/Resources`, so look there first.
    public static let resources: Bundle = resourceBundle(mainResourceURL: Bundle.main.resourceURL)

    static func resourceBundle(mainResourceURL: URL?) -> Bundle {
        if let url = mainResourceURL?.appending(path: resourceBundleName, directoryHint: .isDirectory),
           FileManager.default.fileExists(atPath: url.path),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }
}
