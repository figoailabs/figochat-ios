import Combine
import SwiftUI
import UIKit

/// Entry point of the SDK. Call `initialize` once (for example after the user signs in), then show the chat with
/// `present(from:)` (UIKit) or embed `FigoChatView` (SwiftUI).
public enum FigoChat {
    private final class Session {
        let config: FigoChatConfig
        let client: FigoChatClient
        let realtime: FigoRealtimeConfigStore

        init(config: FigoChatConfig) {
            self.config = config
            client = FigoChatClient(config: config)
            // realtime settings are fetched on first use and kept encrypted with a per-session key
            realtime = FigoRealtimeConfigStore(client: client, crypto: FigoCrypto())
        }
    }

    private static let lock = NSLock()
    private static var session: Session?

    /// Fires on initialize / reset / logout so open chat screens refresh.
    static let changes = PassthroughSubject<Void, Never>()

    public static func initialize(
        apiKey: String,
        fullName: String,
        emailAddress: String,
        mobilePhone: String,
        assistantId: String,
        primaryColor: String,
        baseURL: URL = FigoChatConfig.defaultBaseURL,
        title: String = "Chat",
        welcomeMessage: String? = nil,
        threadId: String? = nil,
        maxFiles: Int = 5,
        maxFileSizeMB: Int = 10,
        autoSendVoice: Bool = true,
        timeout: TimeInterval = 120
    ) throws {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let required = [
            ("apiKey", apiKey), ("fullName", fullName), ("emailAddress", emailAddress),
            ("mobilePhone", mobilePhone), ("assistantId", assistantId), ("primaryColor", primaryColor),
        ]
        let missing = required.filter { trim($0.1).isEmpty }.map(\.0)
        if !missing.isEmpty {
            throw FigoChatError("FigoChat.initialize: missing \(missing.joined(separator: ", ")).", code: "CONFIG")
        }
        guard trim(primaryColor).range(of: #"^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#, options: .regularExpression) != nil else {
            throw FigoChatError("FigoChat.initialize: primaryColor must be a hex color such as #F97316.", code: "CONFIG")
        }

        let config = FigoChatConfig(
            apiKey: trim(apiKey),
            assistantId: trim(assistantId),
            fullName: trim(fullName),
            emailAddress: trim(emailAddress),
            mobilePhone: trim(mobilePhone),
            primaryColor: trim(primaryColor),
            baseURL: baseURL,
            title: title,
            welcomeMessage: welcomeMessage,
            threadId: threadId,
            maxFiles: maxFiles,
            maxFileSizeMB: maxFileSizeMB,
            autoSendVoice: autoSendVoice,
            timeout: timeout
        )
        lock.withLock { session = Session(config: config) }
        notifyChange()
    }

    public static var isInitialized: Bool { lock.withLock { session != nil } }

    public static var config: FigoChatConfig {
        get throws { try requireSession().config }
    }

    /// The API client, for apps that want to build their own UI.
    public static var client: FigoChatClient {
        get throws { try requireSession().client }
    }

    static var realtime: FigoRealtimeConfigStore {
        get throws { try requireSession().realtime }
    }

    /// Thread id of the current conversation; store it and pass it as `threadId` to resume later.
    public static var threadId: String? { lock.withLock { session?.client.threadId } }

    /// Starts a new conversation on the next message.
    public static func resetConversation() {
        lock.withLock { session?.client.resetThread() }
        notifyChange()
    }

    /// Clears the configuration, e.g. when the user signs out.
    public static func logout() {
        lock.withLock { session = nil }
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
