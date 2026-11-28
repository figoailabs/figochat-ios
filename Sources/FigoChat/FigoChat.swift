import Combine
import SwiftUI
import UIKit

/// Entry point of the SDK. Call `initialize` once (for example after the user signs in), then show the chat with
/// `present(from:)` (UIKit) or embed `FigoChatView` (SwiftUI).
public enum FigoChat {
    private final class Session {
        /// Guarded by `lock` (the customer details change with `setCustomerDetails`).
        var config: FigoChatConfig
        let client: FigoChatClient
        let realtime: FigoRealtimeConfigStore
        /// Display details from `GET /api/v1/sdk/assistant/{id}`; nil until loaded (or if loading failed). Guarded by `lock`.
        var assistant: FigoAssistantInfo?
        /// The `firstCustomerMessage` exchange. Guarded by `lock`.
        var first: FigoFirstExchange?
        /// An anonymous visitor: the chat shows the details form until it's submitted or skipped. Guarded by `lock`.
        var needsDetails = false
        /// `firstCustomerMessage` held back until the details form is submitted or skipped. Guarded by `lock`.
        var pendingFirst: String?
        /// `initialize` got no name, email or phone (and `setCustomerDetails` hasn't been called since). Guarded by `lock`.
        var anonymous = false
        /// The current details were typed into the details form. Guarded by `lock`.
        var formDetails = false
        /// The details form was skipped. Guarded by `lock`.
        var skipped = false
        /// Last message sent or reply / live agent message received; the conversation session ends an hour later.
        /// In memory only. Guarded by `lock`.
        var lastActivity: Date?

        init(config: FigoChatConfig) {
            self.config = config
            client = FigoChatClient(config: config)
            // realtime settings are fetched on first use and kept encrypted with a per-session key
            realtime = FigoRealtimeConfigStore(client: client, crypto: FigoCrypto())
        }
    }

    private static let lock = NSLock()
    private static var session: Session?

    /// Fires on initialize / reset / logout, and when the assistant details or the first exchange arrive, so open
    /// chat screens refresh.
    static let changes = PassthroughSubject<Void, Never>()

    /// Changes on initialize / resetConversation / logout: chat screens clear their own messages when it does.
    private static var _conversation = 0
    static var conversation: Int { lock.withLock { _conversation } }

