#if DEBUG
import SwiftUI
import UIKit

/// `-sidebarFoldBench <cycles>` (testing): once the sidebar has loaded, folds every machine and
/// session, then opens them again, `cycles` times, the way a tap does (animated). A display link
/// counts frames that came late, and the result is logged as one `SIDEBAR_FOLD_BENCH` line.
/// The fold state the user had is put back afterwards.
struct SidebarFoldBench: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs

    static var cycles: Int { UserDefaults.standard.integer(forKey: "sidebarFoldBench") }

    func body(content: Content) -> some View {
        content.task {
            guard Self.cycles > 0 else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await run(cycles: Self.cycles)
        }
    }

    private func run(cycles: Int) async {
        let saved = prefs.sidebarCollapsed
        let all = Set(model.servers.flatMap { s in
            [SidebarCollapse.machine(s.id)] + s.sessions.map { SidebarCollapse.session(s.id, $0.id) }
        })
        let sessionsOnly = all.filter { $0.hasPrefix("s:") }
        // `-sidebarFoldBenchScope session`: fold only the session with the most tabs, as one tap does.
        let biggest = model.servers.flatMap { s in
            s.sessions.map { (key: SidebarCollapse.session(s.id, $0.id), tabs: s.views[$0.id]?.windows.count ?? 0) }
        }.max { $0.tabs < $1.tabs }
        let one = UserDefaults.standard.string(forKey: "sidebarFoldBenchScope") == "session"
        let rows = model.servers.reduce(0) { n, s in
            n + 1 + s.sessions.reduce(0) { $0 + 1 + (s.views[$1.id]?.windows.count ?? 0) }
        }
        prefs.sidebarCollapsed = []
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let clock = FrameClock()
        clock.start()
        let from = CACurrentMediaTime()
        for i in 0..<cycles {
            // Alternate: every session (tabs go), then every machine (sessions go too).
            let fold = one ? Set(biggest.map { [$0.key] } ?? []) : i.isMultiple(of: 2) ? sessionsOnly : all
            withAnimation(.snappy(duration: 0.25)) { prefs.sidebarCollapsed = fold }
            try? await Task.sleep(nanoseconds: 600_000_000)
            withAnimation(.snappy(duration: 0.25)) { prefs.sidebarCollapsed = [] }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        let to = CACurrentMediaTime()
        clock.stop()
        let stats = PerfHitchStats.measure(clock.times, in: PerfWindow(from: from, to: to), period: clock.period)
        NSLog("SIDEBAR_FOLD_BENCH scope=%@ rows=%d cycles=%d frames=%d period_ms=%.2f hitches=%d hitch_ms=%.1f worst_ms=%.1f",
              one ? "session" : "all", rows, cycles, stats.events, clock.period * 1000, stats.hitches, stats.hitchSeconds * 1000,
              stats.worstSeconds * 1000)
        prefs.sidebarCollapsed = saved
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
