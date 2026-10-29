import Foundation

public enum FadenCore {
    /// The Faden app's reverse-DNS identifier: the log subsystem and the Keychain service, so the `faden`
    /// CLI uses the API key the app stored. The app's `CFBundleIdentifier` must stay equal to it.
    public static let identifier = "io.github.johannes-01.faden"

    /// SwiftPM's name for the bundle: `<package name>_<target name>`. An app that bundles FadenCore copies it
    /// into `Contents/Resources` under this name.
    public static let resourceBundleName = "faden-core_FadenCore.bundle"

    /// The bundle holding the prompts and styles. Use this instead of `Bundle.module`.
    ///
    /// SwiftPM's generated accessor only looks at the .app root and at the absolute `.build` path, and traps
    /// when neither exists. An app puts the bundle in `Contents/Resources`, so look there first.
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
