import AppKit
import Foundation
import MacPulseCore
import Observation
import ServiceManagement
import UserNotifications

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview, health, memory, cpu, gpu, thermal, energy, storage, processes, monitoring, cleanupHistory, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"; case .health: "System Health"; case .memory: "Memory"; case .cpu: "CPU"
        case .gpu: "GPU"; case .thermal: "Thermal"; case .energy: "Energy"; case .storage: "Storage"; case .processes: "Processes"
        case .monitoring: "Monitoring"; case .cleanupHistory: "Cleanup History"; case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"; case .health: "heart.text.square"; case .memory: "memorychip"
        case .cpu: "cpu"; case .gpu: "cube.transparent"; case .thermal: "thermometer.medium"; case .energy: "bolt"
        case .storage: "internaldrive"; case .processes: "list.bullet.rectangle"; case .monitoring: "waveform.path.ecg"
        case .cleanupHistory: "clock.arrow.circlepath"; case .settings: "gearshape"
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case session = "Session", hour = "1 h", sixHours = "6 h", day = "24 h", week = "7 d"
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self { case .session: nil; case .hour: 3600; case .sixHours: 21600; case .day: 86400; case .week: 604800 }
    }
}

/// Main-actor view model. All measurement happens in `SystemSampler` (an actor, off the main thread);
/// this class only stores results for the UI.
@MainActor
@Observable
final class AppModel {
    var config: MacPulseConfig
    var snapshot: SystemSnapshot?
    var health: HealthReport?
    var recommendations: [Recommendation] = []
    var findings: [ProcessFinding] = []
    var historySummary: HistorySummary = .empty
    /// In-memory ring buffer for this session (independent of the background monitor).
    var live: [HistorySample] = []
    var coreHistory: [[Double]] = []
    var gpuProcessHistory: [Int32: [Double]] = [:]
    var processHistory: [ProcessIdentity: [ProcessHistoryPoint]] = [:]
    /// Computed once per sample (not per render).
    var appGroups: [AppGroup] = []
    var stored: [HistorySample] = []
    var historyRange: HistoryRange = .session { didSet { loadStoredHistory() } }
    var events: [StoredEvent] = []
    var cleanupHistory: [CleanupHistoryEntry] = []
    var agentStatus: LaunchAgentManager.Status?
    var launchAtLogin = false
    var storage: StorageAnalysis?
    var storageScanning = false
    var storageCancel: CancellationFlag?
    var banner: String?
    var mainWindowVisible = true
    var selection: SidebarSection? = .overview
    var diagnosis: SlowdownDiagnosis?
    var growthScans: [GrowthScan] = []
    var growthScanning = false
    var energyHistory: [SeriesPointValue] = []
    var autoCleanPreview: AutoCleanOutcome?
    var autoCleanBusy = false
    var autoCleanLastRun: Date?
    private var lastAutoCleanCheck = Date.distantPast

    let store: HistoryStore?
    private let sampler = SystemSampler()
    private var loop: Task<Void, Never>?
    private var ticks = 0
    private var launchdPIDs: Set<Int32>?
    private let ringLimit = 1800

    init() {
        config = MacPulseConfig.load()
        store = try? HistoryStore()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshAgentStatus()
        loadStoredHistory()
        reloadCleanupHistory()
        loadAutoCleanState()
        start()
    }