    /// Configures the SDK, loads the assistant's details and sends `firstCustomerMessage` if one is given. Call it
    /// again to switch user or settings.
    ///
    /// `fullName`, `emailAddress` and `mobilePhone` are optional: when all three are empty and `askForDetails` is
    /// true, the chat first shows a form asking for them (unless this visitor filled it in or skipped it during the
    /// current conversation session). `firstCustomerMessage` is sent once the form is done.
    ///
    /// A conversation session is the thread and the details typed into the form. It lasts one hour from the last
    /// message sent or received and is kept in memory only, so it ends when the app's process does. An anonymous
    /// visitor's session carries over when `initialize` is called again within that hour.
    public static func initialize(
        apiKey: String,
        fullName: String = "",
        emailAddress: String = "",
        mobilePhone: String = "",
        assistantId: String,
        primaryColor: String,
        baseURL: URL = FigoChatConfig.defaultBaseURL,
        firstCustomerMessage: String? = nil,
        threadId: String? = nil,
        maxFiles: Int = 5,
        maxFileSizeMB: Int = 10,
        autoSendVoice: Bool = true,
        timeout: TimeInterval = 120,
        askForDetails: Bool = true,
        defaultCountry: String? = nil
    ) throws {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let required = [("apiKey", apiKey), ("assistantId", assistantId), ("primaryColor", primaryColor)]
        let missing = required.filter { trim($0.1).isEmpty }.map(\.0)
        if !missing.isEmpty {
            throw FigoChatError("FigoChat.initialize: missing \(missing.joined(separator: ", ")).", code: "CONFIG")
        }
        guard trim(primaryColor).range(of: #"^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#, options: .regularExpression) != nil else {
            throw FigoChatError("FigoChat.initialize: primaryColor must be a hex color such as #F97316.", code: "CONFIG")
        }

        // versions before 2.4 kept form details on the device indefinitely: remove them
        removeLegacyDetails(trim(assistantId))

        // anonymous visitor: reuse the session they started in this app run (details, skip, thread) for an hour
        let now = clock()
        var details = FigoCustomerDetails(fullName: trim(fullName), emailAddress: trim(emailAddress), mobilePhone: trim(mobilePhone))
        let anonymous = details.isEmpty
        let stored = lock.withLock { () -> StoredConversation? in
            guard anonymous, let stored = conversations[trim(assistantId)] else { return nil }
            if isExpired(stored.lastActivity, now: now) {
                conversations[trim(assistantId)] = nil
                return nil
            }
            return stored
        }
        var needsDetails = false
        var formDetails = false
        var skipped = false
        if anonymous && askForDetails {
            if let saved = stored?.details, !saved.isEmpty {
                details = saved
                formDetails = true
            } else {
                skipped = stored?.skipped ?? false
                needsDetails = !skipped
            }
        }

        let config = FigoChatConfig(
            apiKey: trim(apiKey),
            assistantId: trim(assistantId),
            fullName: details.fullName,
            emailAddress: details.emailAddress,
            mobilePhone: details.mobilePhone,
            primaryColor: trim(primaryColor),
            baseURL: baseURL,
            firstCustomerMessage: firstCustomerMessage,
            threadId: threadId,
            maxFiles: maxFiles,
            maxFileSizeMB: maxFileSizeMB,
            autoSendVoice: autoSendVoice,
            timeout: timeout,
            askForDetails: askForDetails,
            defaultCountry: defaultCountry.map(trim).flatMap { $0.isEmpty ? nil : $0.uppercased() }
        )
        let newSession = Session(config: config)
        let first = firstCustomerMessage.map(trim).flatMap { $0.isEmpty ? nil : $0 }
        newSession.needsDetails = needsDetails
        newSession.anonymous = anonymous
        newSession.formDetails = formDetails
        newSession.skipped = skipped
        if needsDetails { newSession.pendingFirst = first }
        if let threadId, !trim(threadId).isEmpty {
            // the app resumes a conversation: it's active from now
            newSession.lastActivity = now
        } else if let stored {
            newSession.lastActivity = stored.lastActivity
            if !needsDetails, let thread = stored.threadId { newSession.client.restoreThread(thread) }
        }
        newSession.client.setOnActivity { [weak newSession] in
            if let newSession { recordActivity(newSession) }
        }
        lock.withLock {
            session = newSession
            _conversation += 1
            storeConversation(newSession)
        }
        loadAssistant(newSession)
        if let first, !needsDetails { sendFirstMessage(newSession, first) }
        notifyChange()
    }

    public static var isInitialized: Bool { lock.withLock { session != nil } }

    public static var config: FigoChatConfig {
        get throws {
            let target = try requireSession()
            return lock.withLock { target.config }
        }
    }

    // MARK: - Customer details

    /// Sets the customer's name, email and phone, for example once a visitor signs in. They're sent with the rest of
    /// the conversation, exactly as if they'd been passed to `initialize`, and close the details form if it's
    /// showing (sending a held-back `firstCustomerMessage`). A nil value keeps the current one. Does nothing before
    /// `initialize`.
    public static func setCustomerDetails(fullName: String? = nil, emailAddress: String? = nil, mobilePhone: String? = nil) {
        guard let target = lock.withLock({ session }) else { return }
        applyDetails(target, fullName: fullName, emailAddress: emailAddress, mobilePhone: mobilePhone, fromForm: false)
    }

    private static func applyDetails(_ target: Session, fullName: String?, emailAddress: String?, mobilePhone: String?, fromForm: Bool) {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let details = lock.withLock { () -> FigoCustomerDetails in
            target.config.fullName = trim(fullName ?? target.config.fullName)
            target.config.emailAddress = trim(emailAddress ?? target.config.emailAddress)
            target.config.mobilePhone = trim(mobilePhone ?? target.config.mobilePhone)
            let details = FigoCustomerDetails(
                fullName: target.config.fullName, emailAddress: target.config.emailAddress, mobilePhone: target.config.mobilePhone
            )
            if fromForm {
                // the form starts the conversation session
                target.formDetails = true
                target.lastActivity = clock()
            } else if !details.isEmpty {
                // the app knows who this is now: the conversation is no longer an anonymous visitor's
                target.anonymous = false
                target.formDetails = false
                if session === target { conversations[target.config.assistantId] = nil }
            }
            storeConversation(target)
            return details
        }
        target.client.setCustomerDetails(details)
        continueAfterDetails(target)
    }

