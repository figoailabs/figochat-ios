import Foundation
import PusherSwift

/// Realtime settings as kept in memory: key and cluster are encrypted with the SDK's `FigoCrypto` instance.
struct EncryptedRealtimeConfig {
    let key: String
    let cluster: String
    let eventName: String
}

/// Fetches `GET /api/v1/realtime/config` once and keeps the result encrypted in memory.
actor FigoRealtimeConfigStore {
    private let client: FigoChatClient
    nonisolated let crypto: FigoCrypto
    private var cached: EncryptedRealtimeConfig?

    init(client: FigoChatClient, crypto: FigoCrypto) {
        self.client = client
        self.crypto = crypto
    }

    func get() async throws -> EncryptedRealtimeConfig {
        if let cached { return cached }
        let config = try await client.getRealtimeConfig()
        let encrypted = EncryptedRealtimeConfig(
            key: try crypto.encrypt(config.key),
            cluster: try crypto.encrypt(config.cluster),
            eventName: config.eventName
        )
        cached = encrypted // a failed fetch throws and is retried on the next subscribe
        return encrypted
    }
}

/// Subscribes to the Pusher channel named after the thread id (the `X-Thread-Id` value) and passes each message
/// published on it (live agent replies, live agent handoff notices) to `onMessage` as received (HTML), on the
/// main queue; messages with no text are skipped. The key and cluster are decrypted only here, right before connecting.
final class FigoRealtimeSubscription: NSObject, PusherDelegate {
    let threadId: String
    private let store: FigoRealtimeConfigStore
    private let onMessage: (String) -> Void
    private let onError: (Error) -> Void
    private var pusher: Pusher?
    private var closed = false

    init(store: FigoRealtimeConfigStore, threadId: String, onMessage: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        self.store = store
        self.threadId = threadId
        self.onMessage = onMessage
        self.onError = onError
    }

    @MainActor
    func start() async {
        do {
            let config = try await store.get()
            guard !closed else { return }

            let options = PusherClientOptions(host: .cluster(try store.crypto.decrypt(config.cluster)), useTLS: true)
            let client = Pusher(key: try store.crypto.decrypt(config.key), options: options)
            client.delegate = self
            pusher = client

            let channel = client.subscribe(threadId)
            _ = channel.bind(eventName: config.eventName) { [weak self] (event: PusherEvent) in
                guard let self, !self.closed else { return }
                let html = Self.message(from: event.data)
                guard !htmlToText(html).isEmpty else { return }
                DispatchQueue.main.async { if !self.closed { self.onMessage(html) } }
            }
            client.connect()
        } catch {
            if !closed { onError(error) }
        }
    }

    @MainActor
    func stop() {
        closed = true
        pusher?.unsubscribe(threadId)
        pusher?.disconnect()
        pusher = nil
    }

    // MARK: PusherDelegate

    func receivedError(error: PusherError) {
        guard !closed else { return }
        let message = error.message
        DispatchQueue.main.async { [weak self] in
            self?.onError(FigoChatError("Live updates are unavailable: \(message)", code: "REALTIME"))
        }
    }

    /// The payload is `{"message": "..."}`.
    private static func message(from data: String?) -> String {
        guard let data, !data.isEmpty else { return "" }
        if let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] {
            return json["message"] as? String ?? ""
        }
        return data
    }
}
