import AppKit
import Charts
import MacPulseCore
import SwiftUI

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Cleanup").tag(0)
                Text("Large Files").tag(1)
                Text("Duplicates").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
            .padding(.top, 14)
            switch tab {
            case 0: CleanupPane()
            case 1: LargeFilesPane()
            default: DuplicatesPane()
            }
        }
    }
}

struct CleanupPane: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Set<String>()
    @State private var includePersonal = false
    @State private var mode: CleanupMode = .trash
    @State private var plan: [CleanupItemResult]?
    @State private var results: [CleanupRunResult]?
    @State private var running = false
    @State private var filter: CleanupClass? = nil

    var guardian: PathGuard { PathGuard(rules: CleanupCatalog.rules(), allowPersonalFolders: includePersonal) }

    var body: some View {
        ScrollPage {
            HStack {
                SectionHeader(title: "Storage", subtitle: "Read-only analysis. Nothing is removed without an explicit, validated confirmation.")
                Toggle("Include Downloads", isOn: $includePersonal).toggleStyle(.checkbox)
                    .help("Scans ~/Downloads for old installers (macOS may ask for permission)")
                if model.storageScanning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelScan() }
                } else {
                    Button(model.storage == nil ? "Analyze" : "Re-analyze") { selected = []; model.scanStorage(includePersonal: includePersonal) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let v = model.snapshot?.volume { VolumeCard(volume: v) }
            if let a = model.storage {
                summary(a)
                candidates(a)
                if !a.protectedItems.isEmpty {
                    Card(title: "Protected — never cleaned", systemImage: "lock.shield") {
                        ForEach(a.protectedItems) { p in
                            HStack {
                                ClassBadge(cls: .protected)
                                Text(p.title)
                                Spacer()
                                Text(p.usage.permissionDenied > 0 && p.usage.allocated == 0 ? "not readable" : Format.bytes(p.usage.allocated)).monospacedDigit()
                            }
                            Text(p.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(a.notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            } else if !model.storageScanning {
                ContentUnavailableView("No analysis yet", systemImage: "internaldrive",
                                       description: Text("Analyze measures caches, logs, temporary files and developer data. It only reads."))
                    .frame(minHeight: 240)
            }
        }
        .sheet(item: Binding(get: { plan.map { PlanBox(items: $0) } }, set: { if $0 == nil { plan = nil } })) { box in
            ConfirmCleanupSheet(plan: box.items, running: running, onCancel: { plan = nil }, onConfirm: { execute() })
        }
        .sheet(item: Binding(get: { results.map { ResultBox(runs: $0) } }, set: { if $0 == nil { results = nil } })) { box in
            CleanupResultSheet(runs: box.runs) { results = nil }
        }
    }

    func summary(_ a: StorageAnalysis) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Reclaimable (estimated)", systemImage: "sparkles") {
                HStack(spacing: 24) {
                    VStack(alignment: .leading) { ClassBadge(cls: .safe); Text(Format.bytes(a.bytes(.safe))).font(.title2.weight(.semibold).monospacedDigit()) }
                    VStack(alignment: .leading) { ClassBadge(cls: .review); Text(Format.bytes(a.bytes(.review))).font(.title2.weight(.semibold).monospacedDigit()) }
                }
                Text("Allocated bytes (sparse/compressed aware; hard links counted once). APFS clones can make real savings smaller.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "By category", systemImage: "chart.pie") {
                Chart(a.byCategory(), id: \.0) { cat, bytes in
                    SectorMark(angle: .value("Bytes", Double(bytes)), innerRadius: .ratio(0.6), angularInset: 1)
                        .foregroundStyle(by: .value("Category", cat.title))
                }
                .frame(height: 150)
            }
        }
    }

    func candidates(_ a: StorageAnalysis) -> some View {
        let rows = a.candidates.filter { filter == nil || $0.classification == filter }
        let chosen = a.candidates.filter { selected.contains($0.id) }
        return Card(title: "Cleanup candidates", systemImage: "checklist") {
            HStack {
                Picker("Show", selection: $filter) {
                    Text("All").tag(CleanupClass?.none)
                    Text("Safe").tag(CleanupClass?.some(.safe))
                    Text("Review").tag(CleanupClass?.some(.review))
                }
                .pickerStyle(.segmented).frame(maxWidth: 260)
                Button("Select all safe") { selected = Set(a.candidates.filter { $0.classification == .safe && $0.isSelectable }.map(\.id)) }
                Button("Clear") { selected = [] }
                Spacer()
                Picker("Method", selection: $mode) {
                    Text("Move to Trash").tag(CleanupMode.trash)
                    Text("Delete permanently").tag(CleanupMode.delete)
                }
                .frame(maxWidth: 220)
                Button("Review \(chosen.count) item(s)…") {
                    Task { plan = await model.planCleanup(chosen, mode: mode, guardian: guardian) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty)
            }
            Table(rows) {
                TableColumn("") { (c: CleanupCandidate) in
                    Toggle("", isOn: Binding(get: { selected.contains(c.id) },
                                             set: { on in if on { selected.insert(c.id) } else { selected.remove(c.id) } }))
                        .labelsHidden().disabled(!c.isSelectable)
                }.width(24)
                TableColumn("Class") { (c: CleanupCandidate) in ClassBadge(cls: c.classification) }.width(80)
                TableColumn("Item") { (c: CleanupCandidate) in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).fontWeight(.medium)
                        Text(c.path).font(.caption).foregroundStyle(.secondary).truncationMode(.middle).lineLimit(1)
                    }
                    .help("\(c.reason)\nIf removed: \(c.consequence)")
                }
                TableColumn("Size") { (c: CleanupCandidate) in Text(Format.bytes(c.estimatedBytes)).monospacedDigit() }.width(80)
                TableColumn("Modified") { (c: CleanupCandidate) in Text(c.modified.map { $0.formatted(.relative(presentation: .named)) } ?? "—").foregroundStyle(.secondary) }.width(110)
                TableColumn("Status") { (c: CleanupCandidate) in
                    if let b = c.blockedReason { Text(c.inUseBy.isEmpty ? "Blocked" : "In use").foregroundStyle(.orange).help(b) }
                    else { Text(c.allowsTrash ? "Ready" : "Delete only").foregroundStyle(.secondary) }
                }.width(90)
                TableColumn("") { (c: CleanupCandidate) in
                    Button { NSWorkspace.shared.selectFile(c.path, inFileViewerRootedAtPath: "") } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Reveal in Finder")
                }.width(28)
            }
            .frame(minHeight: 380)
        }
    }

    func execute() {
        guard let a = model.storage, let plan else { return }
        let ok = Set(plan.filter { $0.status == .dryRun }.map(\.candidateID))
        let items = a.candidates.filter { ok.contains($0.id) }
        running = true
        Task {
            let r = await model.executeCleanup(items, mode: mode, guardian: guardian)
            running = false
            self.plan = nil
            switch r {
            case .success(let runs): results = runs; selected = []
                model.scanStorage(includePersonal: includePersonal)
            case .failure(let e): model.banner = e.description
            }
        }
    }
}

struct PlanBox: Identifiable { let items: [CleanupItemResult]; var id: String { items.map(\.id).joined() } }
struct ResultBox: Identifiable { let runs: [CleanupRunResult]; var id: String { runs.map(\.runID).joined() } }

struct VolumeCard: View {
    let volume: VolumeSnapshot
    var body: some View {
        Card(title: volume.name ?? "Startup disk", systemImage: "internaldrive") {
            let used = Double(volume.used), total = Double(max(volume.total, 1))
            let purge = Double(volume.purgeableEstimate.value ?? 0)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: geo.size.width * used / total)
                    Rectangle().fill(Color.orange.opacity(0.6)).frame(width: geo.size.width * purge / total)
                    Rectangle().fill(Color.gray.opacity(0.2))
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 14)
            HStack(spacing: 24) {
                StatRow(label: "Used", value: Format.bytes(volume.used))
                StatRow(label: "Free", value: Format.bytes(volume.available), provenance: .measured)
                StatRow(label: "Purgeable", value: Format.bytes(volume.purgeableEstimate.value), provenance: .estimated)
                StatRow(label: "Capacity", value: Format.bytes(volume.total))
            }
        }
    }
}

