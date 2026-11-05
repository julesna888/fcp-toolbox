import Foundation

public enum BatchStatus: Equatable, Sendable {
    case waiting
    case running(Double)
    case done(URL)
    case failed(String)
}

public struct BatchItem: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let file: URL
    public let label: String
    public let steps: [Step]
    public let outputDir: URL?
    /// 1-based position in the group it was added with: the {n} of a rename step.
    public let number: Int
    public var status: BatchStatus = .waiting
}

/// A universal queue: files with a list of steps each, run one after the other (one ffmpeg at a time).
/// A failing file never stops the others; failures can be run again.
@MainActor public final class BatchQueue: ObservableObject {
    public typealias Runner = @Sendable (BatchItem, ProxyControl, @escaping @Sendable (Double) -> Void) -> ConvertResult

    /// The queue the app shows; it outlives the panes, so a running queue is not lost when you change page.
    public static let shared = BatchQueue()

    @Published public private(set) var items: [BatchItem] = []
    @Published public private(set) var isRunning = false

    private let runner: Runner
    private var control = ProxyControl()
    private var stopRequested = false
    private var task: Task<Void, Never>?

    public init(runner: @escaping Runner = defaultBatchRunner) { self.runner = runner }

    public var counts: (waiting: Int, running: Int, done: Int, failed: Int) {
        var c = (waiting: 0, running: 0, done: 0, failed: 0)
        for i in items {
            switch i.status {
            case .waiting: c.waiting += 1
            case .running: c.running += 1
            case .done: c.done += 1
            case .failed: c.failed += 1
            }
        }
        return c
    }

    public var summary: String {
        let c = counts
        if isRunning { return TF("In corso: %@ di %@", c.done + c.failed, items.count) }
        if items.isEmpty { return "La coda è vuota." }
        var parts: [String] = []
        if c.done > 0 { parts.append("\(c.done) riusciti") }
        if c.failed > 0 { parts.append(TF("%@ con errore", c.failed)) }
        if c.waiting > 0 { parts.append(TF("%@ in attesa", c.waiting)) }
        return (c.waiting == 0 ? "Finito: " : "Fermo: ") + parts.joined(separator: ", ") + "."
    }

    /// Adds files to the queue (does not start it).
    public func add(_ files: [URL], steps: [Step], label: String, outputDir: URL? = nil) {
        items += files.enumerated().map { BatchItem(file: $1, label: label, steps: steps, outputDir: outputDir, number: $0 + 1) }
    }

    /// Starts (or continues) with the items that are waiting.
    public func start() {
        guard !isRunning, items.contains(where: { $0.status == .waiting }) else { return }
        isRunning = true
        stopRequested = false
        task = Task { [weak self] in
            while let self, !self.stopRequested, let i = self.items.firstIndex(where: { $0.status == .waiting }) {
                await self.runItem(at: i)
            }
            self?.isRunning = false
        }
    }

    private func runItem(at index: Int) async {
        let item = items[index]
        items[index].status = .running(0)
        control = ProxyControl()
        let c = control, runner = runner
        let id = item.id
        let r = await Task.detached(priority: .userInitiated) {
            runner(item, c, { f in Task { @MainActor [weak self] in self?.setProgress(id, f) } })
        }.value
        guard let now = items.firstIndex(where: { $0.id == id }) else { return }
        if let out = r.output, r.ok { items[now].status = .done(out) }
        else { items[now].status = .failed(r.problems.first ?? "Errore sconosciuto.") }
    }

    private func setProgress(_ id: UUID, _ f: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .running(let old) = items[i].status, f - old >= 0.01 else { return }
        items[i].status = .running(f)
    }

    /// Stops the file in progress (it counts as an error, "Interrotto") and the queue does not go on; the waiting ones stay waiting.
    public func stopAll() { stopRequested = true; control.cancel() }

    /// Stops only the file in progress; the queue goes on with the next one.
    public func stopCurrent() { control.cancel() }

    /// Puts the failed files back in line and runs them. Done files are not touched.
    public func retryFailed() {
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        start()
    }

    /// Removes finished items from the list (the files they made stay where they are).
    public func clearFinished() {
        guard !isRunning else { return }
        items.removeAll { if case .done = $0.status { return true } else { return false } }
    }

    /// Waits until the queue stops. For tests.
    public func waitUntilIdle() async { await task?.value }
}

/// Runs one queue item through the real pipeline.
public let defaultBatchRunner: BatchQueue.Runner = { item, control, progress in
    Doctor.runPipeline(item.file, steps: item.steps, label: item.label, outputDir: item.outputDir, number: item.number,
                       control: control, progress: progress)
}
