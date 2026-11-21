import AppKit
import MacPulseCore
import SwiftUI

/// Developer tool: when MACPULSE_SNAPSHOT_DIR is set, renders the main window for every section to PNG
/// (via AppKit cacheDisplay — no Screen Recording permission needed) and then quits.
@MainActor
enum SnapshotHarness {
    static var directory: String? { ProcessInfo.processInfo.environment["MACPULSE_SNAPSHOT_DIR"] }

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
            try? await Task.sleep(nanoseconds: 7_000_000_000)   // let a few samples accumulate
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
