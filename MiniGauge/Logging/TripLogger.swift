import Foundation

/// Writes one CSV per trip into Documents/Logs (visible in the Files app,
/// shareable from the Logs screen). ~5 rows a second.
final class TripLogger {
    private var handle: FileHandle?
    private var started = Date()
    private var lastRow = Date.distantPast
    private var pending = ""
    private(set) var currentURL: URL?

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var isRunning: Bool { handle != nil }

    func start() {
        guard handle == nil else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.folder.appendingPathComponent("MiniGauge_\(f.string(from: Date())).csv")
        FileManager.default.createFile(atPath: url.path, contents: (TripCSV.header + "\n").data(using: .utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        currentURL = url
        started = Date()
        pending = ""
    }

    func add(_ e: EngineFrame, boostKpa: Double?) {
        guard handle != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRow) >= 0.2 else { return }
        lastRow = now
        pending += TripCSV.row(t: now.timeIntervalSince(started), frame: e, boostKpa: boostKpa) + "\n"
        if pending.utf8.count > 4096 { flush() }
    }

    func flush() {
        guard let h = handle, !pending.isEmpty, let d = pending.data(using: .utf8) else { return }
        h.write(d)
        pending = ""
    }

    func stop() {
        flush()
        try? handle?.close()
        handle = nil
        currentURL = nil
    }

    static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
