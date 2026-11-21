import Foundation

/// Thin client over the Figo AI public REST APIs:
///  - POST /api/v1/chat/assistant/{assistantId}   chat with the assistant
///  - POST /api/v1/stt                            speech to text (multipart, field `audio`)
///  - POST /api/v1/cdn/upload/ocr/{assistantId}   upload files to the CDN (images are OCR'd)
///  - GET  /api/v1/realtime/config                public Pusher settings for live agent messages
///  - GET  /api/v1/sdk/assistant/{assistantId}     the assistant's name, persona, waiting and intro messages
public final class FigoChatClient {
    private let config: FigoChatConfig
    /// Name, email and phone sent with messages; `FigoChat.setCustomerDetails` changes them. Guarded by `lock`.
    private var _details: FigoCustomerDetails
    private let session: URLSession
    private let lock = NSLock()
    private var _threadId: String?
    private var _threadMode: String?

    private static let codeSuccess = "00"
    private static let codeLimitReached = "49"

    /// Test seam: URLProtocol classes put in front of the default ones on clients created afterwards.
    static var protocolClassesForTesting: [AnyClass]?

    init(config: FigoChatConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout
        if let classes = Self.protocolClassesForTesting {
            sessionConfig.protocolClasses = classes + (sessionConfig.protocolClasses ?? [])
        }
        session = URLSession(configuration: sessionConfig)
        _threadId = config.threadId
        _details = FigoCustomerDetails(fullName: config.fullName, emailAddress: config.emailAddress, mobilePhone: config.mobilePhone)
    }

    /// The name, email and phone sent with each message ("" when unknown).
    public var customerDetails: FigoCustomerDetails { lock.withLock { _details } }

    func setCustomerDetails(_ details: FigoCustomerDetails) {
        lock.withLock { _details = details }
    }

    /// Thread id of the current conversation, once the first reply has arrived.
    public var threadId: String? { lock.withLock { _threadId } }

    /// "ai" or "liveagent".
    public var threadMode: String? { lock.withLock { _threadMode } }

    /// Forget the current thread so the next message starts a new conversation.
    public func resetThread() {
        lock.withLock {
            _threadId = nil
            _threadMode = nil
        }
    }

