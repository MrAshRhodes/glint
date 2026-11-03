import Foundation

/// How often Glint looks for a new version by itself.
///
/// `never` is the default: nothing is requested until the user chooses "Check for Updates…".
public enum UpdateCheckFrequency: String, CaseIterable, Identifiable, Sendable {
    case never, daily, weekly, monthly

    public var id: String { rawValue }

    public static let `default`: UpdateCheckFrequency = .never

    /// Seconds between automatic checks; nil while automatic checks are off.
    public var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly: 30 * 86_400
        }
    }

    public var title: String {
        switch self {
        case .never: "Never"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    /// Reads back the persisted updater state. An interval that matches no preset (a hand-edited preference)
    /// maps to the nearest one, so the picker always shows a valid choice.
    public init(automaticChecks: Bool, interval: TimeInterval) {
        guard automaticChecks else {
            self = .never
            return
        }
        let scheduled: [UpdateCheckFrequency] = [.daily, .weekly, .monthly]
        self = scheduled.min { lhs, rhs in
            abs((lhs.interval ?? 0) - interval) < abs((rhs.interval ?? 0) - interval)
        } ?? .weekly
    }
}

/// Whether this copy of Glint may replace itself.
///
/// A copy installed by Homebrew belongs to `brew upgrade`: swapping the app underneath Homebrew would leave its
/// records pointing at a version that is no longer there. Those copies never update themselves.
public enum UpdateInstallSource: Equatable, Sendable {
    case direct
    /// `caskVersion` is the Caskroom version folder that owns this copy, when it can be read.
    case homebrew(caskVersion: String?)

    public static let caskToken = "glint"
    public static let appName = "Glint.app"
    public static let homebrewUpdateCommand = "brew update && brew upgrade --cask \(caskToken)"

    public var isHomebrew: Bool {
        if case .homebrew = self { return true }
        return false
    }

    /// Caskroom folders of the usual Homebrew prefixes (Apple silicon, Intel, per-user installs),
    /// plus `HOMEBREW_PREFIX` when set.
    public static func defaultCaskroomRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var prefixes = [
            "/opt/homebrew",
            "/usr/local",
            home.appendingPathComponent("homebrew", isDirectory: true).path,
            home.appendingPathComponent(".homebrew", isDirectory: true).path,
        ]
        if let custom = environment["HOMEBREW_PREFIX"], custom.hasPrefix("/") {
            prefixes.insert(custom, at: 0)
        }
        var seen = Set<String>()
        return prefixes
            .filter { seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Caskroom", isDirectory: true) }
    }

    /// Homebrew-managed means the running app *is* the copy a cask installed. Two layouts exist:
    /// the cask stages the app in `Caskroom/glint/<version>/` and links it into /Applications, or it moves the app
    /// to /Applications and leaves a symlink in the Caskroom. A separate direct download elsewhere is not affected
    /// merely because the cask is also installed.
    ///
    /// A stale symlink (the Caskroom entry still points at the running bundle after a manual replacement) is treated
    /// as Homebrew on purpose: failing safe means never replacing an app Homebrew still believes it owns.
    public static func detect(
        bundleURL: URL,
        caskroomRoots: [URL] = defaultCaskroomRoots(),
        fileManager: FileManager = .default
    ) -> UpdateInstallSource {
        let bundle = normalized(bundleURL)
        for root in caskroomRoots {
            let caskDirectory = root.appendingPathComponent(caskToken, isDirectory: true)
            let stagedPrefix = normalized(caskDirectory).path + "/"
            if bundle.path.hasPrefix(stagedPrefix) {
                return .homebrew(caskVersion: firstComponent(of: bundle.path, after: stagedPrefix))
            }
            guard let versions = try? fileManager.contentsOfDirectory(atPath: caskDirectory.path) else { continue }
            for version in versions.sorted() {
                let staged = caskDirectory
                    .appendingPathComponent(version, isDirectory: true)
                    .appendingPathComponent(appName, isDirectory: true)
                if normalized(staged) == bundle { return .homebrew(caskVersion: version) }
            }
        }
        let marker = "/Caskroom/\(caskToken)/"
        if bundle.path.contains(marker) {
            return .homebrew(caskVersion: firstComponent(of: bundle.path, after: marker))
        }
        return .direct
    }

    /// Set when Homebrew's records name a different version than the one running — typically an app that was
    /// replaced by hand. Only a hint: ownership is never decided by it.
    public func staleRecordHint(runningVersion: String?) -> String? {
        guard case .homebrew(let recorded?) = self, let runningVersion, recorded != runningVersion else { return nil }
        return "Homebrew's records list Glint \(recorded), but this is Glint \(runningVersion). If you replaced the app by hand, see “Switching an install between Homebrew and direct downloads” in the guide."
    }

    private static func firstComponent(of path: String, after prefix: String) -> String? {
        guard let range = path.range(of: prefix) else { return nil }
        let rest = path[range.upperBound...]
        return rest.split(separator: "/").first.map(String.init)
    }

    private static func normalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

/// The two Info.plist values Sparkle needs: where the signed appcast lives and the public key updates must verify against.
public struct UpdateConfiguration: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable {
        case missingFeedURL
        case feedURLNotHTTPS
        case missingPublicKey
        case invalidPublicKey

        /// Plain-language reason shown where the updater cannot run.
        public var explanation: String {
            switch self {
            case .missingFeedURL:
                "This build has no update feed address."
            case .feedURLNotHTTPS:
                "This build's update feed address is not a secure HTTPS URL."
            case .missingPublicKey:
                "This build has no update signing key. Builds made from source cannot verify updates, so they can't update themselves."
            case .invalidPublicKey:
                "This build's update signing key is malformed, so updates can't be verified."
            }
        }
    }

    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"
    /// Length of an Ed25519 public key in bytes.
    public static let publicKeyLength = 32

    public let feedURL: URL
    public let publicKey: String

    public static func resolve(from infoDictionary: [String: Any]?) -> Result<UpdateConfiguration, Problem> {
        guard let rawFeed = trimmed(infoDictionary?[feedURLKey]), let feedURL = URL(string: rawFeed) else {
            return .failure(.missingFeedURL)
        }
        guard feedURL.scheme?.lowercased() == "https", feedURL.host?.isEmpty == false else {
            return .failure(.feedURLNotHTTPS)
        }
        guard let key = trimmed(infoDictionary?[publicKeyKey]) else { return .failure(.missingPublicKey) }
        guard Data(base64Encoded: key)?.count == publicKeyLength else { return .failure(.invalidPublicKey) }
        return .success(UpdateConfiguration(feedURL: feedURL, publicKey: key))
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}
