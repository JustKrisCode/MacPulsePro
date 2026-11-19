import AppKit
import MacPulseCore
import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var categoryFilter: ProcessCategory?
    @State private var sortOrder = [KeyPathComparator(\ProcessRecord.cpuSort, order: .reverse)]
    @State private var selection: ProcessRecord.ID?
    @State private var treeMode = false

    var filtered: [ProcessRecord] {
        let all = model.snapshot?.processes ?? []
        return all.filter { p in
            (categoryFilter == nil || p.category == categoryFilter) &&
            (search.isEmpty || p.name.localizedCaseInsensitiveContains(search) || String(p.pid) == search ||
             (p.path?.localizedCaseInsensitiveContains(search) ?? false))
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Processes").font(.title2.weight(.semibold))
                    Text("\(filtered.count) of \(model.snapshot?.processes.count ?? 0)").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Category", selection: $categoryFilter) {
                        Text("All").tag(ProcessCategory?.none)
                        ForEach(ProcessCategory.allCases, id: \.self) { Text($0.rawValue).tag(ProcessCategory?.some($0)) }
                    }
                    .frame(maxWidth: 200)
                    Toggle("Tree", isOn: $treeMode).toggleStyle(.switch)
                }
                .padding(12)
                if treeMode {
                    ProcessTreeList(selection: $selection, filter: search)
                } else {
                    Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                        TableColumn("Process", value: \.name) { p in
                            HStack(spacing: 6) {
                                if let icon = appIcon(p) { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                Text(p.name).lineLimit(1)
                            }
                        }
                        TableColumn("PID", value: \.pid) { Text("\($0.pid)").monospacedDigit() }.width(60)
                        TableColumn("CPU", value: \.cpuSort) { Text(Format.percent($0.cpuPercent, digits: 1)).monospacedDigit() }.width(64)
                        TableColumn("Memory", value: \.memorySort) { p in
                            Text(p.accessible ? Format.memory(p.footprint) : "n/a").monospacedDigit().foregroundStyle(p.accessible ? .primary : .tertiary)
                        }.width(84)
                        TableColumn("Runtime", value: \.startSort) { Text(Format.duration($0.runtime)).monospacedDigit() }.width(80)
                        TableColumn("Threads") { Text($0.threads.map(String.init) ?? "—").monospacedDigit() }.width(60)
                        TableColumn("User", value: \.user) { Text($0.user).foregroundStyle(.secondary) }.width(90)
                        TableColumn("Kind") { Text($0.category.rawValue).foregroundStyle(.secondary) }.width(110)
                    }
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            .searchable(text: $search, placement: .toolbar, prompt: "Name, PID or path")

            Group {
                if let id = selection, let p = model.snapshot?.processes.first(where: { $0.id == id }) {
                    ProcessInspectorView(record: p)
                } else {
                    ContentUnavailableView("Select a process", systemImage: "sidebar.right", description: Text("Inspect details before taking any action."))
                }
            }
            .frame(minWidth: 320, idealWidth: 380, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func appIcon(_ p: ProcessRecord) -> NSImage? {
        guard p.category == .application else { return nil }
        return NSRunningApplication(processIdentifier: p.pid)?.icon
    }
}

struct ProcessTreeList: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: ProcessRecord.ID?
    let filter: String

    var body: some View {
        let roots = ProcessAnalyzer.tree(model.snapshot?.processes ?? [])
        List(selection: $selection) {
            OutlineGroup(roots, children: \.childNodes) { node in
                HStack {
                    Text(node.record.name).fontWeight(filter.isEmpty || !node.record.name.localizedCaseInsensitiveContains(filter) ? .regular : .bold)
                    Text("\(node.record.pid)").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if (node.record.cpuPercent ?? 0) >= 1 { Text(Format.percent(node.record.cpuPercent)).foregroundStyle(.orange).monospacedDigit() }
                    Text(Format.memory(node.subtreeFootprint)).foregroundStyle(.secondary).monospacedDigit()
                }
                .tag(node.record.id)
            }
        }
    }
}

struct ProcessInspectorView: View {
    @Environment(AppModel.self) private var model
    let record: ProcessRecord
    @State private var details: ProcessDetails?
    @State private var confirmTerminate = false
    @State private var confirmForce = false
    @State private var outcome: TerminationOutcome?
    @State private var working = false