    /// Sends a message. CDN urls of uploaded files are appended to the question so the assistant can read them
    /// (the API adds the OCR text of uploaded images).
    public func sendMessage(_ text: String, attachmentURLs: [String] = []) async throws -> FigoChatReply {
        let question = ([text.trimmingCharacters(in: .whitespacesAndNewlines)] + attachmentURLs)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !question.isEmpty else { throw FigoChatError("Message is empty.", code: "EMPTY") }

        let details = customerDetails
        var body: [String: Any] = [
            "question": question,
            "fullName": details.fullName,
            "emailAddress": details.emailAddress,
            "phoneNumber": details.mobilePhone,
        ]
        if let threadId { body["threadId"] = threadId }

        var request = makeRequest(["api", "v1", "chat", "assistant", config.assistantId], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (json, response) = try await perform(request)
        lock.withLock {
            if let id = response.value(forHTTPHeaderField: "X-Thread-Id"), !id.isEmpty { _threadId = id }
            if let mode = response.value(forHTTPHeaderField: "X-Thread-Mode"), !mode.isEmpty { _threadMode = mode }
        }
        return FigoChatReply(answer: json["responseData"] as? String ?? "", threadId: threadId, threadMode: threadMode)
    }

    /// Transcribes a recorded audio file (AAC in an .m4a container) to text.
    public func transcribe(audioFile: URL, mimeType: String = "audio/mp4") async throws -> String {
        let data = try Data(contentsOf: audioFile)
        let boundary = "FigoChat-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioFile.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = makeRequest(["api", "v1", "stt"], method: "POST", query: [URLQueryItem(name: "mimetype", value: mimeType)])
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (json, _) = try await perform(request)
        return (json["responseData"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uploads files to the CDN and returns one url per file, in order. Images are OCR'd by the API, so sending
    /// their urls in a chat message lets the assistant read them.
    public func uploadFiles(_ files: [FigoUploadFile]) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let payload = files.map { ["extension": $0.fileExtension, "base64String": $0.data.base64EncodedString()] }

        var request = makeRequest(["api", "v1", "cdn", "upload", "ocr", config.assistantId], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // a partial failure still returns the urls that did upload, with null in the failed slots
        let (json, _) = try await perform(request, allowFailureCode: true)
        let urls = (json["responseData"] as? [Any] ?? []).map { $0 as? String ?? "" }
        if urls.isEmpty || urls.contains(where: \.isEmpty) {
            throw FigoChatError(json["responseMessage"] as? String ?? "Upload failed.", code: json["responseCode"] as? String ?? "UPLOAD")
        }
        return urls
    }

    /// The assistant's display details: name, persona, waiting message and intro message.
    public func getAssistant() async throws -> FigoAssistantInfo {
        let (json, _) = try await perform(makeRequest(["api", "v1", "sdk", "assistant", config.assistantId], method: "GET"))
        let data = json["responseData"] as? [String: Any] ?? [:]
        return FigoAssistantInfo(
            assistantName: data["assistantName"] as? String,
            persona: data["persona"] as? String,
            waitingMessage: data["waitingMessage"] as? String,
            introMessage: data["introMessage"] as? String
        )
    }

    /// Public Pusher settings used to subscribe to the thread channel for live agent messages.
    public func getRealtimeConfig() async throws -> FigoRealtimeConfig {
        let (json, _) = try await perform(makeRequest(["api", "v1", "realtime", "config"], method: "GET"))
        let data = json["responseData"] as? [String: Any]
        guard let key = data?["key"] as? String, !key.isEmpty,
              let cluster = data?["cluster"] as? String, !cluster.isEmpty
        else { throw FigoChatError("Realtime is not configured on the server.", code: "REALTIME") }
        return FigoRealtimeConfig(
            provider: data?["provider"] as? String ?? "pusher",
            key: key,
            cluster: cluster,
            eventName: (data?["eventName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "figoai"
        )
    }

    // MARK: - Helpers

    /// Base url + path segments (each appended as one percent-encoded segment).
    private func makeRequest(_ segments: [String], method: String, query: [URLQueryItem] = []) -> URLRequest {
        var url = config.baseURL
        for segment in segments { url.appendPathComponent(segment) }
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(_ request: URLRequest, allowFailureCode: Bool = false) async throws -> ([String: Any], HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw FigoChatError("The request timed out. Please try again.", code: "TIMEOUT")
        } catch is CancellationError {
            throw FigoChatError("The request was cancelled.", code: "CANCELLED")
        } catch {
            throw FigoChatError("Network error. Check your connection and try again.", code: "NETWORK")
        }

        guard let http = response as? HTTPURLResponse else {
            throw FigoChatError("Unexpected response from the server.", code: "PARSE")
        }
        let raw = String(data: data, encoding: .utf8) ?? ""

        guard (200..<300).contains(http.statusCode) else {
            // ApiAccessKeyAuthorize returns a plain string such as "Invalid api-key was passed"
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
            let message = http.statusCode == 401
                ? "Unauthorized: \(text.isEmpty ? "check your API key." : text)"
                : (text.isEmpty ? "Request failed (\(http.statusCode))." : text)
            throw FigoChatError(message, code: String(http.statusCode))
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FigoChatError("Unexpected response from the server.", code: "PARSE")
        }
        let code = json["responseCode"] as? String ?? ""
        let message = json["responseMessage"] as? String ?? ""
        if code == Self.codeLimitReached {
            throw FigoChatError(message.isEmpty ? "Usage limit reached." : message, code: code)
        }
        if code != Self.codeSuccess && !allowFailureCode {
            throw FigoChatError(message.isEmpty ? "Something went wrong." : message, code: code.isEmpty ? "UNKNOWN" : code)
        }
        return (json, http)
    }
}
