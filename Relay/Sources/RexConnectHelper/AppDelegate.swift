import AppKit
import RelayCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    private var relay: Relay?
    private var welcome: WelcomeWindowController?
    private let defaults = UserDefaults.standard

    init(options: Options) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read this first: it describes the event that launched the app.
        let launchedAtLogin = Self.launchedAsLoginItem()
        Log.verbose = options.verbose

        if options.unregister {
            Task {
                do {
                    try await SMAppService.mainApp.unregister()
                    Log.info("login item removed")
                } catch {
                    Log.info("could not remove the login item: \(error.localizedDescription)")
                }
                exit(0)
            }
            return
        }
        if options.checkAPNs {
            Task {
                guard let token = Self.bundledToken() else { exit(1) }
                exit(await APNsCheck.run(token: token, topic: Self.topic) ? 0 : 1)
            }
            return
        }

        NSApp.mainMenu = Self.mainMenu()
        startRelay()

        // First open: start at login from now on. Later opens respect the user's choice.
        let firstRun = !defaults.bool(forKey: "didFirstRun")
        if firstRun {
            defaults.set(true, forKey: "didFirstRun")
            LoginItem.set(true)
        }
        // A login launch stays silent; opening it yourself shows the window.
        if !options.noWindow && (firstRun || !launchedAtLogin) { showWelcome() }
    }

    /// Opening the app again while it runs shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWelcome()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Close the Rex connection with a close frame first, so Rex drops this client at once
    /// instead of listing it as `lost` for a minute.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let relay else { return .terminateNow }
        relay.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // MARK: Relay

    private func startRelay() {
        let stateDir = RelayConfig.defaultStateDir
        // Optional overrides; the normal install has no config file.
        let config = (try? RelayConfig.load(stateDir.appendingPathComponent("config.json"))) ?? RelayConfig()
        let sender: PushSender?
        if options.dryRun {
            sender = DryRunSender(topic: config.apns?.topic ?? Self.topic)
        } else {
            sender = Self.bundledToken().map { APNsSender(token: $0, topic: config.apns?.topic ?? Self.topic) }
        }
        let store = DeviceStore(url: stateDir.appendingPathComponent("devices.json"))
        let relay = Relay(config: config, store: store, sender: sender, dryRun: options.dryRun)
        relay.onWatchingChanged = { [weak self] watching in self?.welcome?.setConnected(watching) }
        relay.start()
        self.relay = relay
    }

    static var topic: String {
        Bundle.main.object(forInfoDictionaryKey: "RexConnectAPNsTopic") as? String ?? RelayConfig.defaultTopic
    }

    /// The APNs key that package.sh copied into the bundle at build time.
    static func bundledToken() -> APNsToken? {
        guard let url = Bundle.main.url(forResource: "AuthKey", withExtension: "p8"),
              let keyID = Bundle.main.object(forInfoDictionaryKey: "RexConnectAPNsKeyID") as? String,
              let teamID = Bundle.main.object(forInfoDictionaryKey: "RexConnectAPNsTeamID") as? String else {
            Log.info("no APNs key in the app bundle; pushes are disabled")
            return nil
        }
        do {
            return try APNsToken(p8Path: url.path, keyID: keyID, teamID: teamID)
        } catch {
            Log.info("could not load the bundled APNs key: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Window

    private func showWelcome() {
        if welcome == nil {
            let w = WelcomeWindowController(dryRun: options.dryRun)
            w.onClose = { [weak self] in self?.welcome = nil }
            welcome = w
        }
        welcome?.setConnected(relay?.isWatching ?? false)
        welcome?.present()
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Hidden for an agent app, but gives the window ⌘W and ⌘Q.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Rex Connect Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }
}

/// "Open at login", via SMAppService. No LaunchAgent plist: macOS keeps the registration and
/// lists the app under System Settings > General > Login Items.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            Log.info("open at login: \(on ? "on" : "off") (status \(SMAppService.mainApp.status.rawValue))")
        } catch {
            Log.info("could not turn open at login \(on ? "on" : "off"): \(error.localizedDescription)")
        }
    }
}
