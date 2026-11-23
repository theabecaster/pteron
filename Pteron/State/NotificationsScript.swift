#if DEBUG
import Foundation
import OSLog

/// `-notificationsScript <steps>` (debug builds): acts on the first computer's row as taps
/// would, for runs against a real server where nothing can tap. Steps are separated by commas
/// and run in order; after each one the row is written to the log (category
/// `notifications-script`):
///
/// - `ready`: wait until the row is on with its version line (at most 90 s)
/// - `off`, `on`: the computer's switch; `flips:<n>`: off and on again, n times
/// - `masterflips:<n>`: the Notifications switch off and on again, n times
/// - `test`: Send Test Notification; `remove`: Remove Beacon, confirmed; `install`: Reinstall
///   Beacon
/// - `fix:<seconds>`: the row's one button (Update, Repair, Retry, …), then that long a wait
/// - `sleep:<seconds>`
extension PushRegistrar {
    func run(script: String) async {
        let log = Logger(subsystem: "dev.abrahamgonzalez.rexduo", category: "notifications-script")
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func row() -> ComputerRow? { computers.first }
        func note(_ step: String) {
            guard let r = row() else { return log.notice("\(step, privacy: .public): no computer") }
            let line = r.status.line.map { "\($0.text)\($0.spinner ? " (working)" : "")" } ?? "-"
            log.notice("\(step, privacy: .public): \(r.name, privacy: .public) switch=\(r.status.switchOn ? "on" : "off", privacy: .public) line=\(line, privacy: .public) fix=\(String(describing: r.status.fix), privacy: .public)")
        }
        for step in script.split(separator: ",").map(String.init) {
            let parts = step.split(separator: ":").map(String.init)
            let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            switch parts.first {
            case "ready":
                for _ in 0..<180 {
                    if let s = row()?.status, s.switchOn, let line = s.line, line.text.hasPrefix("Version") { break }
                    await pause(0.5)
                }
            case "off":
                if let id = row()?.id { setComputer(id, on: false) }
                await pause(2)
            case "on":
                if let id = row()?.id { setComputer(id, on: true) }
                await pause(3)
            case "flips":
                for _ in 0..<count {
                    guard let id = row()?.id else { break }
                    setComputer(id, on: false)
                    await pause(0.15)
                    setComputer(id, on: true)
                    await pause(0.15)
                }
                await pause(4)
            case "masterflips":
                for _ in 0..<count {
                    setMaster(on: false)
                    await pause(0.15)
                    setMaster(on: true)
                    await pause(0.15)
                }
                await pause(5)
            case "test":
                if let id = row()?.id { sendTest(for: id) }
                await pause(3)
            case "remove":
                if let id = row()?.id { removeHelper(from: id) }
                await pause(25)
            case "install":
                if let id = row()?.id { reinstall(id) }
                await pause(30)
            case "fix":
                if let r = row(), let fix = r.status.fix {
                    // Trust goes through the screen's confirm; here it is confirmed for the key offered now.
                    if fix == .trust, let key = offeredKey(for: r.id) { trust(r.id, key: key) } else { self.fix(fix, for: r.id) }
                }
                await pause(Double(count))
            case "sleep":
                await pause(Double(count))
            default:
                log.notice("unknown step \(step, privacy: .public)")
            }
            note(step)
        }
        log.notice("script done")
    }
}
#endif
