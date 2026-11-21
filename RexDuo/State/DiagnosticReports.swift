import Foundation
import MetricKit

/// The crash and hang reports the system hands the app (MetricKit), kept as files: the newest
/// `limit`. They are evidence for a problem after the fact, like the connection log: they stay on
/// the phone, out of its backups, and leave only in the file the user shares from Settings → About.
///
/// A report is the system's JSON cut down to the fields in `kept` before it is stored: call
/// stacks as binary names and offsets, the exception's numbers, the app's build, the device
/// model and the system's version. Everything else is dropped, the system's free text among it
/// (a termination reason, an exception's message), since such text can hold a path or a name.
struct DiagnosticReports: Sendable {
    struct Report: Equatable, Sendable {
        /// The end of the time the report covers.
        var date: Date
        var json: Data
    }

    /// How many reports are kept.
    static let limit = 20
    /// A report larger than this is not kept: the file the user shares stays small enough to send.
    static let maxBytes = 512 * 1024

    let folder: URL

    /// `Application Support/Diagnostics/Reports`, beside the connection log.
    static var standard: DiagnosticReports {
        DiagnosticReports(folder: ConnectionDiagnostics.file.deletingLastPathComponent()
            .appendingPathComponent("Reports", isDirectory: true))
    }

    /// The fields of a report that are kept. A field not named here never reaches a file.
    static let groups: Set<String> = [
        "crashDiagnostics", "hangDiagnostics", "cpuExceptionDiagnostics", "diskWriteExceptionDiagnostics",
        "appLaunchDiagnostics", "diagnosticMetaData", "callStackTree", "callStacks", "callStackRootFrames", "subFrames",
    ]
    /// Kept when they are numbers or yes-or-no values.
    static let numbers: Set<String> = [
        "exceptionType", "exceptionCode", "signal", "isTestFlightApp", "lowPowerModeEnabled", "callStackPerThread",
        "threadAttributed", "offsetIntoBinaryTextSegment", "sampleCount", "address",
    ]
    /// Kept when they are short text with no path, address or name in it (`isPlain`).
    static let texts: Set<String> = [
        "timeStampBegin", "timeStampEnd", "version", "appBuildVersion", "appVersion", "osVersion", "deviceType",
        "platformArchitecture", "binaryName", "binaryUUID", "hangDuration", "launchDuration", "totalCPUTime",
        "totalSampledTime", "writesCaused",
    ]
    static var kept: Set<String> { groups.union(numbers).union(texts) }

    /// The report with only the kept fields, or nil when it is not a JSON object.
    static func clean(_ json: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: clean(object), options: [.sortedKeys])
    }

    private static func clean(_ object: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in object {
            if groups.contains(key) {
                if let one = value as? [String: Any] {
                    out[key] = clean(one)
                } else if let many = value as? [Any] {
                    out[key] = many.compactMap { ($0 as? [String: Any]).map(clean) }
                }
            } else if numbers.contains(key) {
                if value is NSNumber { out[key] = value }
            } else if texts.contains(key), var text = value as? String {
                // A binary's name, never where it is.
                if key == "binaryName" { text = (text as NSString).lastPathComponent }
                if isPlain(text) { out[key] = text }
            }
        }
        return out
    }

    /// Short, and nothing that makes a path, an address or a link: a version, a model, a
    /// binary's name, a time.
    static func isPlain(_ text: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-+:,()"))
        return text.count <= 80 && text.unicodeScalars.allSatisfy(allowed.contains)
            && !text.lowercased().contains(".net") && !text.contains("..")
    }

    /// Keeps a report, cut down to the kept fields (`clean`), and drops the oldest past `limit`.
    /// Files are named by their time, so the names sort oldest first.
    func add(_ report: Data, at date: Date) {
        guard report.count <= Self.maxBytes, let json = Self.clean(report), json.count > 2 else { return }
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = folder
        try? dir.setResourceValues(values)
        var stamp = Int64((date.timeIntervalSince1970 * 1000).rounded())
        // Two reports of the same millisecond both stay.
        while files.fileExists(atPath: file(stamp).path) { stamp += 1 }
        try? json.write(to: file(stamp), options: .atomic)
        let kept = names()
        for name in kept.dropLast(Self.limit) { try? files.removeItem(at: folder.appendingPathComponent(name)) }
    }

    /// The reports kept, newest first.
    func all() -> [Report] {
        names().suffix(Self.limit).reversed().compactMap { name in
            guard let stamp = Int64(name.dropLast(Self.suffix.count)),
                  let json = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return Report(date: Date(timeIntervalSince1970: Double(stamp) / 1000), json: json)
        }
    }

    private static let suffix = ".json"

    private func file(_ stamp: Int64) -> URL {
        folder.appendingPathComponent(String(format: "%015lld", stamp) + Self.suffix)
    }

    /// The report files' names, oldest first.
    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(Self.suffix) && Int64($0.dropLast(Self.suffix.count)) != nil }
            .sorted()
    }
}

/// Takes the system's crash and hang reports as they come and keeps them (`DiagnosticReports`).
/// The system delivers them at most once a day, on a queue of its own, usually at the launch
/// after the crash. Nothing is asked of the system and nothing runs between deliveries: no
/// timer, no work per frame. The daily metric payloads are not taken.
///
/// Sendable: its one stored value is a `Sendable` struct that never changes.
final class DiagnosticReportsSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    private let reports: DiagnosticReports

    init(reports: DiagnosticReports) {
        self.reports = reports
    }

    /// Call once, at launch. The manager does not keep its subscribers alive: the app does.
    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { reports.add(p.jsonRepresentation(), at: p.timeStampEnd) }
    }
}