    /// The customer's current name, email and phone (empty strings when unknown or before `initialize`).
    public static var customerDetails: FigoCustomerDetails {
        lock.withLock {
            guard let config = session?.config else { return FigoCustomerDetails() }
            return FigoCustomerDetails(fullName: config.fullName, emailAddress: config.emailAddress, mobilePhone: config.mobilePhone)
        }
    }

    /// The chat shows the details form instead of the conversation.
    static var needsDetails: Bool { lock.withLock { session?.needsDetails ?? false } }

    /// The details form was submitted: use the details for this conversation session (in memory only).
    static func submitDetails(_ details: FigoCustomerDetails) {
        guard let target = lock.withLock({ session }) else { return }
        applyDetails(target, fullName: details.fullName, emailAddress: details.emailAddress, mobilePhone: details.mobilePhone, fromForm: true)
    }

    /// The details form was skipped: chat without details, and don't ask again during this conversation session.
    static func skipDetails() {
        guard let target = lock.withLock({ session }) else { return }
        lock.withLock {
            target.skipped = true
            target.lastActivity = clock()
            storeConversation(target)
        }
        continueAfterDetails(target)
    }

    /// Leaves the details form: sends the held-back `firstCustomerMessage` and refreshes the chat.
    private static func continueAfterDetails(_ target: Session) {
        let first = lock.withLock { () -> String? in
            target.needsDetails = false
            defer { target.pendingFirst = nil }
            return session === target ? target.pendingFirst : nil
        }
        if let first { sendFirstMessage(target, first) }
        notifyChange()
    }

    // MARK: - Conversation session

    // A conversation session is the thread and the details typed into the form (or the skip). It lasts one hour
    // from the last activity (a message sent, a reply or live agent message received) and lives in memory only:
    // nothing is written to the device, so it ends with the app's process, like a closed browser tab.

    /// How long a conversation session lasts after its last activity.
    static let sessionLifetime: TimeInterval = 60 * 60

    /// Test seam: the clock used for the session's activity and expiry.
    static var clock: () -> Date = { Date() }

    /// An anonymous visitor's session, kept for this app run so `initialize` can pick it up again.
    private struct StoredConversation {
        var details: FigoCustomerDetails?
        var skipped = false
        var threadId: String?
        var lastActivity: Date?
    }

    /// By assistant id. Guarded by `lock`.
    private static var conversations: [String: StoredConversation] = [:]

    /// true when the session's last activity was at least `sessionLifetime` ago; false when there was none.
    static func isExpired(_ lastActivity: Date?, now: Date) -> Bool {
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= sessionLifetime
    }

    /// Ends the conversation session if it has expired: forgets the thread, the form's details and the skip,
    /// clears the first exchange and the chat's messages, and asks an anonymous visitor for their details again
    /// (unless `askForDetails` is false). Returns whether it expired. Checked on `initialize`, when the chat
    /// appears and before sending.
    @discardableResult
    static func expireSessionIfNeeded(now: Date? = nil) -> Bool {
        guard let target = lock.withLock({ session }) else { return false }
        let now = now ?? clock()
        let details = lock.withLock { () -> FigoCustomerDetails? in
            guard session === target, isExpired(target.lastActivity, now: now) else { return nil }
            target.client.resetThread()
            target.first = nil
            target.pendingFirst = nil
            target.lastActivity = nil
            target.skipped = false
            if target.formDetails {
                target.config.fullName = ""
                target.config.emailAddress = ""
                target.config.mobilePhone = ""
                target.formDetails = false
            }
            let details = FigoCustomerDetails(
                fullName: target.config.fullName, emailAddress: target.config.emailAddress, mobilePhone: target.config.mobilePhone
            )
            target.needsDetails = target.anonymous && target.config.askForDetails && details.isEmpty
            conversations[target.config.assistantId] = nil
            _conversation += 1
            return details
        }
        guard let details else { return false }
        target.client.setCustomerDetails(details)
        notifyChange()
        return true
    }

    /// A live agent message arrived on the chat screen: the conversation session is active.
    static func noteActivity() {
        guard let target = lock.withLock({ session }) else { return }
        recordActivity(target)
    }