    var decision: TerminationPolicy.Decision { TerminationPolicy.evaluate(record, ownAncestors: []) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(record.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("PID \(record.pid) · parent \(record.ppid) · \(record.category.rawValue)").foregroundStyle(.secondary)
                Card {
                    StatRow(label: "CPU", value: Format.percent(record.cpuPercent, digits: 1))
                    StatRow(label: "CPU time", value: Format.duration(record.cpuTimeSeconds))
                    StatRow(label: "Memory (footprint)", value: Format.memory(record.footprint), provenance: record.accessible ? .measured : .unavailable)
                    StatRow(label: "Resident", value: Format.memory(record.residentSize))
                    StatRow(label: "Threads", value: record.threads.map(String.init) ?? "—")
                    StatRow(label: "Started", value: record.startTime.formatted(date: .abbreviated, time: .shortened))
                    StatRow(label: "Runtime", value: Format.duration(record.runtime))
                    StatRow(label: "Disk read / written", value: "\(Format.bytes(record.diskBytesRead)) / \(Format.bytes(record.diskBytesWritten))")
                }
                if let pts = model.processHistory[record.identity], pts.count > 2 {
                    Card(title: "This session", systemImage: "chart.xyaxis.line") {
                        TimeSeriesChart(points: pts.compactMap { p in p.cpu.map { SeriesPoint(date: p.timestamp, value: $0, series: "CPU %") } },
                                        format: { "\(Int($0))%" }, height: 90)
                        TimeSeriesChart(points: pts.compactMap { p in p.footprint.map { SeriesPoint(date: p.timestamp, value: Double($0) / 1_048_576, series: "Memory MB") } },
                                        color: .purple, format: { "\(Int($0)) MB" }, height: 90)
                    }
                }
                if let d = details {
                    Card(title: "Identity", systemImage: "person.text.rectangle") {
                        LabeledText("Path", record.path ?? "—")
                        LabeledText("Working directory", d.workingDirectory ?? "—")
                        LabeledText("Bundle", record.bundleIdentifier ?? "—")
                        LabeledText("Signature", d.signature.status.rawValue + (d.signature.teamIdentifier.map { " · team \($0)" } ?? ""))
                        LabeledText("User", "\(record.user) (uid \(record.uid))")
                        if let a = d.arguments { LabeledText("Arguments (secrets redacted)", a.joined(separator: " ")) }
                        LabeledText("Ancestry", ([record] + d.ancestors).map { "\($0.name) (\($0.pid))" }.joined(separator: " ← "))
                        if !d.children.isEmpty { LabeledText("Children", d.children.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")) }
                    }
                }
                Card(title: "Action", systemImage: "hand.raised") {
                    if decision.allowed {
                        ForEach(decision.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                        HStack {
                            Button(record.category == .application ? "Quit Application…" : "Terminate…") { confirmTerminate = true }
                                .disabled(working)
                            if outcome == .stillRunning { Button("Force Quit…", role: .destructive) { confirmForce = true } }
                            if working { ProgressView().controlSize(.small) }
                        }
                        if let o = outcome { Text("Result: \(o.description)").font(.callout).foregroundStyle(.secondary) }
                    } else {
                        Label("Protected: \(decision.reason ?? "")", systemImage: "lock.fill").foregroundStyle(.secondary)
                    }
                    Text("Before any signal, MacPulse re-checks the PID and start time so a reused PID is never targeted.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .task(id: record.id) {
            outcome = nil
            let pid = record.pid
            let all = model.snapshot?.processes ?? []
            details = await Task.detached { ProcessInspector.details(pid: pid, in: all) }.value
        }
        .confirmationDialog("\(record.category == .application ? "Quit" : "Terminate") \(record.name)?", isPresented: $confirmTerminate) {
            Button(record.category == .application ? "Quit" : "Terminate", role: .destructive) { run(force: false) }
        } message: {
            Text(record.category == .application ? "The app is asked to quit and may prompt you to save." : "A graceful termination signal (SIGTERM) is sent to PID \(record.pid).")
        }
        .confirmationDialog("Force quit \(record.name)?", isPresented: $confirmForce) {
            Button("Force Quit", role: .destructive) { run(force: true) }
        } message: { Text("SIGKILL ends the process immediately. Unsaved work is lost.") }
    }

    func run(force: Bool) {
        working = true
        Task {
            outcome = await model.terminate(record, force: force)
            working = false
        }
    }
}

struct LabeledText: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).lineLimit(6)
        }
    }
}