    var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    /// While only the menu bar is visible, sample less often and skip the process table on most ticks.
    var effectiveInterval: TimeInterval {
        mainWindowVisible ? config.uiRefreshSeconds : max(config.uiRefreshSeconds, 5)
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(self.effectiveInterval * 1e9))
            }
        }
    }

    func refresh() async {
        ticks += 1
        // Window open: full process table every other tick; menu bar only: every sixth tick.
        let withProcesses = mainWindowVisible ? ticks % 2 == 1 : ticks % 6 == 1
        let snap = await sampler.snapshot(includeProcesses: withProcesses)
        if withProcesses == false, let previous = snapshot { // keep the last process table for the menu bar
            var merged = snap
            merged.processes = previous.processes
            apply(merged, freshProcesses: false)
        } else {
            apply(snap, freshProcesses: true)
        }
    }

    private func apply(_ snap: SystemSnapshot, freshProcesses: Bool) {
        snapshot = snap
        live.append(HistorySample(snap))
        if live.count > ringLimit { live.removeFirst(live.count - ringLimit) }
        if let cores = snap.cpu?.cores {
            if coreHistory.count != cores.count { coreHistory = Array(repeating: [], count: cores.count) }
            for (i, c) in cores.enumerated() {
                coreHistory[i].append(c.total)
                if coreHistory[i].count > 120 { coreHistory[i].removeFirst() }
            }
        }
        for p in snap.gpu.processes { if let r = p.recentPercent { gpuProcessHistory[p.pid, default: []].append(r) } }
        gpuProcessHistory = gpuProcessHistory.filter { pid, _ in snap.gpu.processes.contains { $0.pid == pid } }
            .mapValues { Array($0.suffix(120)) }

        if freshProcesses {
            appGroups = ProcessAnalyzer.appGroups(snap.processes)
            let watts = snap.processes.compactMap(\.powerWatts).reduce(0, +)
            if snap.processes.contains(where: { $0.powerWatts != nil }) {
                energyHistory.append(SeriesPointValue(date: snap.timestamp, value: watts))
                if energyHistory.count > 300 { energyHistory.removeFirst(energyHistory.count - 300) }
            }
            for p in snap.processes where (p.cpuPercent ?? 0) > 2 || (p.footprint ?? 0) > 300_000_000 {
                processHistory[p.identity, default: []].append(ProcessHistoryPoint(timestamp: snap.timestamp, cpu: p.cpuPercent, footprint: p.footprint))
            }
            if ticks % 30 == 1 {
                let live = Set(snap.processes.map(\.identity))
                processHistory = processHistory.filter { live.contains($0.key) }.mapValues { Array($0.suffix(900)) }
            }
            if ticks % 30 == 1 || launchdPIDs == nil { launchdPIDs = ProcessAnalyzer.launchdManagedPIDs() }
        }
        let recentStored = stored.filter { snap.timestamp.timeIntervalSince($0.timestamp) <= 3600 }
        historySummary = HistorySummary.compute(recentStored + live.suffix(900),
                                                cpuThreshold: config.thresholds.sustainedCPUPercent,
                                                cpuWindow: config.thresholds.sustainedCPUMinutes * 60)
        health = HealthScorer.evaluate(snap, history: historySummary, thresholds: config.thresholds)
        if freshProcesses {
            var ctx = ProcessAnalyzer.Context(records: snap.processes, physicalMemory: snap.system.physicalMemory)
            ctx.launchdManagedPIDs = launchdPIDs
            ctx.history = processHistory
            ctx.thresholds = config.thresholds
            findings = ProcessAnalyzer.findings(ctx)
        }
        maybeAutoClean()
        recommendations = RecommendationEngine.recommendations(RecommendationContext(
            snapshot: snap, history: historySummary, findings: findings, cleanup: storage?.summary, thresholds: config.thresholds))
    }

    // MARK: History

    func loadStoredHistory() {
        guard let store else { stored = []; return }
        let seconds = historyRange.seconds ?? 3600
        stored = (try? store.samples(since: Date().addingTimeInterval(-seconds))) ?? []
        events = (try? store.events(since: Date().addingTimeInterval(-7 * 86400))) ?? []
    }

    /// Samples for charts: persisted history for long ranges, the session buffer otherwise.
    var chartSamples: [HistorySample] {
        guard let seconds = historyRange.seconds else { return downsample(live, to: 150) }
        let cutoff = Date().addingTimeInterval(-seconds)
        let merged = stored.filter { $0.timestamp >= cutoff } + live.filter { $0.timestamp >= cutoff && $0.timestamp > (stored.last?.timestamp ?? .distantPast) }
        return downsample(merged, to: 600)
    }

    func downsample(_ s: [HistorySample], to n: Int) -> [HistorySample] {
        guard s.count > n else { return s }
        let step = Double(s.count) / Double(n)
        return (0..<n).map { s[Int(Double($0) * step)] }
    }

    /// Last 10 minutes of this session, at most 150 points — cheap for Swift Charts to redraw.
    var recentLive: [HistorySample] {
        downsample(Array(live.suffix(300)), to: 150)
    }

    func reloadCleanupHistory() { cleanupHistory = (try? store?.cleanupHistory(limit: 1000)) ?? [] }

    // MARK: Storage

    func scanStorage(includePersonal: Bool) {
        guard !storageScanning else { return }
        storageScanning = true
        let cancel = CancellationFlag()
        storageCancel = cancel
        Task.detached(priority: .utility) {
            var opts = ScanOptions()
            opts.includePersonalFolders = includePersonal
            let result = CleanupScanner().scan(options: opts, cancel: cancel)
            await MainActor.run {
                self.storage = result
                self.storageScanning = false
                self.storageCancel = nil
            }
        }
    }

    func cancelScan() { storageCancel?.cancel() }

    /// Dry run (validation only) — always performed before showing the confirmation sheet.
    func planCleanup(_ items: [CleanupCandidate], mode: CleanupMode, guardian: PathGuard) async -> [CleanupItemResult] {
        await Task.detached(priority: .userInitiated) {
            let cleaner = Cleaner(guardian: guardian, store: nil)
            var results: [CleanupItemResult] = []
            for (m, group) in Dictionary(grouping: items, by: { Self.effectiveMode($0, mode) }) {
                results += (try? cleaner.run(group, mode: m, dryRun: true).items) ?? []
            }
            return results
        }.value
    }

    nonisolated static func effectiveMode(_ c: CleanupCandidate, _ requested: CleanupMode) -> CleanupMode {
        if !c.allowsTrash { return .delete }
        if requested == .delete && !c.allowsDelete { return .trash }
        return requested
    }

    func executeCleanup(_ items: [CleanupCandidate], mode: CleanupMode, guardian: PathGuard) async -> Result<[CleanupRunResult], MacPulseError> {
        let store = self.store
        let result: Result<[CleanupRunResult], MacPulseError> = await Task.detached(priority: .userInitiated) {
            let cleaner = Cleaner(guardian: guardian, store: store)
            var runs: [CleanupRunResult] = []
            do {
                for (m, group) in Dictionary(grouping: items, by: { Self.effectiveMode($0, mode) }) {
                    runs.append(try cleaner.run(group, mode: m, dryRun: false))
                }
                return .success(runs)
            } catch let e as MacPulseError {
                return .failure(e)
            } catch {
                return .failure(.failed("\(error)"))
            }
        }.value
        reloadCleanupHistory()
        await sampler.invalidateVolume()
        return result
    }

    // MARK: Insights

    func diagnose() {
        guard let snap = snapshot else { return }
        let input = SlowdownDetective.Input(snapshot: snap, history: stored + live, processHistory: processHistory,
                                            findings: findings, thresholds: config.thresholds)
        Task.detached(priority: .userInitiated) {
            let d = SlowdownDetective.diagnose(input)
            await MainActor.run { self.diagnosis = d }
        }
    }

    func loadGrowthScans() { growthScans = (try? store?.growthScans()) ?? [] }

    func runGrowthScan(includePersonal: Bool) {
        guard !growthScanning else { return }
        growthScanning = true
        let store = self.store
        Task.detached(priority: .utility) {
            let scan = GrowthTracker.scan(includePersonal: includePersonal)
            try? store?.recordGrowthScan(scan)
            await MainActor.run { self.growthScanning = false; self.loadGrowthScans() }
        }
    }

    // MARK: Automatic cleanup

    /// Hourly check while the app is open. Skipped when the background monitor runs (it owns the schedule).
    func maybeAutoClean() {
        guard config.autoClean.enabled, !autoCleanBusy, Date().timeIntervalSince(lastAutoCleanCheck) > 3600, let store else { return }
        lastAutoCleanCheck = Date()
        guard agentStatus?.loaded != true, AutoCleaner.isDue(config.autoClean, lastRun: AutoCleaner.lastRun(store)) else { return }
        runAutoClean(dryRun: false)
    }

    func runAutoClean(dryRun: Bool) {
        guard !autoCleanBusy else { return }
        autoCleanBusy = true
        var cfg = config.autoClean
        cfg.enabled = true
        let store = self.store, notifyOn = config.notificationsEnabled && isBundled
        Task.detached(priority: dryRun ? .userInitiated : .background) {
            let outcome = try? AutoCleaner.run(config: cfg, store: store, dryRun: dryRun)
            await MainActor.run {
                self.autoCleanBusy = false
                if dryRun { self.autoCleanPreview = outcome } else {
                    self.banner = outcome.map { "Automatic cleanup: " + $0.summary } ?? "Automatic cleanup could not run (another cleanup may be in progress)."
                    self.reloadCleanupHistory()
                    self.loadAutoCleanState()
                    if notifyOn, let o = outcome, o.result != nil { Notifier.post(title: "MacPulse: Automatic cleanup", body: o.summary) }
                }
            }
        }
    }

    func loadAutoCleanState() { autoCleanLastRun = store.flatMap { AutoCleaner.lastRun($0) } }

    // MARK: Processes

    func terminate(_ r: ProcessRecord, force: Bool) async -> TerminationOutcome {
        let outcome = force ? await ProcessController.forceKill(r) : await ProcessController.terminate(r)
        await refresh()
        return outcome
    }

    // MARK: Monitoring service & settings

    var bundledCLIPath: String? {
        let p = Bundle.main.bundlePath + "/Contents/MacOS/macpulse"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    func refreshAgentStatus() {
        Task.detached { let s = LaunchAgentManager().status(); await MainActor.run { self.agentStatus = s } }
    }

    func installAgent() {
        guard let cli = bundledCLIPath else {
            banner = "The monitor helper is only available in the built app bundle (scripts/build-app.sh)."
            return
        }
        do { try config.save(); try LaunchAgentManager().install(executable: cli); banner = "Background monitor enabled." }
        catch { banner = "Could not enable the monitor: \(error)" }
        refreshAgentStatus()
    }

    func uninstallAgent() {
        do { try LaunchAgentManager().uninstall(); banner = "Background monitor disabled." }
        catch { banner = "Could not disable the monitor: \(error)" }
        refreshAgentStatus()
    }

    func saveConfig() {
        do { try config.save() } catch { banner = "Could not save settings: \(error)" }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            banner = "Launch at login could not be changed: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if on && SMAppService.mainApp.status == .requiresApproval {
            banner = "Approve MacPulse Pro in System Settings › General › Login Items."
        }
    }

    func setNotifications(_ on: Bool) {
        config.notificationsEnabled = on
        saveConfig()
        guard on, isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { Task { @MainActor in self.banner = "Notifications are disabled for MacPulse in System Settings." } }
        }
    }

    func pruneHistory() {
        guard let store else { return }
        let r = try? store.prune(retentionDays: config.retentionDays, maxSamples: config.maxSampleRows)
        banner = "Removed \(r?.samples ?? 0) samples, \(r?.processSamples ?? 0) process samples and \(r?.events ?? 0) events beyond retention."
        loadStoredHistory()
    }

    func reportText(_ format: ReportFormat) -> String {
        guard let snap = snapshot else { return "" }
        return ReportBuilder.render(ReportBuilder.build(snapshot: snap, store: store, storage: storage, config: config), as: format)
    }
}

struct SeriesPointValue: Sendable { let date: Date; let value: Double }

extension ProcessRecord {
    var powerSort: Double { powerWatts ?? -1 }
    var wakeupSort: Double { wakeupsPerSecond ?? -1 }
    var cpuSort: Double { cpuPercent ?? -1 }
    var memorySort: UInt64 { footprint ?? 0 }
    var startSort: Double { startTime.timeIntervalSince1970 }
}
