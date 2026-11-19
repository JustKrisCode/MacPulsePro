import Foundation

public enum CleanupClass: String, Codable, Sendable, CaseIterable, Comparable {
    /// Verified rebuildable data.
    case safe
    /// May be rebuildable but could hold useful state; requires inspection.
    case review
    /// Documents, source, credentials, databases, configuration, media, valuable app state.
    case protected
    /// Not recognized; never eligible for cleanup.
    case unknown

    private var rank: Int { switch self { case .safe: 0; case .review: 1; case .protected: 2; case .unknown: 3 } }
    public static func < (a: CleanupClass, b: CleanupClass) -> Bool { a.rank < b.rank }
    public var isActionable: Bool { self == .safe || self == .review }
}

public enum CleanupCategory: String, Codable, Sendable, CaseIterable {
    case applicationCache, browserCache, developerCache, logs, temporary, installers, trash
    case largeFile, duplicate, applicationData, backups

    public var title: String {
        switch self {
        case .applicationCache: "Application caches"; case .browserCache: "Browser caches"
        case .developerCache: "Developer caches"; case .logs: "Logs"; case .temporary: "Temporary files"
        case .installers: "Old installers"; case .trash: "Trash"; case .largeFile: "Large files"
        case .duplicate: "Duplicate files"; case .applicationData: "Application data"; case .backups: "Device backups"
        }
    }
}

public enum CleanupScope: String, Codable, Sendable {
    /// The root itself is a single candidate.
    case wholeItem
    /// Every direct child of the root is a separate candidate.
    case children
    /// One candidate covering everything inside the root; the root directory itself is kept.
    case contents
}

/// Who owns a cache. If any owner is running, the item is blocked (in use).
public struct Owner: Codable, Sendable, Hashable {
    public var bundleIDs: [String] = []
    public var processNames: [String] = []
    public var display: String
    public init(_ display: String, bundleIDs: [String] = [], processNames: [String] = []) {
        self.display = display; self.bundleIDs = bundleIDs; self.processNames = processNames
    }
}

public struct CleanupRule: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var category: CleanupCategory
    public var root: String
    public var scope: CleanupScope
    public var classification: CleanupClass
    public var confidence: Level
    public var owner: Owner?
    public var reason: String
    public var consequence: String
    /// Only items whose newest modification is older than this are candidates.
    public var minAgeDays: Double?
    /// For `.children`: only children with these extensions (lowercased, no dot).
    public var extensions: Set<String>?
    /// Permanent deletion allowed (otherwise Trash only).
    public var allowsDelete: Bool
    /// Moving to Trash is meaningful (false for the Trash itself).
    public var allowsTrash: Bool = true
    /// Lives in a TCC-protected personal folder; scanned only on explicit opt-in.
    public var personal: Bool = false
    /// Per-child override for heterogeneous roots like ~/Library/Caches.
    public var childClassifier: (@Sendable (String) -> ChildKnowledge)?
}

public struct ChildKnowledge: Sendable {
    public var title: String
    public var category: CleanupCategory
    public var classification: CleanupClass
    public var confidence: Level
    public var owner: Owner?
    public var reason: String
    public var consequence: String
}

public enum CleanupCatalog {
    static var home: String { NSHomeDirectory() }
    static var tmp: String { (NSTemporaryDirectory() as NSString).standardizingPath }

