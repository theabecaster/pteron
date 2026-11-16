import Foundation
import RelayCore

// Command-line build of the relay, for development. Friends use Rex Connect Helper.app instead.

let usage = """
usage: rex-push-relay [options]

Watches Rex and sends Rex Connect push notifications when an agent is blocked or
finishes, or a terminal raises a desktop notification. Finds the local Rex server
by itself unless --server is given.

  --dry-run          print the pushes instead of sending them
  --server ADDR      Rex server to watch: unix:///path/server.sock or https://host
                     (repeatable; overrides config.json)
  --state-dir DIR    where config.json and devices.json live
                     (default ~/Library/Application Support/Rex Connect Helper)
  --config FILE      config file (default <state-dir>/config.json)
  --check-apns       send one push to a fake token in each APNs environment and
                     report Apple's answer (BadDeviceToken means the key works)
  --verbose          log every status report
  --version, --help
"""

setvbuf(stdout, nil, _IOLBF, 0)

var dryRun = false
var checkAPNs = false
var servers: [String] = []
var stateDir = RelayConfig.defaultStateDir
var configPath: URL?
var args = CommandLine.arguments.dropFirst()
func value(_ flag: String) -> String {
    guard let v = args.popFirst() else { FileHandle.standardError.write(Data("\(flag) needs a value\n".utf8)); exit(2) }
    return v
}
while let a = args.popFirst() {
    switch a {
    case "--dry-run": dryRun = true
    case "--check-apns": checkAPNs = true
    case "--verbose", "-v": Log.verbose = true
    case "--server": servers.append(value(a))
    case "--state-dir": stateDir = URL(fileURLWithPath: (value(a) as NSString).expandingTildeInPath, isDirectory: true)
    case "--config": configPath = URL(fileURLWithPath: (value(a) as NSString).expandingTildeInPath)
    case "--version": print(Relay.version); exit(0)
    case "--help", "-h": print(usage); exit(0)
    default:
        FileHandle.standardError.write(Data("unknown option \(a)\n\n\(usage)\n".utf8))
        exit(2)
    }
}

let configURL = configPath ?? stateDir.appendingPathComponent("config.json")
var config: RelayConfig
do {
    config = try RelayConfig.load(configURL)
} catch {
    Log.info("could not read \(configURL.path): \(error)")
    exit(1)
}
if !servers.isEmpty { config.servers = servers }

/// The APNs token signer, or nil (with one log line) when no usable key is configured.
@MainActor func loadToken() -> APNsToken? {
    guard let path = config.apns?.keyPath, let keyID = config.apns?.keyID else { return nil }
    do {
        return try APNsToken(p8Path: path, keyID: keyID, teamID: config.teamID)
    } catch {
        Log.info("could not load APNs key \(path): \(error.localizedDescription)")
        return nil
    }
}

Task { @MainActor in
    if checkAPNs {
        guard let token = loadToken() else {
            Log.info("no APNs key configured in \(configURL.path)")
            exit(1)
        }
        exit(await APNsCheck.run(token: token, topic: config.topic) ? 0 : 1)
    }
    let sender: PushSender? = dryRun
        ? DryRunSender(topic: config.topic)
        : loadToken().map { APNsSender(token: $0, topic: config.topic) }
    let store = DeviceStore(url: stateDir.appendingPathComponent("devices.json"))
    let relay = Relay(config: config, store: store, sender: sender, dryRun: dryRun)
    relay.start()
    RelayHolder.relay = relay   // lives for the life of the process
}

enum RelayHolder { @MainActor static var relay: Relay? }

// On SIGINT/SIGTERM, close the Rex connections with a close frame so the server drops this
// client at once instead of keeping it as "lost" for 60 s (which would make two relays show up).
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        Task { @MainActor in
            RelayHolder.relay?.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(0)
        }
    }
    src.resume()
    signalSources.append(src)
}
dispatchMain()
