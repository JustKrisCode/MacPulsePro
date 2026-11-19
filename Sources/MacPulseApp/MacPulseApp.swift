import AppKit
import MacPulseCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The menu bar companion keeps running after the main window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MacPulseProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MacPulse Pro", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1200, height: 800)
        .commands { AppCommands(model: model) }

        MenuBarExtra {
            MenuBarPanel().environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model).frame(width: 560, height: 620)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh Now") { Task { await model.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Why Is My Mac Slow?") { model.diagnose() }
                .keyboardShortcut("y", modifiers: .command)
            Divider()
            ForEach(Array(SidebarSection.allCases.prefix(9).enumerated()), id: \.element) { i, section in
                Button(section.title) { model.selection = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
        CommandGroup(replacing: .importExport) {
            Button("Export Report…") { ReportExporter.export(model: model) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export History as CSV…") { ReportExporter.exportHistory(model: model) }
        }
    }
}

@MainActor
enum ReportExporter {
    static func export(model: AppModel) {
        let panel = NSSavePanel()
        panel.title = "Export MacPulse Report"
        panel.nameFieldStringValue = "MacPulse Report.md"
        panel.allowedContentTypes = [.plainText, .json, .html, .commaSeparatedText]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format: ReportFormat = switch url.pathExtension.lowercased() {
        case "json": .json; case "html", "htm": .html; case "csv": .csv; default: .markdown
        }
        do { try model.reportText(format).write(to: url, atomically: true, encoding: .utf8) }
        catch { model.banner = "Export failed: \(error.localizedDescription)" }
    }

    static func exportHistory(model: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacPulse History.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let samples = (try? model.store?.samples(since: .distantPast)) ?? model.live
        do { try ReportBuilder.historyCSV(samples).write(to: url, atomically: true, encoding: .utf8) }
        catch { model.banner = "Export failed: \(error.localizedDescription)" }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Monitor") {
                    ForEach([SidebarSection.overview, .health, .memory, .cpu, .gpu, .thermal, .energy]) { SidebarRow(section: $0) }
                }
                Section("Maintain") {
                    ForEach([SidebarSection.storage, .processes, .monitoring, .cleanupHistory]) { SidebarRow(section: $0) }
                }
                Section { SidebarRow(section: .settings) }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    BannerView(text: banner) { model.banner = nil }
                }
                detail(model.selection ?? .overview)
            }
        }
        .sheet(item: $model.diagnosis) { d in DiagnosisSheet(diagnosis: d) { model.diagnosis = nil } }
        .onAppear { model.mainWindowVisible = true; SnapshotHarness.runIfRequested(model: model) }
        .onDisappear { model.mainWindowVisible = false }
    }

    @ViewBuilder
    func detail(_ s: SidebarSection) -> some View {
        switch s {
        case .overview: OverviewView()
        case .health: HealthView()
        case .memory: MemoryView()
        case .cpu: CPUView()
        case .gpu: GPUView()
        case .thermal: ThermalView()
        case .energy: EnergyView()
        case .storage: StorageView()
        case .processes: ProcessesView()
        case .monitoring: MonitoringView()
        case .cleanupHistory: CleanupHistoryView()
        case .settings: SettingsView()
        }
    }
}

struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let section: SidebarSection

    var body: some View {
        Label {
            HStack {
                Text(section.title)
                Spacer()
                if let badge { badge }
            }
        } icon: {
            Image(systemName: section.symbol)
        }
        .tag(section)
    }

    var badge: AnyView? {
        guard let h = model.health else { return nil }
        let kind: HealthDimension.Kind? = switch section {
        case .memory: .memory; case .cpu: .cpu; case .gpu: .gpu; case .thermal: .thermal; case .storage: .storage; default: nil
        }
        if section == .health { return AnyView(Text("\(h.overall)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)) }
        guard let kind, let d = h.dimensions.first(where: { $0.kind == kind }), d.status != .ok else { return nil }
        return AnyView(SeverityDot(severity: d.status))
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "info.circle")
            Text(text).font(.callout)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(10)
        .background(.blue.opacity(0.12))
    }
}
