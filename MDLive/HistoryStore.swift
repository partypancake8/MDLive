import Foundation
import CryptoKit

/// One saved version of a file in the global edit log.
struct HistoryVersion: Codable, Equatable, Identifiable {
    let id: String
    var timestamp: Date
    let label: String
    var bytes: Int
    var sha256: String
}

/// Version history for every file MDLive opens (Google Docs style, basic).
///
/// Layout on disk, under `root`:
///   <sha256 of the standardized absolute path>/index.json   {path, versions: [...]}
///   <sha256 of the standardized absolute path>/<id>.md      one snapshot per version
///
/// Labels: `opened` (baseline at open), `you` (MDLive autosave), `outside`
/// (another program changed the file), `restored` (Restore from the sidebar).
/// A `you` save within `coalesceWindow` of a newest `you` version replaces it.
/// A version equal to the newest snapshot is never recorded. Pure Swift, no UI.
final class HistoryStore {
    enum Label: String { case opened, you, outside, restored }

    struct Index: Codable {
        var path: String
        var versions: [HistoryVersion]
    }

    static let shared = HistoryStore(root: HistoryStore.defaultRoot())

    let root: URL
    var now: () -> Date = Date.init
    var coalesceWindow: TimeInterval = 120
    var perFileCap = 200
    var globalCapBytes = 500 * 1024 * 1024
    private var counter = 0

    init(root: URL) { self.root = root }

    /// `MDLIVE_HISTORY_DIR` when set; a throwaway temp folder inside XCTest (so
    /// tests never touch the real log); else Application Support/MDLive/history.
    static func defaultRoot(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = env["MDLIVE_HISTORY_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        if env["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("mdlive-history-tests-\(getpid())", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("MDLive/history", isDirectory: true)
    }

    // MARK: keys and paths

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Folder name for a file: SHA-256 of its standardized absolute path.
    static func key(for url: URL) -> String {
        sha256(Data(url.standardizedFileURL.path.utf8))
    }

    func folder(for url: URL) -> URL { root.appendingPathComponent(Self.key(for: url), isDirectory: true) }
    private func indexURL(_ folder: URL) -> URL { folder.appendingPathComponent("index.json") }
    private func snapshotURL(_ folder: URL, _ id: String) -> URL { folder.appendingPathComponent("\(id).md") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(HistoryStore.iso.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = HistoryStore.iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: reading

    private func loadIndex(_ folder: URL) -> Index? {
        guard let d = try? Data(contentsOf: indexURL(folder)) else { return nil }
        return try? Self.decoder.decode(Index.self, from: d)
    }

    private func saveIndex(_ index: Index, _ folder: URL) throws {
        try Self.encoder.encode(index).write(to: indexURL(folder), options: .atomic)
    }

    /// Versions for a file, oldest first.
    func versions(for url: URL) -> [HistoryVersion] { loadIndex(folder(for: url))?.versions ?? [] }

    /// The exact bytes saved for a version.
    func snapshotData(_ id: String, for url: URL) -> Data? {
        try? Data(contentsOf: snapshotURL(folder(for: url), id))
    }

    func snapshot(_ id: String, for url: URL) -> String? {
        snapshotData(id, for: url).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: recording

    /// Record `text` as the file's newest version. Returns the version written
    /// (new or coalesced), or nil when nothing was recorded (same as newest).
    @discardableResult
    func record(_ text: String, for url: URL, label: Label) -> HistoryVersion? {
        let data = Data(text.utf8)
        let hash = Self.sha256(data)
        let dir = folder(for: url)
        var index = loadIndex(dir) ?? Index(path: url.standardizedFileURL.path, versions: [])
        if index.versions.last?.sha256 == hash { return nil }
        let t = now()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if label == .you, var last = index.versions.last, last.label == Label.you.rawValue,
               t.timeIntervalSince(last.timestamp) <= coalesceWindow {
                try data.write(to: snapshotURL(dir, last.id), options: .atomic)
                last.timestamp = t; last.bytes = data.count; last.sha256 = hash
                index.versions[index.versions.count - 1] = last
                try saveIndex(index, dir)
                return last
            }
            let v = HistoryVersion(id: makeID(t), timestamp: t, label: label.rawValue, bytes: data.count, sha256: hash)
            try data.write(to: snapshotURL(dir, v.id), options: .atomic)
            index.versions.append(v)
            while index.versions.count > perFileCap {
                let old = index.versions.removeFirst()
                try? FileManager.default.removeItem(at: snapshotURL(dir, old.id))
            }
            try saveIndex(index, dir)
            pruneGlobal()
            return v
        } catch {
            NSLog("MDLive: history write failed for %@: %@", url.path, error.localizedDescription)
            return nil
        }
    }

    private func makeID(_ t: Date) -> String {
        counter += 1
        return String(format: "%013lld-%04d", Int64(t.timeIntervalSince1970 * 1000), counter % 10000)
    }

    /// Keep the whole log under `globalCapBytes` by dropping the oldest versions
    /// across all files. Each file keeps at least its newest version.
    func pruneGlobal() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var indexes: [(URL, Index)] = dirs.compactMap { d in loadIndex(d).map { (d, $0) } }
        var total = indexes.reduce(0) { $0 + $1.1.versions.reduce(0) { $0 + $1.bytes } }
        guard total > globalCapBytes else { return }
        var touched = Set<Int>()
        while total > globalCapBytes {
            var pick: (Int, Date)? = nil
            for (i, entry) in indexes.enumerated() where entry.1.versions.count > 1 {
                let ts = entry.1.versions[0].timestamp
                if pick == nil || ts < pick!.1 { pick = (i, ts) }
            }
            guard let (i, _) = pick else { break }
            let old = indexes[i].1.versions.removeFirst()
            try? fm.removeItem(at: snapshotURL(indexes[i].0, old.id))
            total -= old.bytes
            touched.insert(i)
        }
        for i in touched { try? saveIndex(indexes[i].1, indexes[i].0) }
    }
}
