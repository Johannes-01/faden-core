/// Which step made a request and the inputs, besides the messages, that its system prompt depends on.
/// The hosted mode sends the tag instead of the prompt; `HostedRequest.make` rebuilds the request from it.
/// Never encoded into a request body.
public struct RequestTag: Sendable, Equatable {
    public var step: CostRecord.Step
    /// Notes only: the style's prompt.
    public var stylePrompt: String?
    /// Notes only: whether the model may add explanations of its own.
    public var allowAdditions: Bool?
    /// Notes only: a language code such as `de`; nil means the lecture's own language.
    public var languageOverride: String?
    /// The backend's reservation for this call, once it holds one.
    public var reservationID: String?

    public init(step: CostRecord.Step, stylePrompt: String? = nil, allowAdditions: Bool? = nil,
                languageOverride: String? = nil, reservationID: String? = nil) {
        self.step = step
        self.stylePrompt = stylePrompt
        self.allowAdditions = allowAdditions
        self.languageOverride = languageOverride
        self.reservationID = reservationID
    }
}
