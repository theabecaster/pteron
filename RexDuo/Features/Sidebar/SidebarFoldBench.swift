#if DEBUG
import SwiftUI
import UIKit

/// `-sidebarFoldBench <cycles>` (testing): once the sidebar has loaded, folds every machine and
/// session, then opens them again, `cycles` times, animated as a tap does.
/// `-sidebarFoldBenchScope session` folds only the session with the most tabs; `-sidebarFoldBenchAnimate
/// never` switches at once, for comparison. A display link counts frames that came late, and the
/// result is logged as one `SIDEBAR_FOLD_BENCH` line.
///
/// The user's fold state is kept aside in `sidebarFoldBenchSaved` while the run lasts and put back
/// afterwards, also on the next launch when a run was cut short.
struct SidebarFoldBench: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs

    static var cycles: Int { UserDefaults.standard.integer(forKey: "sidebarFoldBench") }
    private static let savedKey = "sidebarFoldBenchSaved"

    func body(content: Content) -> some View {
        content.task {
            if let saved = UserDefaults.standard.stringArray(forKey: Self.savedKey) {
                prefs.sidebarCollapsed = Set(saved)
                UserDefaults.standard.removeObject(forKey: Self.savedKey)
            }
            guard Self.cycles > 0 else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await run(cycles: Self.cycles)
        }
    }

    private func run(cycles: Int) async {
        let saved = prefs.sidebarCollapsed
        UserDefaults.standard.set(saved.sorted(), forKey: Self.savedKey)
        let machines = model.servers.map { s in
            SidebarOutline.Machine(id: s.id, sessions: s.sessions.map { e in
                SidebarOutline.Session(id: e.id, windowIDs: s.views[e.id]?.windows.map(\.id) ?? [])
            })
        }
        let all = Set(machines.flatMap { m in [SidebarCollapse.machine(m.id)] + m.sessions.map { SidebarCollapse.session(m.id, $0.id) } })
        let sessionsOnly = all.filter { $0.hasPrefix("s:") }
        let biggest = machines.flatMap { m in m.sessions.map { (key: SidebarCollapse.session(m.id, $0.id), tabs: $0.windowIDs.count) } }
            .max { $0.tabs < $1.tabs }
        let one = UserDefaults.standard.string(forKey: "sidebarFoldBenchScope") == "session"
        let never = UserDefaults.standard.string(forKey: "sidebarFoldBenchAnimate") == "never"
        let open = SidebarOutline.rows(machines, collapsed: []).count
        prefs.sidebarCollapsed = []
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let clock = FrameClock()
        clock.start()
        let from = CACurrentMediaTime()
        for i in 0..<cycles {
            // Alternate: every session (tabs go), then every machine (sessions go too).
            let fold = one ? Set(biggest.map { [$0.key] } ?? []) : i.isMultiple(of: 2) ? sessionsOnly : all
            let a: Animation? = never ? nil : SidebarCollapse.animation
            withAnimation(a) { prefs.sidebarCollapsed = fold }
            try? await Task.sleep(nanoseconds: 600_000_000)
            withAnimation(a) { prefs.sidebarCollapsed = [] }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        let to = CACurrentMediaTime()
        clock.stop()
        let stats = PerfHitchStats.measure(clock.times, in: PerfWindow(from: from, to: to), period: clock.period)
        NSLog("SIDEBAR_FOLD_BENCH scope=%@ animate=%@ rows=%d cycles=%d frames=%d period_ms=%.2f hitches=%d hitch_ms=%.1f worst_ms=%.1f",
              one ? "session" : "all", never ? "never" : "always", open, cycles, stats.events, clock.period * 1000,
              stats.hitches, stats.hitchSeconds * 1000, stats.worstSeconds * 1000)
        prefs.sidebarCollapsed = saved
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
    }
}

/// Main-thread frame timestamps from a display link.
@MainActor
private final class FrameClock: NSObject {
    private(set) var times: [Double] = []
    private(set) var period: Double = 1.0 / 60
    private var link: CADisplayLink?

    func start() {
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        times.append(l.timestamp)
        period = l.targetTimestamp - l.timestamp
    }
}
#endif
