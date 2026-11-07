import Foundation
import Observation

/// 浏览状态挂在 AppModel 上；切换目录时丢弃旧扫描，磁盘读取始终在 blocking 中。
@Observable
@MainActor
final class AppDataBrowser {
    private(set) var target: AppDataTarget?
    private(set) var path = ""
    private(set) var entries: [AppDataEntry] = []
    private(set) var selected: Set<String> = []
    private(set) var chosen: [AppDataEntry] = []
    private(set) var loading = false
    private(set) var measuring = false
    private(set) var error: String?
    var focused: String?
    var deleting = false

    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var sample = false
    @ObservationIgnored private var sampleRemoved: Set<String> = []
    @ObservationIgnored private var positions: [String: Int] = [:]
    @ObservationIgnored private let scan: @Sendable (AppDataTarget, String) -> AppDataListing
    @ObservationIgnored private var cancellation = AppDataScanCancellation()
    @ObservationIgnored private let measure: @Sendable (AppDataEntry, String, AppDataScanCancellation) -> AppDataEntry

    init(scan: @escaping @Sendable (AppDataTarget, String) -> AppDataListing = { AppDataScanner.list($0, path: $1) },
         measure: @escaping @Sendable (AppDataEntry, String, AppDataScanCancellation) -> AppDataEntry = { AppDataScanner.measured($0, root: $1, cancellation: $2) }) {
        self.scan = scan
        self.measure = measure
    }

    var current: AppDataEntry? { focused.flatMap { positions[$0] }.map { entries[$0] } }
    var canGoBack: Bool { target.map { path != URL(filePath: $0.root).standardizedFileURL.path } ?? false }

    func open(_ target: AppDataTarget, sample: Bool = false) {
        cancellation.cancel()
        revision += 1
        self.target = target
        self.sample = sample
        sampleRemoved = []
        path = URL(filePath: target.root).standardizedFileURL.path
        entries = []
        selected = []
        chosen = []
        positions = [:]
        focused = nil
        loading = true
        measuring = false
        deleting = false
        error = nil
    }

    func close() {
        cancellation.cancel()
        revision += 1
        target = nil
        entries = []
        selected = []
        chosen = []
        positions = [:]
        focused = nil
        loading = false
        measuring = false
    }

    func toggle(_ entry: AppDataEntry) {
        guard !deleting, let index = positions[entry.path], entries[index].canSelect else { return }
        if !selected.insert(entry.path).inserted { selected.remove(entry.path) }
        updateChosen()
    }

    func toggleAll() {
        guard !deleting else { return }
        let selectable = Set(entries.filter(\.canSelect).map(\.path))
        selected = selected == selectable ? [] : selectable
        updateChosen()
    }

    func clearSelection() { selected = []; chosen = [] }

    private func updateChosen() {
        chosen = selected.compactMap { positions[$0] }.sorted().map { entries[$0] }
    }

    func moveFocus(by step: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        let index = focused.flatMap { positions[$0] }.map { min(max($0 + step, 0), entries.count - 1) } ?? 0
        focused = entries[index].path
        return focused
    }

    func enter(_ entry: AppDataEntry) async {
        guard !deleting, let index = positions[entry.path], entries[index].canEnter else { return }
        await refresh(at: entry.path)
    }

    func goBack() async {
        guard canGoBack, !deleting else { return }
        await refresh(at: URL(filePath: path).deletingLastPathComponent().path)
    }

    func removeSample(_ paths: [String]) {
        sampleRemoved.formUnion(paths)
    }

    func refresh(at requested: String? = nil) async {
        guard let target, !deleting else { return }
        cancellation.cancel()
        let cancellation = AppDataScanCancellation()
        self.cancellation = cancellation
        revision += 1
        let run = revision
        let directory = requested ?? path
        let sample = sample
        let scan = scan
        loading = true
        measuring = false
        error = nil
        selected = []
        chosen = []
        positions = [:]
        focused = nil
        entries = []
        path = directory
        let removed = sampleRemoved
        let (listing, indices, pending) = await blocking {
            var listing = sample ? Sample.appDataListing(target, path: directory) : scan(target, directory)
            if !removed.isEmpty { listing.entries.removeAll { removed.contains($0.path) } }
            let indices = Dictionary(uniqueKeysWithValues: listing.entries.enumerated().map { ($0.element.path, $0.offset) })
            return (listing, indices, listing.entries.filter { !$0.isMeasured })
        }
        guard run == revision else { return }
        path = listing.path
        error = listing.error
        positions = indices
        entries = listing.entries
        loading = false
        guard !pending.isEmpty else { return }
        measuring = true
        let measure = measure
        let positions = indices
        await withTaskGroup(of: AppDataEntry?.self) { group in
            var remaining = pending[...]
            for item in remaining.prefix(6) {
                group.addTask { await AppDataMeasurementLimiter.shared.measured(item, root: target.root, cancellation: cancellation, work: measure) }
            }
            remaining = remaining.dropFirst(6)
            var completed: [AppDataEntry] = []
            var flushed = ContinuousClock.now
            @MainActor func flush() {
                var updated = entries
                for item in completed {
                    if let index = positions[item.path] { updated[index] = item }
                }
                entries = updated
                if !selected.isEmpty { updateChosen() }
                completed = []
                flushed = .now
            }
            for await item in group {
                guard run == revision else { group.cancelAll(); return }
                guard let item else { continue }
                completed.append(item)
                if flushed.duration(to: .now) > .milliseconds(300) { flush() }
                if let next = remaining.popFirst() {
                    group.addTask { await AppDataMeasurementLimiter.shared.measured(next, root: target.root, cancellation: cancellation, work: measure) }
                }
            }
            guard run == revision else { return }
            flush()
        }
        guard run == revision else { return }
        let measuredEntries = entries
        let (ordered, orderedPositions) = await blocking {
            let ordered = measuredEntries.sorted {
                if $0.size != $1.size { return ($0.size ?? -1) > ($1.size ?? -1) }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return (ordered, Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.path, $0.offset) }))
        }
        guard run == revision else { return }
        self.positions = orderedPositions
        entries = ordered
        if !selected.isEmpty { updateChosen() }
        measuring = false
    }
}