struct ConfirmCleanupSheet: View {
    let plan: [CleanupItemResult]
    let running: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let ok = plan.filter { $0.status == .dryRun }
        let permanent = ok.filter { $0.mode == .delete }
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm cleanup").font(.title2.weight(.semibold))
            Text("Every item below was re-validated just now (allowlisted location, not in use, unchanged since the scan).")
                .foregroundStyle(.secondary)
            List(plan) { r in
                HStack {
                    Image(systemName: r.status == .dryRun ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(r.status == .dryRun ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(r.path).lineLimit(1).truncationMode(.middle)
                        Text(r.message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(r.mode == .trash ? "Trash" : "Delete").foregroundStyle(r.mode == .delete ? .red : .secondary)
                    Text(Format.bytes(r.estimatedBytes)).monospacedDigit()
                }
            }
            .frame(minHeight: 220)
            if !permanent.isEmpty {
                Label("\(permanent.count) item(s) will be permanently deleted and cannot be recovered.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if ok.contains(where: { $0.mode == .trash }) {
                Text("Items moved to the Trash can be restored; their space is freed when the Trash is emptied.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(ok.count) item(s), ≈ \(Format.bytes(ok.map(\.estimatedBytes).reduce(0, +))) (estimated)").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(permanent.isEmpty ? "Move to Trash" : "Clean Up", role: .destructive, action: onConfirm)
                    .disabled(ok.isEmpty || running)
                if running { ProgressView().controlSize(.small) }
            }
        }
        .padding(24)
        .frame(width: 720, height: 520)
    }
}

struct CleanupResultSheet: View {
    let runs: [CleanupRunResult]
    let done: () -> Void

    var body: some View {
        let items = runs.flatMap(\.items)
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup finished").font(.title2.weight(.semibold))
            HStack(spacing: 28) {
                StatRow(label: "Deleted (measured)", value: Format.bytes(runs.map(\.removedTotal).reduce(0, +)), provenance: .measured)
                StatRow(label: "Moved to Trash", value: Format.bytes(runs.map(\.trashedTotal).reduce(0, +)), provenance: .estimated)
                StatRow(label: "Free-space change", value: Format.bytes(runs.compactMap(\.measuredVolumeDelta).reduce(0, +)), provenance: .measured)
            }
            List(items) { r in
                HStack {
                    Text(r.status.rawValue).foregroundStyle(r.status == .deleted || r.status == .trashed ? .green : .orange).frame(width: 110, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text(r.path).lineLimit(1).truncationMode(.middle)
                        Text(r.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("The free-space change is measured on the volume and includes other activity during the cleanup.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 680, height: 480)
    }
}

@MainActor
func chooseFolder(_ title: String) -> String? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct LargeFilesPane: View {
    @Environment(AppModel.self) private var model
    @State private var root: String?
    @State private var files: [LargeFile] = []
    @State private var denied = 0
    @State private var scanning = false
    @State private var minGB = 1.0
    @State private var confirm: LargeFile?

    var body: some View {
        ScrollPage {
            HStack {
                SectionHeader(title: "Large Files", subtitle: "Clone-aware sizes: “private” is what deleting would actually free.")
                Stepper("≥ \(String(format: "%.1f", minGB)) GB", value: $minGB, in: 0.1...50, step: 0.5)
                Button("Choose Folder…") {
                    guard let r = chooseFolder("Choose a folder to search for large files") else { return }
                    root = r; scan()
                }
                .buttonStyle(.borderedProminent)
            }
            if scanning { ProgressView("Searching \(root ?? "")…") }
            if let root, !scanning {
                Card(title: "\(files.count) files in \(root)", systemImage: "doc") {
                    Table(files) {
                        TableColumn("Class") { (f: LargeFile) in ClassBadge(cls: f.classification) }.width(80)
                        TableColumn("File") { (f: LargeFile) in Text(f.path).lineLimit(1).truncationMode(.middle).help(f.note) }
                        TableColumn("Allocated") { (f: LargeFile) in Text(Format.bytes(f.allocated)).monospacedDigit() }.width(90)
                        TableColumn("Private") { (f: LargeFile) in Text(f.privateBytes.map { Format.bytes($0) } ?? "—").monospacedDigit() }.width(90)
                        TableColumn("Modified") { (f: LargeFile) in Text(f.modified.formatted(date: .abbreviated, time: .omitted)) }.width(110)
                        TableColumn("") { (f: LargeFile) in
                            HStack {
                                Button { NSWorkspace.shared.selectFile(f.path, inFileViewerRootedAtPath: "") } label: { Image(systemName: "magnifyingglass") }
                                    .help("Reveal in Finder")
                                if f.classification == .review {
                                    Button { confirm = f } label: { Image(systemName: "trash") }.help("Move to Trash…")
                                }
                            }
                            .buttonStyle(.borderless)
                        }.width(60)
                    }
                    .frame(minHeight: 420)
                    if denied > 0 { Text("\(denied) folders were not readable.").font(.caption).foregroundStyle(.orange) }
                    Text("Documents, media, source code and databases are PROTECTED: MacPulse only reveals them in Finder so you decide.").font(.caption).foregroundStyle(.secondary)
                }
            } else if !scanning {
                ContentUnavailableView("Choose a folder", systemImage: "folder", description: Text("MacPulse only reads folders you choose."))
            }
        }
        .confirmationDialog("Move “\((confirm?.path as NSString?)?.lastPathComponent ?? "")” to the Trash?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Move to Trash", role: .destructive) { if let f = confirm { trash(f) } }
        } message: {
            Text("You can restore it from the Trash.")
        }
    }

    func scan() {
        guard let root else { return }
        scanning = true
        let min = Int64(minGB * 1e9)
        Task.detached(priority: .utility) {
            let r = FileFinder.largeFiles(in: root, minSize: min)
            await MainActor.run { files = r.files; denied = r.permissionDenied; scanning = false }
        }
    }

    func trash(_ f: LargeFile) {
        guard let root else { return }
        let g = PathGuard(allowedRoots: [root], allowPersonalFolders: true)
        let c = FileFinder.candidates(for: [f], guardian: g)
        Task {
            if case .success(let runs) = await model.executeCleanup(c, mode: .trash, guardian: g) {
                model.banner = runs.first?.items.first?.message
            }
            scan()
        }
    }
}

struct DuplicatesPane: View {
    @Environment(AppModel.self) private var model
    @State private var root: String?
    @State private var groups: [DuplicateGroup] = []
    @State private var scanning = false
    @State private var chosen = Set<String>()
    @State private var confirming = false

    var body: some View {
        ScrollPage {
            HStack {
                SectionHeader(title: "Duplicates", subtitle: "Identical content (SHA-256). One copy in every group is always kept.")
                Button("Choose Folder…") {
                    guard let r = chooseFolder("Choose a folder to search for duplicates") else { return }
                    root = r; scan()
                }
                .buttonStyle(.borderedProminent)
            }
            if scanning { ProgressView("Hashing files…") }
            if !groups.isEmpty {
                HStack {
                    Text("\(groups.count) groups · keeping one copy each frees \(Format.bytes(groups.map(\.reclaimable).reduce(0, +)))").foregroundStyle(.secondary)
                    Spacer()
                    Button("Move \(chosen.count) selected to Trash…") { confirming = true }.disabled(chosen.isEmpty)
                }
                ForEach(groups) { g in
                    Card {
                        HStack {
                            Text("\(Format.bytes(g.size)) × \(g.files.count)").fontWeight(.medium)
                            Spacer()
                            Text("reclaim \(Format.bytes(g.reclaimable))").monospacedDigit()
                            ProvenanceBadge(provenance: g.reclaimProvenance)
                        }
                        ForEach(Array(g.files.enumerated()), id: \.element.path) { i, f in
                            HStack {
                                Toggle("", isOn: Binding(get: { chosen.contains(f.path) }, set: { on in
                                    if on {
                                        // Never allow every member of a group to be selected.
                                        let others = g.files.filter { $0.path != f.path }.map(\.path)
                                        if others.allSatisfy(chosen.contains) { return }
                                        chosen.insert(f.path)
                                    } else { chosen.remove(f.path) }
                                }))
                                .labelsHidden()
                                Text(f.path).lineLimit(1).truncationMode(.middle)
                                if i == 0 { Tag("oldest") }
                                if (f.privateBytes ?? f.allocated) < f.allocated / 2 { Tag("APFS clone") }
                                Spacer()
                                Button { NSWorkspace.shared.selectFile(f.path, inFileViewerRootedAtPath: "") } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                            }
                            .font(.callout)
                        }
                    }
                }
            } else if root != nil && !scanning {
                ContentUnavailableView("No duplicates", systemImage: "checkmark.circle", description: Text("No identical files of 1 MB or more."))
            } else if !scanning {
                ContentUnavailableView("Choose a folder", systemImage: "folder", description: Text("MacPulse only reads folders you choose."))
            }
        }
        .confirmationDialog("Move \(chosen.count) duplicate(s) to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { trashChosen() }
        } message: { Text("One copy of each file is kept. Items can be restored from the Trash.") }
    }

    func scan() {
        guard let root else { return }
        scanning = true; chosen = []
        Task.detached(priority: .utility) {
            let g = FileFinder.duplicates(in: root)
            await MainActor.run { groups = g; scanning = false }
        }
    }

    func trashChosen() {
        guard let root else { return }
        let guardian = PathGuard(allowedRoots: [root], allowPersonalFolders: true)
        var cands: [CleanupCandidate] = []
        for g in groups {
            let picked = g.files.filter { chosen.contains($0.path) }
            if !picked.isEmpty { cands += FileFinder.candidates(for: picked, groupID: g.id, guardian: guardian) }
        }
        Task {
            if case .failure(let e) = await model.executeCleanup(cands, mode: .trash, guardian: guardian) { model.banner = e.description }
            scan()
        }
    }
}
