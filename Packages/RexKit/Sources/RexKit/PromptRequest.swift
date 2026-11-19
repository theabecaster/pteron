import Foundation

/// `client_prompt_requested`: an action from the configuration file asks the person a question
/// (`rex.ui`). Every app that can show it gets its own `call_id`; the first answer wins.
public struct PromptRequest: @unchecked Sendable {
    // `@unchecked`: `prompt` is an immutable JSON value (see `DecodedJSON`).
    public var callID: String
    /// The action that asks, when the server knows it.
    public var action: String?
    /// The question as sent: `kind`, `title`, `items` and the rest.
    public var prompt: JSONObject
    /// `input` or `pick`; anything else can't be shown.
    public var kind: String
    public var timeoutMS: Int
    public var receivedAt: Date
    /// The connection the prompt came on. Its `call_id` means nothing on a later one.
    public var connectionSerial: Int

    public static let knownKinds: Set<String> = ["input", "pick"]
    public var isKnownKind: Bool { Self.knownKinds.contains(kind) }

    /// Nil without a `call_id`: there is nothing to answer.
    public init?(_ p: JSONObject, receivedAt: Date = Date(), connectionSerial: Int = 0) {
        guard let id = p.str("call_id"), !id.isEmpty else { return nil }
        callID = id
        action = p.str("action")
        prompt = p.obj("prompt") ?? [:]
        kind = prompt.str("kind") ?? ""
        timeoutMS = p.int("timeout_ms") ?? 0
        self.receivedAt = receivedAt
        self.connectionSerial = connectionSerial
    }

    /// The `client.reply` payload that takes only this app out of the prompt.
    public static func decline(callID: String) -> JSONObject {
        ["call_id": callID,
         "error": ["code": "not_supported", "message": "This app can't show the prompt."] as JSONObject]
    }
}
