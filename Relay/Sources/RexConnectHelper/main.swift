import AppKit

// Rex Connect Helper: a background app (LSUIElement) that runs the push relay.
//
// Launch arguments (also usable with `open -a "Rex Connect Helper" --args ...`):
//   --dry-run       log pushes instead of sending them (or set REX_CONNECT_DRY_RUN=1)
//   --verbose       log every status report
//   --check-apns    test the bundled APNs key against Apple, then quit
//   --unregister    remove the login item, then quit
//   --no-window     don't show the welcome window on this launch

struct Options {
    var dryRun = ProcessInfo.processInfo.environment["REX_CONNECT_DRY_RUN"].map { $0 != "" && $0 != "0" } ?? false
    var verbose = false
    var checkAPNs = false
    var unregister = false
    var noWindow = false

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        for a in args.dropFirst() {
            switch a {
            case "--dry-run": o.dryRun = true
            case "--verbose", "-v": o.verbose = true
            case "--check-apns": o.checkAPNs = true
            case "--unregister": o.unregister = true
            case "--no-window": o.noWindow = true
            default: break   // LaunchServices may add its own arguments
            }
        }
        return o
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: .parse(CommandLine.arguments))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