    private static func recordActivity(_ target: Session) {
        lock.withLock {
            guard session === target else { return }
            target.lastActivity = clock()
            storeConversation(target)
        }
    }

    /// Keeps an anonymous visitor's session for this app run. Call with `lock` held.
    private static func storeConversation(_ target: Session) {
        guard target.anonymous, session === target else { return }
        conversations[target.config.assistantId] = StoredConversation(
            details: target.formDetails ? FigoCustomerDetails(
                fullName: target.config.fullName, emailAddress: target.config.emailAddress, mobilePhone: target.config.mobilePhone
            ) : nil,
            skipped: target.skipped,
            threadId: target.client.threadId,
            lastActivity: target.lastActivity
        )
    }

    /// Test seam: the UserDefaults older versions saved form details in (`.standard` when nil).
    static var storageForTesting: UserDefaults?
    private static var storage: UserDefaults { storageForTesting ?? .standard }

    /// Where versions before 2.4 saved the form's details.
    static func detailsKey(_ assistantId: String) -> String { "figochat.details.\(assistantId)" }

    private static func removeLegacyDetails(_ assistantId: String) {
        storage.removeObject(forKey: detailsKey(assistantId))
    }

    static func hasSkippedDetails(_ assistantId: String) -> Bool {
        lock.withLock {
            if let session, session.config.assistantId == assistantId, session.skipped { return true }
            return conversations[assistantId]?.skipped ?? false
        }
    }

    private static func forgetDetails(_ assistantId: String) {
        removeLegacyDetails(assistantId)
        _ = lock.withLock { conversations.removeValue(forKey: assistantId) }
    }

    /// Test seam: forgets every conversation session, like a fresh app run.
    static func forgetSessionsForTesting() {
        lock.withLock { conversations.removeAll() }
    }

    /// The API client, for apps that want to build their own UI.
    public static var client: FigoChatClient {
        get throws { try requireSession().client }
    }

    static var realtime: FigoRealtimeConfigStore {
        get throws { try requireSession().realtime }
    }

    /// The assistant's display details (name, persona, waiting and intro messages, disclaimer, company terms and
    /// privacy policy), or nil until they have
    /// loaded. They're fetched by `initialize`.
    public static var assistantInfo: FigoAssistantInfo? { lock.withLock { session?.assistant } }

    /// The `firstCustomerMessage` exchange, shown at the top of the chat.
    static var firstExchange: FigoFirstExchange? { lock.withLock { session?.first } }

    /// Sends the `firstCustomerMessage` again after it failed (the chat's "Tap to retry").
    static func retryFirstMessage() {
        let target = lock.withLock { () -> (Session, String)? in
            guard let session, let first = session.first, first.done, first.error != nil else { return nil }
            return (session, first.message.text)
        }
        guard let (session, text) = target else { return }
        sendFirstMessage(session, text)
        notifyChange()
    }

    /// Thread id of the current conversation; store it and pass it as `threadId` to resume later.
    public static var threadId: String? { lock.withLock { session?.client.threadId } }

    /// Starts a new conversation on the next message.
    public static func resetConversation() {
        lock.withLock {
            session?.client.resetThread()
            session?.first = nil
            _conversation += 1
            if let session { storeConversation(session) }
        }
        notifyChange()
    }

    /// Clears the configuration, e.g. when the user signs out. The conversation session (thread, details a visitor
    /// typed into the details form, a skip) is forgotten too.
    public static func logout() {
        let assistantId = lock.withLock { () -> String? in
            defer {
                session = nil
                _conversation += 1
            }
            return session?.config.assistantId
        }
        if let assistantId { forgetDetails(assistantId) }
        notifyChange()
    }

    // MARK: - Events

    private struct Listeners {
        var nextId = 0
        var sent: [Int: (String) -> Void] = [:]
        var received: [Int: (String) -> Void] = [:]
    }

    private static let listenersLock = NSLock()
    private static var listeners = Listeners()

