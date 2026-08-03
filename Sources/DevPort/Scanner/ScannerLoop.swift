import Foundation

/// Snapshot difference between two consecutive scans.
struct ScanDiff: Sendable {
    let added: Set<ListeningPort>
    let removed: Set<ListeningPort>
}

/// Polls PortScanner on a fixed interval, logs diffs, and streams them to
/// consumers. A failed scan skips the tick and keeps the previous snapshot.
actor ScannerLoop {
    static let shared = ScannerLoop()

    private var previous: Set<ListeningPort> = []
    private var running = false
    private var continuation: AsyncStream<ScanDiff>.Continuation?

    func events() -> AsyncStream<ScanDiff> {
        AsyncStream { self.continuation = $0 }
    }

    func start(interval: Duration = .seconds(2.5)) {
        guard !running else { return }
        running = true
        Task { await loop(interval: interval) }
    }

    private func loop(interval: Duration) async {
        while true {
            tick()
            try? await Task.sleep(for: interval)
        }
    }

    private func tick() {
        let snapshot: Set<ListeningPort>
        do {
            snapshot = try PortScanner.scan()
        } catch {
            scannerLog.error("scan failed, skipping tick: \(error)")
            return
        }

        let added = snapshot.subtracting(previous)
        let removed = previous.subtracting(snapshot)

        for p in added.sorted(by: { $0.port < $1.port }) {
            scannerLog.info("+ port \(p.port) (pid \(p.pid))")
        }
        for p in removed.sorted(by: { $0.port < $1.port }) {
            scannerLog.info("- port \(p.port) (pid \(p.pid))")
        }

        if !added.isEmpty || !removed.isEmpty {
            continuation?.yield(ScanDiff(added: added, removed: removed))
        }
        previous = snapshot
    }
}
