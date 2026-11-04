public enum HostedRequestError: Error, Equatable {
    /// A notes tag without its style prompt or additions flag.
    case incompleteTag
}

/// Rebuilds a request from a tag and the user's messages, with the same per-step templates the builders use.
public enum HostedRequest {
    public static func make(tag: RequestTag, messages: [Message], model: String) throws -> MessageRequest {
        var request: MessageRequest
        switch tag.step {
        case .notes:
            guard let style = tag.stylePrompt, let additions = tag.allowAdditions else {
                throw HostedRequestError.incompleteTag
            }
            request = try NotesPrompt.template(stylePrompt: style, allowAdditions: additions,
                                               languageOverride: tag.languageOverride, model: model, messages: messages)
        case .verify:
            request = try Verifier.template(model: model, messages: messages)
        case .flashcards:
            request = try Flashcards.template(model: model, messages: messages)
        case .studyGuide:
            request = try StudyGuide.template(model: model, messages: messages)
        }
        request.tag = tag
        return request
    }
}
