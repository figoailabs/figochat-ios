import AVFoundation
import Combine
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PendingFile: Identifiable, Equatable {
    let id: String
    let name: String
    let mimeType: String?
    let data: Data
    var url: String?
    var uploading = true
    var failed = false
}

/// State and actions behind `FigoChatView`.
@MainActor
final class FigoChatViewModel: ObservableObject {
    @Published var messages: [FigoChatMessage] = []
    @Published var input = ""
    @Published var pending: [PendingFile] = []
    /// A reply to a message sent from this screen is on its way.
    @Published private(set) var replying = false
    /// Display details of the assistant, once loaded.
    @Published private(set) var assistant: FigoAssistantInfo?
    /// The `firstCustomerMessage` exchange from `initialize`.
    @Published private(set) var first: FigoFirstExchange?
    /// An anonymous visitor: the details form is shown instead of the conversation.
    @Published private(set) var needsDetails = false
    @Published private(set) var recording = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var transcribing = false
    @Published private(set) var notice: String?

    var onError: ((FigoChatError) -> Void)?

    private var ids = 0
    private var subscription: FigoRealtimeSubscription?
    private var recorder: AVAudioRecorder?
    private var recordTimer: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var changes: AnyCancellable?
    private var conversation = FigoChat.conversation

    init() {
        assistant = FigoChat.assistantInfo
        first = FigoChat.firstExchange
        needsDetails = FigoChat.needsDetails
        changes = FigoChat.changes.sink { [weak self] in
            guard let self else { return }
            self.assistant = FigoChat.assistantInfo
            self.first = FigoChat.firstExchange
            self.needsDetails = FigoChat.needsDetails
            // a new session, a new conversation or a logout: start from an empty screen
            if self.conversation != FigoChat.conversation {
                self.conversation = FigoChat.conversation
                self.messages.removeAll()
                self.subscription?.stop()
                self.subscription = nil
            }
            self.syncRealtime()
        }
    }

    /// A reply is on its way: one the user just asked for, or the one to `firstCustomerMessage`. Sending is blocked.
    var waiting: Bool { replying || (first.map { !$0.done } ?? false) }

    /// Header title: the persona, else the assistant name, else "Chat".
    var title: String {
        [assistant?.persona, assistant?.assistantName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Chat"
    }

    /// The assistant's waiting message as plain text, shown while a reply is on its way; nil shows typing dots.
    var waitingText: String? {
        let text = htmlToText(assistant?.waitingMessage ?? "")
        return text.isEmpty ? nil : text
    }

    /// What the screen shows: the intro message, the first exchange, then the messages sent from this screen.
    var displayMessages: [FigoChatMessage] {
        var all: [FigoChatMessage] = []
        if let intro = assistant?.introMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty {
            all.append(FigoChatMessage(id: "welcome", role: .assistant, text: intro, createdAt: .distantPast))
        }
        if let first {
            all.append(first.message)
            if let reply = first.reply { all.append(reply) }
            if let error = first.error {
                all.append(FigoChatMessage(id: "\(first.message.id)-error", role: .system, text: friendlyMessage(error, context: .chat)))
            }
        }
        return all + messages
    }

    private func newId() -> String {
        ids += 1
        return "\(Date().timeIntervalSince1970)-\(ids)"
    }

    @discardableResult
    private func report(_ error: Error) -> FigoChatError {
        let err = error as? FigoChatError ?? FigoChatError(error.localizedDescription, code: "UNKNOWN")
        onError?(err)
        return err
    }

    func showNotice(_ text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    // MARK: - Lifecycle (called by the view)

    func appear() { syncRealtime() }

    func disappear() {
        subscription?.stop()
        subscription = nil
        if recording { stopRecording(discard: true) }
    }

    // MARK: - Live agent messages

    /// Keeps a subscription to the Pusher channel named after the current thread id; what arrives is shown on the
    /// left, like an assistant reply. Re-subscribes when the thread changes and stops when there is none.
    private func syncRealtime() {
        let threadId = FigoChat.isInitialized ? FigoChat.threadId : nil
        if subscription?.threadId == threadId { return }

        subscription?.stop()
        subscription = nil
        guard let threadId, let store = try? FigoChat.realtime else { return }

        let sub = FigoRealtimeSubscription(
            store: store,
            threadId: threadId,
            onMessage: { [weak self] html in
                guard let self else { return }
                self.messages.append(FigoChatMessage(id: self.newId(), role: .assistant, text: html))
                FigoChat.emit(.messageReceived, htmlToText(html))
            },
            onError: { [weak self] error in self?.report(error) }
        )
        subscription = sub
        Task { await sub.start() }
    }

    // MARK: - Chat

    private func update(_ id: String, _ change: (inout FigoChatMessage) -> Void) {
        if let index = messages.firstIndex(where: { $0.id == id }) { change(&messages[index]) }
    }

    private func ask(_ message: FigoChatMessage) {
        replying = true
        Task {
            defer { replying = false }
            do {
                let reply = try await FigoChat.client.sendMessage(message.text, attachmentURLs: message.attachments.map(\.url))
                update(message.id) { $0.status = .sent }
                FigoChat.emit(.messageSent, message.text)
                // in live agent mode the API relays the message to the agent and answers with nothing;
                // the agent's reply arrives on the thread channel instead
                let replyText = htmlToText(reply.answer)
                if !replyText.isEmpty {
                    messages.append(FigoChatMessage(id: newId(), role: .assistant, text: reply.answer))
                    FigoChat.emit(.messageReceived, replyText)
                } else if reply.threadMode != "liveagent" {
                    messages.append(FigoChatMessage(id: newId(), role: .assistant, text: "…"))
                }
                syncRealtime()
            } catch {
                let err = report(error)
                update(message.id) { $0.status = .error }
                messages.append(FigoChatMessage(id: newId(), role: .system, text: friendlyMessage(err, context: .chat)))
            }
        }
    }

    func send(_ textOverride: String? = nil) {
        let text = (textOverride ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = pending.filter { !$0.uploading && !$0.failed && $0.url != nil }
        if waiting || (text.isEmpty && ready.isEmpty) { return }
        if pending.contains(where: \.uploading) {
            showNotice("Please wait, your files are still uploading.")
            return
        }

        let attachments = ready.map { FigoAttachment(url: $0.url!, name: $0.name, mimeType: $0.mimeType, data: $0.data) }
        let message = FigoChatMessage(
            id: newId(),
            role: .user,
            text: text.isEmpty ? (attachments.count > 1 ? "Please review the attached files." : "Please review the attached file.") : text,
            attachments: attachments,
            status: .sending
        )
        messages.append(message)
        pending.removeAll()
        if textOverride == nil { input = "" }
        ask(message)
    }

    func retry(_ message: FigoChatMessage) {
        if waiting { return }
        if message.id == first?.message.id {
            FigoChat.retryFirstMessage()
            return
        }
        update(message.id) { $0.status = .sending }
        ask(message)
    }

    func newConversation() {
        if waiting { return }
        FigoChat.resetConversation() // the change notification resets the messages and the subscription
        pending.removeAll()
        input = ""
    }

    // MARK: - Files

    func addFiles(_ urls: [URL]) {
        let files: [(name: String, mimeType: String?, data: Data)] = urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (url.lastPathComponent, UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, data)
        }
        enqueue(files)
    }

    func addPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var files: [(name: String, mimeType: String?, data: Data)] = []
            for (index, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                let ext = type?.preferredFilenameExtension ?? "jpg"
                files.append(("photo-\(index + 1).\(ext)", type?.preferredMIMEType ?? "image/jpeg", data))
            }
            enqueue(files)
        }
    }

