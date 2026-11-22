import Foundation

/// Settings passed to `FigoChat.initialize`.
public struct FigoChatConfig: CustomStringConvertible {
    /// API key from the FigoChat admin (API Keys in the sidebar at app.figolabs.ai). Sent as `Authorization: Bearer <apiKey>`.
    public let apiKey: String
    /// Assistant the user chats with.
    public let assistantId: String
    /// The customer's name; "" when unknown (the chat then asks for it, see `askForDetails`). Updated by
    /// `FigoChat.setCustomerDetails` and the details form.
    public internal(set) var fullName: String
    /// The customer's email address; "" when unknown.
    public internal(set) var emailAddress: String
    /// Phone number in international format, e.g. +2348012345678; "" when unknown.
    public internal(set) var mobilePhone: String
    /// Brand color as hex: #RGB, #RRGGBB or #RRGGBBAA.
    public let primaryColor: String
    public let baseURL: URL
    /// Sent on the customer's behalf as soon as `initialize` runs, for example the question they typed on your own
    /// screen before opening the chat. It is sent like any other message: the reply and the thread id are kept, so
    /// the chat continues from it and shows both when it opens.
    public let firstCustomerMessage: String?
    /// Resumes an earlier conversation; use the value from `FigoChat.threadId`.
    public let threadId: String?
    public let maxFiles: Int
    public let maxFileSizeMB: Int
    /// true sends a transcribed voice note right away; false puts the text in the input for editing.
    public let autoSendVoice: Bool
    public let timeout: TimeInterval
    /// true (the default) shows a details form (name, email, phone) before the chat when none of the three were
    /// passed and the visitor hasn't given them before.
    public let askForDetails: Bool
    /// Country preselected in the details form's phone field, as an ISO code such as NG or GB (trimmed, any case);
    /// nil or an unknown code preselects Nigeria (NG).
    public let defaultCountry: String?

    public var description: String { "FigoChatConfig(assistantId: \(assistantId), baseURL: \(baseURL), apiKey: ***)" }

    public static let defaultBaseURL = URL(string: "https://api.figolabs.ai")!
}

/// The customer's name, email and phone, as sent with every message. Empty strings when unknown.
public struct FigoCustomerDetails: Codable, Equatable, Sendable {
    public var fullName: String
    public var emailAddress: String
    /// International format, e.g. +2348012345678.
    public var mobilePhone: String

    public init(fullName: String = "", emailAddress: String = "", mobilePhone: String = "") {
        self.fullName = fullName
        self.emailAddress = emailAddress
        self.mobilePhone = mobilePhone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? ""
        emailAddress = try c.decodeIfPresent(String.self, forKey: .emailAddress) ?? ""
        mobilePhone = try c.decodeIfPresent(String.self, forKey: .mobilePhone) ?? ""
    }

    var isEmpty: Bool { fullName.isEmpty && emailAddress.isEmpty && mobilePhone.isEmpty }
}

/// Display details of the assistant, from `GET /api/v1/sdk/assistant/{assistantId}`. The chat header shows
/// `persona` (or `assistantName`), the first bubble shows `introMessage`, and `waitingMessage` is shown on the left
/// while a reply is being prepared. `disclaimerMessage` is shown above the footer, and when the company has both
/// terms and a privacy policy the details form asks the visitor to agree to them. Any field may be nil.
public struct FigoAssistantInfo: Equatable {
    public let assistantName: String?
    public let persona: String?
    public let waitingMessage: String?
    /// HTML, rendered like an assistant reply.
    public let introMessage: String?
    /// Short notice such as "AI can make mistakes. Double-check sensitive information", shown in small grey text
    /// above the "Powered by Figo AI Labs" footer.
    public let disclaimerMessage: String?
    /// The company's legal links; nil when the API didn't return them.
    public let company: FigoCompanyInfo?

    public init(
        assistantName: String? = nil,
        persona: String? = nil,
        waitingMessage: String? = nil,
        introMessage: String? = nil,
        disclaimerMessage: String? = nil,
        company: FigoCompanyInfo? = nil
    ) {
        self.assistantName = assistantName
        self.persona = persona
        self.waitingMessage = waitingMessage
        self.introMessage = introMessage
        self.disclaimerMessage = disclaimerMessage
        self.company = company
    }