    public static func rules(home: String = NSHomeDirectory()) -> [CleanupRule] {
        let h = home
        return [
            CleanupRule(id: "user-caches", title: "Application caches", category: .applicationCache,
                        root: h + "/Library/Caches", scope: .children, classification: .review, confidence: .medium,
                        reason: "Per-app cache folder", consequence: "The app rebuilds it on demand.",
                        allowsDelete: true, childClassifier: CacheKnowledge.classify),
            CleanupRule(id: "npm-cache", title: "npm package cache", category: .developerCache,
                        root: h + "/.npm/_cacache", scope: .wholeItem, classification: .safe, confidence: .high,
                        owner: Owner("npm", processNames: ["npm", "npx"]),
                        reason: "Content-addressable download cache; npm re-downloads as needed.",
                        consequence: "Next installs re-download packages (slower, needs network).", allowsDelete: true),
            CleanupRule(id: "npx-cache", title: "npx package cache", category: .developerCache,
                        root: h + "/.npm/_npx", scope: .wholeItem, classification: .review, confidence: .medium,
                        owner: Owner("npx", processNames: ["npx", "npm"]),
                        reason: "Packages fetched by npx.", consequence: "npx re-downloads tools on next use.", allowsDelete: true),
            CleanupRule(id: "xcode-deriveddata", title: "Xcode DerivedData", category: .developerCache,
                        root: h + "/Library/Developer/Xcode/DerivedData", scope: .children, classification: .safe, confidence: .high,
                        owner: Owner("Xcode", bundleIDs: ["com.apple.dt.Xcode"], processNames: ["xcodebuild", "XCBBuildService"]),
                        reason: "Build intermediates and indexes, regenerated by Xcode.",
                        consequence: "Next build and indexing take longer.", allowsDelete: true),
            CleanupRule(id: "simulator-caches", title: "Simulator caches", category: .developerCache,
                        root: h + "/Library/Developer/CoreSimulator/Caches", scope: .contents, classification: .safe, confidence: .high,
                        owner: Owner("Simulator", bundleIDs: ["com.apple.iphonesimulator"], processNames: ["simctl"]),
                        reason: "Dyld and runtime caches for simulators.", consequence: "Simulators rebuild caches on next boot.",
                        allowsDelete: true),
            CleanupRule(id: "xcode-device-support", title: "Device support files", category: .developerCache,
                        root: h + "/Library/Developer/Xcode/iOS DeviceSupport", scope: .children, classification: .review, confidence: .medium,
                        owner: Owner("Xcode", bundleIDs: ["com.apple.dt.Xcode"]),
                        reason: "Debug symbols copied from connected devices.",
                        consequence: "Re-copied (slowly) when that OS version's device is connected again.", allowsDelete: true),
            CleanupRule(id: "gradle-caches", title: "Gradle caches", category: .developerCache,
                        root: h + "/.gradle/caches", scope: .wholeItem, classification: .review, confidence: .medium,
                        owner: Owner("Gradle", processNames: ["java", "gradle"]),
                        reason: "Dependency and build cache.", consequence: "Builds re-download dependencies.", allowsDelete: true),
            CleanupRule(id: "user-logs", title: "Old application logs", category: .logs,
                        root: h + "/Library/Logs", scope: .children, classification: .safe, confidence: .medium,
                        reason: "Log files untouched for 30+ days.", consequence: "Old logs are no longer available for troubleshooting.",
                        minAgeDays: 30, allowsDelete: true, childClassifier: { name in
                            name == "DiagnosticReports"
                                ? ChildKnowledge(title: "Crash reports", category: .logs, classification: .review, confidence: .medium,
                                                 reason: "Crash and hang reports.", consequence: "Lost history for diagnosing crashes.")
                                : name == "MacPulsePro"
                                ? ChildKnowledge(title: "MacPulse logs", category: .logs, classification: .protected, confidence: .high,
                                                 reason: "This app's own logs.", consequence: "")
                                : ChildKnowledge(title: "Logs: \(name)", category: .logs, classification: .safe, confidence: .medium,
                                                 reason: "Log files untouched for 30+ days.", consequence: "Old logs are no longer available.")
                        }),
            CleanupRule(id: "temp", title: "Old temporary files", category: .temporary,
                        root: tmp, scope: .children, classification: .review, confidence: .low,
                        reason: "Per-user temporary items untouched for 3+ days.",
                        consequence: "An app that still expects the file may need to recreate it.",
                        minAgeDays: 3, allowsDelete: true),
            CleanupRule(id: "ios-updates", title: "Device software updates", category: .installers,
                        root: h + "/Library/iTunes/iPhone Software Updates", scope: .children, classification: .safe, confidence: .high,
                        reason: "Downloaded device firmware (re-downloadable).", consequence: "Re-downloaded if needed for a restore.",
                        allowsDelete: true),
            CleanupRule(id: "mail-downloads", title: "Mail attachment downloads", category: .applicationCache,
                        root: h + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", scope: .contents,
                        classification: .review, confidence: .medium, owner: Owner("Mail", bundleIDs: ["com.apple.mail"]),
                        reason: "Copies of attachments opened from Mail.", consequence: "Attachments remain in Mail; copies are removed.",
                        allowsDelete: false),
            CleanupRule(id: "downloads-installers", title: "Old installers in Downloads", category: .installers,
                        root: h + "/Downloads", scope: .children, classification: .review, confidence: .medium,
                        reason: "Disk images and installer packages older than 14 days.",
                        consequence: "You would need to download the installer again.",
                        minAgeDays: 14, extensions: ["dmg", "pkg", "mpkg", "iso", "xip"], allowsDelete: false, personal: true),
            CleanupRule(id: "trash", title: "Trash", category: .trash,
                        root: h + "/.Trash", scope: .contents, classification: .review, confidence: .high,
                        reason: "Items you already moved to the Trash.", consequence: "PERMANENT: items cannot be recovered.",
                        allowsDelete: true, allowsTrash: false),
        ]
    }

    /// Locations shown for transparency but never offered for cleanup.
    public static func protectedLocations(home: String = NSHomeDirectory()) -> [(title: String, path: String, category: CleanupCategory, reason: String)] {
        [("iPhone/iPad backups", home + "/Library/Application Support/MobileSync/Backup", .backups,
          "Device backups — manage them in Finder › device › Manage Backups."),
         ("Xcode archives", home + "/Library/Developer/Xcode/Archives", .applicationData,
          "Shipped app archives with debug symbols."),
         ("Application Support", home + "/Library/Application Support", .applicationData,
          "Application databases, settings and documents. Remove apps' data only via the app itself.")]
    }
}