    private func enqueue(_ files: [(name: String, mimeType: String?, data: Data)]) {
        guard !files.isEmpty, let config = try? FigoChat.config else { return }
        let room = config.maxFiles - pending.count
        if room <= 0 {
            showNotice("You can attach up to \(config.maxFiles) files per message.")
            return
        }
        let maxBytes = config.maxFileSizeMB * 1024 * 1024
        let tooBig = files.filter { $0.data.count > maxBytes }.map(\.name)
        if !tooBig.isEmpty { showNotice("\(tooBig.joined(separator: ", ")) is larger than \(config.maxFileSizeMB) MB.") }

        let items = files.filter { $0.data.count <= maxBytes }.prefix(room).map {
            PendingFile(id: newId(), name: $0.name, mimeType: $0.mimeType, data: $0.data)
        }
        pending.append(contentsOf: items)

        // one request per file so a failure only marks that file
        for item in items {
            Task {
                var updated = item
                do {
                    updated.url = try await FigoChat.client.uploadFiles([FigoUploadFile(name: item.name, data: item.data, mimeType: item.mimeType)]).first
                } catch {
                    report(error)
                    updated.failed = true
                }
                updated.uploading = false
                if let index = pending.firstIndex(where: { $0.id == item.id }) { pending[index] = updated }
            }
        }
    }

    func removePending(_ id: String) {
        pending.removeAll { $0.id == id }
    }

    // MARK: - Voice

    func startRecording() {
        Task { [weak self] in
            guard let self else { return }
            guard await Self.requestMicrophone() else {
                showNotice("Allow microphone access in Settings to send voice messages.")
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true)

                let url = FileManager.default.temporaryDirectory.appendingPathComponent("figochat-\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                guard recorder.record() else { throw FigoChatError("The microphone could not start.", code: "RECORD") }
                self.recorder = recorder
                recording = true
                recordingSeconds = 0
                recordTimer = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard let self, let r = self.recorder else { return }
                        self.recordingSeconds = Int(r.currentTime)
                    }
                }
            } catch {
                showNotice(friendlyMessage(report(error), context: .recording))
            }
        }
    }

    func stopRecording(discard: Bool = false) {
        recordTimer?.cancel()
        guard let recorder else { return }
        let duration = recorder.currentTime
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if discard || duration < 0.6 {
            try? FileManager.default.removeItem(at: url)
            return
        }

        transcribing = true
        Task {
            defer {
                transcribing = false
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let text = try await FigoChat.client.transcribe(audioFile: url, mimeType: "audio/mp4")
                if text.isEmpty {
                    showNotice("We could not hear anything in that recording. Please try again.")
                } else if (try? FigoChat.config)?.autoSendVoice == false {
                    input = input.isEmpty ? text : "\(input) \(text)"
                } else {
                    send(text)
                }
            } catch {
                showNotice(friendlyMessage(report(error), context: .voice))
            }
        }
    }

    private static func requestMicrophone() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}
