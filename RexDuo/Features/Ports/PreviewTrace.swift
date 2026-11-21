import os

/// The steps of a page's open as signpost intervals, for Instruments and
/// `log stream --signpost` (subsystem `dev.abrahamgonzalez.rexduo`, category `PreviewBrowser`):
/// `present`, `viewDidLoad`, `buildChrome`, `transition` (the sheet's rise, from will-appear to
/// did-appear), `makeWebView` and `attach`, and the event `firstLayout`. Debug and benchmark
/// builds only: in a shipped build every call here is empty.
enum PreviewTrace {
    #if DEBUG || BENCH
    private static let poster = OSSignposter(subsystem: "dev.abrahamgonzalez.rexduo", category: "PreviewBrowser")

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    static func begin(_ name: StaticString) -> Interval? {
        Interval(name: name, state: poster.beginInterval(name))
    }

    static func end(_ interval: Interval?) {
        if let interval { poster.endInterval(interval.name, interval.state) }
    }

    static func event(_ name: StaticString) {
        poster.emitEvent(name)
    }
    #else
    struct Interval {}

    @inline(__always) static func begin(_ name: StaticString) -> Interval? { nil }
    @inline(__always) static func end(_ interval: Interval?) {}
    @inline(__always) static func event(_ name: StaticString) {}
    #endif

    @inline(__always) static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try body()
    }
}