/// Knowledge base for ~/Library/Caches children.
public enum CacheKnowledge {
    struct Entry { var title: String; var category: CleanupCategory; var cls: CleanupClass; var owner: Owner?; var note: String }

    static let known: [String: Entry] = {
        func dev(_ t: String, _ procs: [String], _ cls: CleanupClass = .safe, _ note: String = "Download/build cache; rebuilt on demand.") -> Entry {
            Entry(title: t, category: .developerCache, cls: cls, owner: Owner(t, processNames: procs), note: note)
        }
        func browser(_ t: String, _ bundle: [String]) -> Entry {
            Entry(title: "\(t) cache", category: .browserCache, cls: .safe, owner: Owner(t, bundleIDs: bundle),
                  note: "Web content cache; pages load slower once while it refills. Logins and history are not stored here.")
        }
        return [
            "Homebrew": dev("Homebrew downloads", ["brew"]),
            "pip": dev("pip cache", ["pip", "pip3"]),
            "pnpm": dev("pnpm metadata cache", ["pnpm"]),
            "Yarn": dev("Yarn cache", ["yarn"]),
            "CocoaPods": dev("CocoaPods cache", ["pod"]),
            "node-gyp": dev("node-gyp headers", ["node-gyp"]),
            "go-build": dev("Go build cache", ["go"]),
            "typescript": dev("TypeScript cache", ["tsserver"]),
            "deno": dev("Deno cache", ["deno"]),
            "bun": dev("Bun install cache", ["bun"]),
            "org.swift.swiftpm": dev("SwiftPM package cache", ["swift-build", "swift-package"]),
            "pypoetry": dev("Poetry cache", ["poetry"]),
            "electron": dev("Electron downloads", []),
            "electron-builder": dev("electron-builder downloads", []),
            "com.apple.dt.Xcode": Entry(title: "Xcode cache", category: .developerCache, cls: .safe,
                                        owner: Owner("Xcode", bundleIDs: ["com.apple.dt.Xcode"]), note: "Xcode download/doc cache."),
            "ms-playwright": dev("Playwright browsers", [], .review, "Browser binaries used by test suites; must be re-installed with `playwright install`."),
            "Cypress": dev("Cypress binaries", [], .review, "Test runner binaries; re-downloaded on install."),
            "JetBrains": dev("JetBrains IDE caches", [], .review, "Indexes; IDEs re-index (slow) after removal."),
            "Google": browser("Google Chrome", ["com.google.Chrome"]),
            "Firefox": browser("Firefox", ["org.mozilla.firefox"]),
            "BraveSoftware": browser("Brave", ["com.brave.Browser"]),
            "Microsoft Edge": browser("Microsoft Edge", ["com.microsoft.edgemac"]),
            "com.operasoftware.Opera": browser("Opera", ["com.operasoftware.Opera"]),
            "company.thebrowser.Browser": browser("Arc", ["company.thebrowser.Browser"]),
            "com.apple.Safari": browser("Safari", ["com.apple.Safari"]),
            "com.microsoft.VSCode.ShipIt": Entry(title: "VS Code update cache", category: .applicationCache, cls: .safe,
                                                 owner: Owner("VS Code", bundleIDs: ["com.microsoft.VSCode"]), note: "Downloaded updates."),
        ]
    }()

    @Sendable public static func classify(_ name: String) -> ChildKnowledge {
        if let e = known[name] {
            return ChildKnowledge(title: e.title, category: e.category, classification: e.cls,
                                  confidence: e.cls == .safe ? .high : .medium, owner: e.owner,
                                  reason: e.note, consequence: e.cls == .safe ? "Rebuilt automatically when needed." : e.note)
        }
        if name.hasPrefix("com.apple.") || name == "CloudKit" || name == "GeoServices" || name == "SiriTTS" {
            return ChildKnowledge(title: "macOS cache: \(name)", category: .applicationCache, classification: .review, confidence: .low,
                                  owner: Owner(name, bundleIDs: [name]),
                                  reason: "Managed by macOS, which trims it automatically.",
                                  consequence: "System services rebuild it; removal rarely helps and may cause re-downloads.")
        }
        let looksLikeBundleID = name.split(separator: ".").count >= 3
        return ChildKnowledge(title: "Cache: \(name)", category: .applicationCache, classification: .review,
                              confidence: looksLikeBundleID ? .medium : .low,
                              owner: looksLikeBundleID ? Owner(name, bundleIDs: [name]) : nil,
                              reason: "Located in the user Caches folder, which apps must treat as disposable.",
                              consequence: "Some apps store offline content here; it would be re-downloaded.")
    }
}
