import XCTest
import RexKit
import GlanceModel
@testable import Pteron

/// The crash and hang reports the app keeps (`DiagnosticReports`) and the file Settings → About
/// shares (`ConnectionDiagnostics.report`): the newest 20, no name and no address of a computer,
/// and a file that exists only between the tap and the share sheet's close.
@MainActor
final class DiagnosticReportsTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A report as it is stored: kept fields only, keys in order.
    private func json(_ n: Int) -> Data {
        Data(#"{"crashDiagnostics":[{"diagnosticMetaData":{"exceptionCode":\#(n)}}]}"#.utf8)
    }

    private func date(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(n)) }

    func testTheNewestTwentyAreKeptNewestFirst() {
        let reports = DiagnosticReports(folder: folder.appendingPathComponent("Reports"))
        XCTAssertEqual(reports.all(), [], "no folder yet: nothing, and no error")
        XCTAssertEqual(DiagnosticReports.limit, 20)
        // Not handed over in order of time.
        for n in [3, 1, 2] + Array(4...25) { reports.add(json(n), at: date(n)) }
        let kept = reports.all()
        XCTAssertEqual(kept.count, 20)
        XCTAssertEqual(kept.first, DiagnosticReports.Report(date: date(25), json: json(25)))
        XCTAssertEqual(kept.last, DiagnosticReports.Report(date: date(6), json: json(6)))
        let files = try? FileManager.default.contentsOfDirectory(atPath: reports.folder.path)
        XCTAssertEqual(files?.count, 20, "the older ones are deleted, not only hidden")
    }

    func testTwoReportsOfTheSameMomentBothStayAndAnEmptyOrHugeOneIsNotKept() {
        let reports = DiagnosticReports(folder: folder.appendingPathComponent("Reports"))
        reports.add(json(1), at: date(1))
        reports.add(json(2), at: date(1))
        reports.add(Data(), at: date(2))
        reports.add(Data(count: DiagnosticReports.maxBytes + 1), at: date(3))
        XCTAssertEqual(Set(reports.all().map(\.json)), [json(1), json(2)])
    }

    func testTheReportsAreLeftOutOfBackupsAndSitBesideTheConnectionLog() throws {
        let reports = DiagnosticReports(folder: folder.appendingPathComponent("Reports"))
        reports.add(json(1), at: date(1))
        let values = try reports.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertTrue(DiagnosticReports.standard.folder.path.hasSuffix("Application Support/Diagnostics/Reports"))
    }

    /// What is in the reports folder that is not a report is neither read nor deleted.
    func testAStrangeFileInTheFolderIsLeftAlone() throws {
        let reports = DiagnosticReports(folder: folder.appendingPathComponent("Reports"))
        reports.add(json(1), at: date(1))
        let other = reports.folder.appendingPathComponent("notes.json")
        try Data("x".utf8).write(to: other)
        for n in 2...30 { reports.add(json(n), at: date(n)) }
        XCTAssertEqual(reports.all().count, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: What a report may hold

    /// A payload as the system could hand it over, with text in it that names a user, a
    /// computer, a path under a home folder and a network. None of that is stored or shared.
    func testOnlyTheKeptFieldsOfAReportAreStoredAndNoNamePathOrNetworkReachesTheSharedFile() async throws {
        let payload = #"""
        {"timeStampBegin":"2026-11-20 10:00:00 +0000","timeStampEnd":"2026-11-21 10:00:00 +0000","userName":"Jordan",
         "crashDiagnostics":[{"version":"1.0.0",
           "diagnosticMetaData":{"appBuildVersion":"2611201913","appVersion":"1.2","osVersion":"iPhone OS 27.1 (25B50)",
             "deviceType":"iPhone19,1","platformArchitecture":"arm64e","bundleIdentifier":"dev.example.app","regionFormat":"US",
             "exceptionType":1,"exceptionCode":0,"signal":11,"pid":4242,
             "terminationReason":"Namespace SIGNAL, Code 11 at /Users/jordan/Library/x",
             "virtualMemoryRegionInfo":"0 is not in any region. kitchen-rex.tail1234.ts.net",
             "objectiveCexceptionReason":{"composedMessage":"bad URL https://kitchen-rex.tail1234.ts.net/api for Kitchen Mac",
               "formatString":"bad URL %@","arguments":["https://kitchen-rex.tail1234.ts.net/api"]}},
           "callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
             {"binaryUUID":"70B89F27-1634-3580-A695-57CDB41D7743","offsetIntoBinaryTextSegment":123,"sampleCount":20,
              "binaryName":"/Users/jordan/Library/Developer/Pteron.debug.dylib","address":7170766264,
              "subFrames":[{"binaryName":"libswiftCore.dylib","offsetIntoBinaryTextSegment":7,"note":"wifi HomeNet-5G"},
                           {"binaryName":"kitchen-rex.tail1234.ts.net","offsetIntoBinaryTextSegment":8}]}]}]}}],
         "hangDiagnostics":[{"diagnosticMetaData":{"hangDuration":"20 sec","deviceType":"~jordan/phone"}}]}
        """#
        let reports = DiagnosticReports(folder: folder.appendingPathComponent("Reports"))
        reports.add(Data(payload.utf8), at: date(1))
        let kept = try XCTUnwrap(reports.all().first)
        let stored = String(decoding: kept.json, as: UTF8.self)
        let text = await ConnectionDiagnostics.report(log: nil, servers: [], reports: reports.all(), version: "1.2 (34)")
        for out in [stored, text] {
            for secret in ["jordan", "Jordan", "Users", "Library", "Kitchen", "kitchen", "tail1234", "ts.net", "https", "HomeNet",
                           "userName", "terminationReason", "virtualMemoryRegionInfo", "objectiveCexceptionReason", "composedMessage",
                           "arguments", "bundleIdentifier", "regionFormat", "pid", "note", "/", "~", "%@"] {
                XCTAssertFalse(out.contains(secret), "“\(secret)” reached the report")
            }
            // What is evidence stays.
            for fact in ["Pteron.debug.dylib", "libswiftCore.dylib", "70B89F27-1634-3580-A695-57CDB41D7743", "\"offsetIntoBinaryTextSegment\":123",
                         "\"exceptionType\":1", "\"signal\":11", "iPhone19,1", "iPhone OS 27.1 (25B50)", "2611201913", "arm64e", "20 sec",
                         "2026-11-21 10:00:00 +0000"] {
                XCTAssertTrue(out.contains(fact), "“\(fact)” is missing")
            }
        }
        // Every key in the stored report is on the list.
        func keys(_ value: Any) -> Set<String> {
            if let d = value as? [String: Any] { return d.reduce(into: Set(d.keys)) { $0.formUnion(keys($1.value)) } }
            if let a = value as? [Any] { return a.reduce(into: Set<String>()) { $0.formUnion(keys($1)) } }
            return []
        }
        XCTAssertTrue(keys(try JSONSerialization.jsonObject(with: kept.json)).isSubset(of: DiagnosticReports.kept))
    }

    func testWhatIsNotAReportIsNotKept() {
        let reports = DiagnosticReports(folder: folder.appendingPathComponent("Reports"))
        reports.add(Data("not json".utf8), at: date(1))
        reports.add(Data(#"["a"]"#.utf8), at: date(2))
        reports.add(Data(#"{"userName":"Jordan"}"#.utf8), at: date(3))
        XCTAssertEqual(reports.all(), [], "nothing of it is on the list: nothing to keep")
        XCTAssertTrue(DiagnosticReports.isPlain("iPhone OS 27.1 (25B50)"))
        for bad in ["a/b", "~x", "user@host", "desk.tail1.ts.net", "..", String(repeating: "a", count: 81), "a\\b", "a%b"] {
            XCTAssertFalse(DiagnosticReports.isPlain(bad), bad)
        }
    }

    // MARK: The file the user shares

    func testTheSharedTextHasTheLogAndTheReportsAndNoNameOrAddressOfAComputer() async throws {
        let log = ConnectionLog(file: folder.appendingPathComponent("Diagnostics/connections.clog"))
        log.record(.launch(build: 2611201913))
        let config = ServerConfig(name: "Kitchen Mac", url: "https://kitchen-rex.tail1234.ts.net")
        let reporter = ConnectionReporter(log: log, server: ConnectionDiagnostics.key(config)) { 1 }
        reporter.retryScheduled(after: 1)
        let reports = [DiagnosticReports.Report(date: date(2), json: json(2)),
                       DiagnosticReports.Report(date: date(1), json: json(1))]
        let text = await ConnectionDiagnostics.report(log: log, servers: [config], reports: reports, version: "1.2 (34)")
        XCTAssertTrue(text.hasPrefix("\(Brand.appName) diagnostics\nversion 1.2 (34)\n"), text)
        XCTAssertTrue(text.contains("Connection log"), text)
        XCTAssertTrue(text.contains("App         launch build=2611201913"), text)
        XCTAssertTrue(text.contains("Computer 1  retry in=1000ms"), text)
        XCTAssertTrue(text.contains("Crash and hang reports\nreports 2\n"), text)
        let first = try XCTUnwrap(text.range(of: #""exceptionCode":2}"#)), second = try XCTUnwrap(text.range(of: #""exceptionCode":1}"#))
        XCTAssertTrue(first.lowerBound < second.lowerBound, "newest first")
        for secret in ["Kitchen", "kitchen-rex", "tail1234", "ts.net", "https://", config.id.uuidString] {
            XCTAssertFalse(text.contains(secret), "“\(secret)” is in the shared text")
        }
    }

    func testWithNoLogAndNoReportsTheFileSaysSo() async {
        let text = await ConnectionDiagnostics.report(log: nil, servers: [], reports: [], version: "1.2 (34)")
        XCTAssertTrue(text.contains("Connection log\nnone\n"), text)
        XCTAssertTrue(text.contains("reports 0\n"), text)
    }

    func testTheSharedFileIsOneTextFileThatGoesWhenTheSheetCloses() throws {
        let share = folder.appendingPathComponent("Share")
        let first = try ConnectionDiagnostics.writeShareFile("one", in: share)
        XCTAssertEqual(first.lastPathComponent, "\(Brand.appName) Diagnostics.txt")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
        // A second tap after a sheet that never told of its close: one file, the new one.
        let second = try ConnectionDiagnostics.writeShareFile("two", in: share)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: share.path), ["\(Brand.appName) Diagnostics.txt"])
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
        ConnectionDiagnostics.clearShareFile(in: share)
        XCTAssertFalse(FileManager.default.fileExists(atPath: share.path))
        ConnectionDiagnostics.clearShareFile(in: share)  // nothing there: no error
        XCTAssertTrue(ConnectionDiagnostics.shareFolder.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      "never in a place that is backed up or kept")
    }

    /// The row's words (the glossary: "computer", "this iPhone", sentence case).
    func testTheRowsFooterSaysWhatIsSharedAndThatNothingLeavesByItself() {
        let footer = AboutPage.diagnosticsFooter
        XCTAssertTrue(footer.contains("no computer names or addresses"))
        XCTAssertTrue(footer.contains("stays on this iPhone unless you share it"))
        XCTAssertFalse(footer.lowercased().contains("server"))
    }
}
