import Foundation

/// Reads/writes coastty's session snapshot, modelled on herdr's
/// `src/persist/io.rs`: atomic write via temp file + swap, own file
/// instead of AppKit's opaque restoration state.
enum CoasttySessionPersistence {
    /// The release build's bundle identifier - only it migrates the legacy shared session file.
    private static let releaseBundleID = "com.espensteen.coastty"

    /// Falls back to the temp directory on the vanishingly unlikely chance Application Support isn't available.
    private static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Namespaced by bundle identifier so dev and production builds don't share and clobber one session file.
    private static var sessionFileURL: URL {
        sessionFileURL(forBundleID: Bundle.main.bundleIdentifier, in: applicationSupportDirectory)
    }

    /// The bundle-ID-to-path mapping `sessionFileURL` uses, pulled out as a pure function so it's testable without touching the real Application Support directory or `Bundle.main`.
    static func sessionFileURL(forBundleID bundleID: String?, in base: URL) -> URL {
        base
            .appendingPathComponent(bundleID ?? releaseBundleID, isDirectory: true)
            .appendingPathComponent("session.json")
    }

    /// The pre-namespacing session path every coastty build used to share.
    private static var legacySessionFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("Coastty", isDirectory: true).appendingPathComponent("session.json")
    }

    /// Mirrors herdr's `snapshot_file_version` peek.
    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// Encodes `snapshot` to JSON - kept separate from `save(_:)` so callers can encode on the main thread and hand off only `Data`.
    static func encode(_ snapshot: CoasttySessionSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try? encoder.encode(snapshot)
    }

    static func save(_ data: Data) {
        let url = sessionFileURL
        let directory = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let tempURL = url.appendingPathExtension("tmp")
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            // Best-effort, same as herdr.
        }
    }

    // MARK: Window layouts

    /// Where a window's own presentation lives - deliberately not `session.json`.
    ///
    /// The structure it used to hold now belongs to the daemon, but leaving that
    /// file untouched means reverting to a build from before this change still
    /// finds the session it wrote, rather than a file it would refuse to read.
    private static var layoutFileURL: URL {
        sessionFileURL.deletingLastPathComponent().appendingPathComponent("layout.json")
    }

    static func encodeLayouts(_ layouts: [CoasttyWindowLayout]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try? encoder.encode(layouts)
    }

    static func saveLayouts(_ data: Data) {
        write(data, to: layoutFileURL)
    }

    static func loadLayouts() -> [CoasttyWindowLayout] {
        guard let data = try? Data(contentsOf: layoutFileURL) else { return [] }
        return (try? JSONDecoder().decode([CoasttyWindowLayout].self, from: data)) ?? []
    }

    /// Writes atomically, creating the directory if it is not there. Best-effort, same as herdr.
    private static func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let tempURL = url.appendingPathExtension("tmp")
            try data.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {}
    }

    static func clear() {
        try? FileManager.default.removeItem(at: sessionFileURL)
    }

    /// Nil if there's no snapshot, it can't be read, or it's from a newer
    /// coastty version than this one understands.
    static func load() -> CoasttySessionSnapshot? {
        let url = sessionFileURL
        migrateLegacySessionFileIfNeeded(to: url)
        guard let data = try? Data(contentsOf: url) else { return nil }

        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           probe.version > CoasttySessionSnapshot.currentVersion {
            return nil
        }

        return try? JSONDecoder().decode(CoasttySessionSnapshot.self, from: data)
    }

    /// One-time adoption of the legacy shared session file into this build's own namespaced path, release only.
    private static func migrateLegacySessionFileIfNeeded(to destination: URL) {
        let legacyURL = legacySessionFileURL
        guard shouldMigrateLegacySessionFile(
            bundleID: Bundle.main.bundleIdentifier,
            destinationExists: FileManager.default.fileExists(atPath: destination.path),
            legacyExists: FileManager.default.fileExists(atPath: legacyURL.path)
        ) else { return }

        do {
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: legacyURL, to: destination)
        } catch {
            // Best-effort, same as save().
        }
    }

    /// The migration-eligibility decision `migrateLegacySessionFileIfNeeded` acts on, pulled out as a pure function so its branches (release-only, don't clobber an existing namespaced file, only migrate if a legacy file actually exists) are testable without touching the real file system.
    static func shouldMigrateLegacySessionFile(bundleID: String?, destinationExists: Bool, legacyExists: Bool) -> Bool {
        guard bundleID == releaseBundleID else { return false }
        guard !destinationExists else { return false }
        return legacyExists
    }
}
