import AppKit
import MacPulseCore
import SwiftUI

/// Developer tool: when MACPULSE_SNAPSHOT_DIR is set, renders the main window for every section to PNG
/// (via AppKit cacheDisplay — no Screen Recording permission needed) and then quits.
@MainActor
enum SnapshotHarness {
    static var directory: String? { ProcessInfo.processInfo.environment["MACPULSE_SNAPSHOT_DIR"] }

    /// Screenshots are meant for the README, so they must not reveal what else runs on the capturing Mac:
    /// keep only macOS system processes and MacPulse itself, and hide the account name and home folder.
    static func scrubbed(_ snap: SystemSnapshot) -> SystemSnapshot {
        guard directory != nil else { return snap }
        let home = NSHomeDirectory(), account = NSUserName()
        let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]
        func isShareable(_ p: ProcessRecord) -> Bool {
            if p.name.hasPrefix("MacPulse") { return true }
            if p.bundleIdentifier?.hasPrefix("com.apple.") == true { return true }
            guard let path = p.path else { return p.uid == 0 }
            return systemPrefixes.contains { path.hasPrefix($0) }
        }
        var s = snap
        s.processes = s.processes.filter(isShareable).map { p in
            var p = p
            if p.user == account { p.user = "user" }
            // System XPC services name their host app in parentheses, e.g. "Open and Save Panel Service (SomeApp)".
            if let open = p.name.firstIndex(of: "(") { p.name = p.name[..<open].trimmingCharacters(in: .whitespaces) }
            if let path = p.path, path.hasPrefix(home) { p.path = "~" + path.dropFirst(home.count) }
            return p
        }
        let kept = Set(s.processes.map(\.pid))
        s.gpu.processes = s.gpu.processes.filter { kept.contains($0.pid) }
        return s
    }

    static func runIfRequested(model: AppModel) {
        // Benchmark aid: open the app directly on a given section.
        if let start = ProcessInfo.processInfo.environment["MACPULSE_START_SECTION"], let s = SidebarSection(rawValue: start) {
            model.selection = s
        }
        guard let dir = directory else { return }
        let appearance = ProcessInfo.processInfo.environment["MACPULSE_SNAPSHOT_APPEARANCE"]
        if appearance == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        if appearance == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(nanoseconds: 40_000_000_000)   // let a few samples (incl. CPU deltas) accumulate
            if ProcessInfo.processInfo.environment["MACPULSE_SNAPSHOT_SCAN"] == "1" {
                model.scanStorage(includePersonal: false)
                while model.storageScanning { try? await Task.sleep(nanoseconds: 300_000_000) }
            }
            for section in SidebarSection.allCases {
                model.selection = section
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                capture(name: section.rawValue, dir: dir)
            }
            model.selection = .overview
            model.diagnose()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let sheet = NSApp.windows.first(where: { $0.isVisible && $0.isSheet }), let v = sheet.contentView?.superview ?? sheet.contentView,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/why.png"))
            }
            NSApp.terminate(nil)
        }
    }

    static func capture(name: String, dir: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
