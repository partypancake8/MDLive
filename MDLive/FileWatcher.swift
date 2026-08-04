import Foundation
import CoreServices

/// Watches a single file for external changes (DEC-7). Watches the PARENT
/// DIRECTORY via FSEvents (survives atomic-replace / temp-move that an fd watch
/// misses), debounces bursts, and requires a stable (mtime,size) sample before
/// emitting `.changed` (avoids reading mid-write). A 1s poll is a safety net.
final class FileWatcher {
    enum Event { case changed, deleted, appeared }

    let fileURL: URL
    private let dirURL: URL
    private let onEvent: (Event) -> Void
    private let enabled: Bool
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.ssmith.MDLive.filewatcher")

    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?
    private var poll: DispatchSourceTimer?

    private var exists: Bool
    private var mtime: TimeInterval
    private var size: UInt64

    init(fileURL: URL, enabled: Bool = true, pollInterval: TimeInterval = 1.0,
         onEvent: @escaping (Event) -> Void) {
        self.fileURL = fileURL.standardizedFileURL
        self.dirURL = self.fileURL.deletingLastPathComponent()
        self.enabled = enabled
        self.pollInterval = pollInterval
        self.onEvent = onEvent
        let s = FileWatcher.probe(self.fileURL)
        self.exists = s.exists; self.mtime = s.mtime; self.size = s.size
        guard enabled else { return } // auto-refresh off → no stream/timer (DEC-V12)
        startStream()
        startPolling()
    }

    deinit {
        NSLog("MDLive.FileWatcher.deinit %@", fileURL.lastPathComponent) // Step 10 teardown signal
        if let m = ProcessInfo.processInfo.environment["MDLIVE_GUI_MARKER"],
           let fh = FileHandle(forWritingAtPath: m) {
            fh.seekToEndOfFile()
            fh.write("watcher-deinit \(fileURL.path)\n".data(using: .utf8)!)
            try? fh.close()
        }
        stop()
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        poll?.cancel(); poll = nil
        debounce?.cancel(); debounce = nil
    }

    private func startStream() {
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().scheduleEvaluate()
        }
        let paths = [dirURL.path] as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.evaluate() }
        t.resume()
        poll = t
    }

    private func scheduleEvaluate() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.evaluate() }
        debounce = w
        queue.asyncAfter(deadline: .now() + 0.15, execute: w) // debounce 150ms (DEC-7)
    }

    /// Runs on `queue`. Diffs current file state vs last known and emits.
    private func evaluate() {
        let s1 = FileWatcher.probe(fileURL)
        if !s1.exists {
            if exists { exists = false; mtime = 0; size = 0; emit(.deleted) }
            return
        }
        if !exists {
            exists = true; mtime = s1.mtime; size = s1.size
            emit(.appeared)
            return
        }
        if s1.mtime != mtime || s1.size != size {
            // Stability check: re-sample ~60ms later; only emit when settled.
            usleep(60_000)
            let s2 = FileWatcher.probe(fileURL)
            if s2.exists && s2.mtime == s1.mtime && s2.size == s1.size {
                mtime = s2.mtime; size = s2.size
                emit(.changed)
            } // else still mid-write; next FS event or poll re-checks
        }
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent(e) }
    }

    private static func probe(_ url: URL) -> (exists: Bool, mtime: TimeInterval, size: UInt64) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (false, 0, 0)
        }
        let m = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let sz = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        return (true, m, sz)
    }
}