    /// The disclaimer trimmed, or nil when there is none to show.
    var disclaimer: String? {
        disclaimerMessage.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The terms and privacy policy the details form asks the visitor to agree to: only when both are set.
    var consentLinks: FigoConsentLinks? {
        let trim: (String?) -> String? = { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        guard let terms = trim(company?.termsAndCondition), let privacy = trim(company?.privacyPolicy) else { return nil }
        return FigoConsentLinks(terms: terms, privacy: privacy)
    }
}

/// The assistant's company, as returned with the assistant details.
public struct FigoCompanyInfo: Equatable {
    /// Terms and conditions, usually a URL.
    public let termsAndCondition: String?
    /// Privacy policy, usually a URL.
    public let privacyPolicy: String?

    public init(termsAndCondition: String? = nil, privacyPolicy: String? = nil) {
        self.termsAndCondition = termsAndCondition
        self.privacyPolicy = privacyPolicy
    }
}

/// Terms and privacy policy (trimmed, non-empty) the visitor must agree to before starting the chat.
struct FigoConsentLinks: Equatable {
    let terms: String
    let privacy: String

    var termsURL: URL? { Self.webURL(terms) }
    var privacyURL: URL? { Self.webURL(privacy) }

    /// The value as a URL when it is an http(s) link; nil otherwise, so it is shown as plain text.
    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// Error thrown by every SDK call. `code` is the API response code or the HTTP status.
public struct FigoChatError: LocalizedError, Equatable {
    public let message: String
    public let code: String

    public init(_ message: String, code: String) {
        self.message = message
        self.code = code
    }

    public var errorDescription: String? { message }
}

public enum FigoMessageRole: Equatable { case user, assistant, system }

public enum FigoMessageStatus: Equatable { case sending, sent, error }

/// An attachment on a chat message.
public struct FigoAttachment: Equatable, Identifiable {
    public var id: String { url }
    /// CDN url returned by the upload.
    public let url: String
    public let name: String
    public let mimeType: String?
    /// Local bytes, used for image previews.
    public let data: Data?

    public var isImage: Bool {
        if mimeType?.hasPrefix("image/") == true { return true }
        let pattern = #"\.(png|jpe?g|gif|webp|bmp|heic|heif)(\?|$)"#
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            || url.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public struct FigoChatMessage: Equatable, Identifiable {
    public let id: String
    public let role: FigoMessageRole
    /// What the user typed for `.user` messages; the raw reply (HTML) for `.assistant` messages, rendered with
    /// `htmlToRuns(_:)`. Use `htmlToText(_:)` for its plain text.
    public let text: String
    public var attachments: [FigoAttachment] = []
    public var createdAt = Date()
    public var status: FigoMessageStatus = .sent
}

public struct FigoChatReply: Equatable {
    public let answer: String
    public let threadId: String?
    /// "ai" normally, "liveagent" once a human agent has taken over.
    public let threadMode: String?
}

/// A file to upload: its name (with extension) and contents.
public struct FigoUploadFile {
    public let name: String
    public let data: Data
    public let mimeType: String?

    public init(name: String, data: Data, mimeType: String? = nil) {
        self.name = name
        self.data = data
        self.mimeType = mimeType
    }

    var fileExtension: String {
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        let sub = mimeType?.split(separator: "/").last.map { String($0).lowercased() }
        return sub == "jpeg" ? "jpg" : (sub ?? "txt")
    }
}

/// Public realtime settings from `GET /api/v1/realtime/config`.
public struct FigoRealtimeConfig: CustomStringConvertible {
    public let provider: String
    public let key: String
    public let cluster: String
    /// Event bound on the thread channel; its payload is `{"message": "..."}`.
    public let eventName: String

    public var description: String { "FigoRealtimeConfig(provider: \(provider), eventName: \(eventName), key: ***, cluster: ***)" }
}
