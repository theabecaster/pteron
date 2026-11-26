import Foundation

/// The word for the device the app runs on, in text that means "this device": "iPhone" or "iPad".
/// Read once from the model identifier, so it needs no main actor and any thread can use it.
/// It is "iPhone" unless the device is an iPad, or a Mac running the iPad app, so a phone's
/// text stays exactly as written.
enum DeviceWord {
    static let current: String = word(forModel: modelIdentifier())

    /// "iPad" for an iPad identifier ("iPad16,3") and for a Mac ("Mac15,6", the iPad app on a
    /// Mac); "iPhone" for anything else.
    static func word(forModel model: String) -> String {
        model.hasPrefix("iPad") || model.hasPrefix("Mac") ? "iPad" : "iPhone"
    }

    /// The simulator reports the model it plays in an environment variable; a device reports it
    /// in `hw.machine`.
    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