    /// Listens to chat events and returns a token; pass it to `removeListener(_:)` to stop listening.
    /// - `onMessageSent`: the user's message was delivered; gets the text the user sent.
    /// - `onMessageReceived`: an assistant or live agent reply arrived; gets the reply as plain text (HTML stripped).
    ///
    /// Listeners are called on the main thread. They can be added from any thread, before `initialize`, and stay
    /// registered across `logout`.
    @discardableResult
    public static func addListener(
        onMessageSent: ((String) -> Void)? = nil,
        onMessageReceived: ((String) -> Void)? = nil
    ) -> FigoChatListenerToken {
        listenersLock.withLock {
            listeners.nextId += 1
            let id = listeners.nextId
            if let onMessageSent { listeners.sent[id] = onMessageSent }
            if let onMessageReceived { listeners.received[id] = onMessageReceived }
            return FigoChatListenerToken(id: id)
        }
    }

    /// Stops the listeners added with the call that returned `token`.
    public static func removeListener(_ token: FigoChatListenerToken) {
        listenersLock.withLock {
            listeners.sent[token.id] = nil
            listeners.received[token.id] = nil
        }
    }

    enum Event {
        case messageSent
        case messageReceived
    }

    /// Raised by the chat screen; calls the matching listeners on the main thread.
    static func emit(_ event: Event, _ text: String) {
        let targets = listenersLock.withLock { () -> [(String) -> Void] in
            let map = event == .messageSent ? listeners.sent : listeners.received
            return map.keys.sorted().compactMap { map[$0] }
        }
        guard !targets.isEmpty else { return }
        let call = { targets.forEach { $0(text) } }
        if Thread.isMainThread { call() } else { DispatchQueue.main.async(execute: call) }
    }

    /// Presents the chat full screen from a UIKit view controller.
    @MainActor
    public static func present(from presenter: UIViewController, animated: Bool = true) {
        let controller = FigoChatViewController()
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: animated)
    }

    private static func loadAssistant(_ target: Session) {
        Task {
            // the chat still works without it: default title, no intro, typing dots instead of the waiting message
            guard let info = try? await target.client.getAssistant() else { return }
            let current = lock.withLock { () -> Bool in
                guard session === target else { return false }
                target.assistant = info
                return true
            }
            if current { notifyChange() }
        }
    }

    private static func sendFirstMessage(_ target: Session, _ text: String) {
        let message = FigoChatMessage(id: "first-\(UUID().uuidString)", role: .user, text: text, status: .sending)
        lock.withLock { target.first = FigoFirstExchange(message: message) }
        Task {
            var result = FigoFirstExchange(message: message, done: true)
            var replyText = ""
            do {
                let reply = try await target.client.sendMessage(text)
                result.message.status = .sent
                replyText = htmlToText(reply.answer)
                if !replyText.isEmpty {
                    result.reply = FigoChatMessage(id: "\(message.id)-reply", role: .assistant, text: reply.answer)
                }
            } catch {
                result.message.status = .error
                result.error = error as? FigoChatError ?? FigoChatError(error.localizedDescription, code: "UNKNOWN")
            }
            let current = lock.withLock { () -> Bool in
                guard target.first?.message.id == message.id else { return false }
                target.first = result
                return session === target
            }
            if result.error == nil {
                emit(.messageSent, text)
                if !replyText.isEmpty { emit(.messageReceived, replyText) }
            }
            if current { notifyChange() }
        }
    }

    private static func requireSession() throws -> Session {
        guard let session = lock.withLock({ session }) else {
            throw FigoChatError("FigoChat is not initialized. Call FigoChat.initialize(...) first.", code: "NOT_INITIALIZED")
        }
        return session
    }

    private static func notifyChange() {
        if Thread.isMainThread { changes.send() } else { DispatchQueue.main.async { changes.send() } }
    }
}

/// The `firstCustomerMessage` sent by `initialize` and what came back. The chat screen shows it at the top of the
/// conversation.
struct FigoFirstExchange: Equatable {
    var message: FigoChatMessage
    /// The raw reply (HTML), only when it has text.
    var reply: FigoChatMessage?
    var error: FigoChatError?
    var done = false
}

/// Returned by `FigoChat.addListener(onMessageSent:onMessageReceived:)`; pass it to `FigoChat.removeListener(_:)`.
public struct FigoChatListenerToken: Hashable, Sendable {
    let id: Int
}

/// UIKit container for `FigoChatView`; `FigoChat.present(from:)` shows it full screen.
public final class FigoChatViewController: UIHostingController<FigoChatView> {
    public init() {
        super.init(rootView: FigoChatView())
        rootView = FigoChatView(onClose: { [weak self] in self?.dismiss(animated: true) })
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder, rootView: FigoChatView())
    }
}
