@testable import FigoChat
import XCTest

final class FigoCryptoTests: XCTestCase {
    func testRoundTripsWithAFreshNonceEachTime() throws {
        let crypto = FigoCrypto()
        for value in ["a1b2c3d4e5f6", "eu", "ünïcødé ✓ key", ""] {
            let first = try crypto.encrypt(value)
            let second = try crypto.encrypt(value)
            XCTAssertNotEqual(first, second)
            if !value.isEmpty { XCTAssertFalse(first.contains(value)) }
            XCTAssertEqual(try crypto.decrypt(first), value)
        }
    }

    func testAnotherInstanceCannotDecrypt() throws {
        let sealed = try FigoCrypto().encrypt("secret")
        XCTAssertThrowsError(try FigoCrypto().decrypt(sealed))
    }

    func testRejectsMalformedValues() {
        XCTAssertThrowsError(try FigoCrypto().decrypt("garbage"))
    }
}

final class HtmlTests: XCTestCase {
    private let reply =
        "<span style=\"line-height:1.3\">\n<b>What I can help you with</b>\n<p>I can handle a lot inside <i>BillsClan</i>.</p>\n\n"
        + "<ul>\n<li>Buy airtime</li>\n<li>Pay electricity bills</li>\n</ul>\n<p>Visit <a href=\"https://billsclan.com\">our site</a>.</p>"
        + "<ol><li>One</li><li>Two</li></ol></span>"

    func testAssistantHtmlReplyBecomesStyledRunsNeverMarkdown() {
        XCTAssertEqual(htmlToRuns(reply), [
            FigoTextRun(text: "What I can help you with", bold: true),
            FigoTextRun(text: "\n\nI can handle a lot inside "),
            FigoTextRun(text: "BillsClan", italic: true),
            FigoTextRun(text: ".\n\n• Buy airtime\n• Pay electricity bills\n\nVisit "),
            FigoTextRun(text: "our site", link: "https://billsclan.com"),
            FigoTextRun(text: ".\n\n1. One\n2. Two"),
        ])
    }

    func testHtmlToTextStripsTheHtmlToPlainText() {
        XCTAssertEqual(
            htmlToText(reply),
            "What I can help you with\n\nI can handle a lot inside BillsClan.\n\n• Buy airtime\n• Pay electricity bills\n\nVisit our site.\n\n1. One\n2. Two"
        )
        XCTAssertEqual(htmlToText("&lt;p&gt;Hi &lt;b&gt;Ada&lt;/b&gt;&lt;/p&gt;"), "Hi Ada")
        XCTAssertEqual(htmlToText("<b>Ada &amp; Co</b> says:<br/>Price is &lt;5&gt; &#39;ok&#39;"), "Ada & Co says:\nPrice is <5> 'ok'")
    }

    func testPlainTextKeepsLineBreaksAndDrawsBoldWithoutAsterisks() {
        XCTAssertEqual(htmlToRuns("Line 1\nLine 2, 5 < 6 and **bold**"), [
            FigoTextRun(text: "Line 1\nLine 2, 5 < 6 and "),
            FigoTextRun(text: "bold", bold: true),
        ])
    }

    func testUrlsBecomeLinksUnsafeHrefsDoNot() {
        XCTAssertEqual(htmlToRuns("See https://figolabs.ai."), [
            FigoTextRun(text: "See "),
            FigoTextRun(text: "https://figolabs.ai", link: "https://figolabs.ai"),
            FigoTextRun(text: "."),
        ])
        XCTAssertEqual(htmlToRuns("<a href=\"javascript:alert(1)\">x</a>"), [FigoTextRun(text: "x")])
        XCTAssertEqual(plainToRuns("<b>typed</b>"), [FigoTextRun(text: "<b>typed</b>")])
    }
}

final class ListenerTests: XCTestCase {
    func testAddEmitRemove() {
        var sent: [String] = []
        var received: [String] = []
        let token = FigoChat.addListener(onMessageSent: { sent.append($0) }, onMessageReceived: { received.append($0) })
        let receivedOnly = FigoChat.addListener(onMessageReceived: { received.append("2:" + $0) })

        FigoChat.emit(.messageSent, "hello")
        FigoChat.emit(.messageReceived, "hi there")
        XCTAssertEqual(sent, ["hello"])
        XCTAssertEqual(received, ["hi there", "2:hi there"])

        FigoChat.removeListener(token)
        FigoChat.removeListener(receivedOnly)
        FigoChat.emit(.messageSent, "again")
        FigoChat.emit(.messageReceived, "again")
        XCTAssertEqual(sent, ["hello"])
        XCTAssertEqual(received, ["hi there", "2:hi there"])
    }
}

final class InitializeTests: XCTestCase {
    func testRejectsMissingValuesAndBadColor() {
        XCTAssertThrowsError(try FigoChat.initialize(apiKey: "", fullName: "A", emailAddress: "a@b.c", mobilePhone: "+1", assistantId: "x", primaryColor: "#000"))
        XCTAssertThrowsError(try FigoChat.initialize(apiKey: "k", fullName: "A", emailAddress: "a@b.c", mobilePhone: "+1", assistantId: "x", primaryColor: "orange"))
        XCTAssertNoThrow(try FigoChat.initialize(apiKey: "k", fullName: "A", emailAddress: "a@b.c", mobilePhone: "+1", assistantId: "x", primaryColor: "#F97316"))
        XCTAssertTrue(FigoChat.isInitialized)
        FigoChat.logout()
        XCTAssertFalse(FigoChat.isInitialized)
    }
}

// MARK: - Session store (assistant details and firstCustomerMessage), against a fake API

/// Answers the SDK's requests in-process, so no API key or network is needed.
final class FakeAPI: URLProtocol {
    struct Call {
        let url: String
        let method: String?
        let auth: String?
        let body: [String: Any]?
    }

    static var assistant: [String: Any] = [:]
    static var answer = ""
    static var failChat = false
    static var offline = false
    private static let lock = NSLock()
    private static var _calls: [Call] = []
    static var calls: [Call] { lock.withLock { _calls } }

    static func reset(
        assistant: [String: Any] = ["assistantName": "Support Bot", "persona": "Dave", "waitingMessage": "One moment…", "introMessage": "<b>Hi!</b>"],
        answer: String = "<p>Your balance is <b>₦500</b></p>",
        failChat: Bool = false,
        offline: Bool = false
    ) {
        lock.withLock {
            self.assistant = assistant
            self.answer = answer
            self.failChat = failChat
            self.offline = offline
            _calls = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let (assistant, answer, failChat, offline) = Self.lock.withLock { () -> ([String: Any], String, Bool, Bool) in
            Self._calls.append(Call(url: url, method: request.httpMethod, auth: request.value(forHTTPHeaderField: "Authorization"), body: Self.body(of: request)))
            return (Self.assistant, Self.answer, Self.failChat, Self.offline)
        }
        if offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if url.hasSuffix("/api/v1/sdk/assistant/asst-1") {
            respond(200, ["responseCode": "00", "responseData": assistant])
        } else if url.contains("/api/v1/chat/assistant/") {
            if failChat {
                respond(401, "Unauthorized: Invalid api-key was passed")
            } else {
                respond(200, ["responseCode": "00", "responseData": answer], headers: ["X-Thread-Id": "thread-42", "X-Thread-Mode": "ai"])
            }
        } else {
            respond(404, [String: Any]())
        }
    }

    private func respond(_ status: Int, _ json: Any, headers: [String: String] = [:]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands URLProtocol the body as a stream.
    private static func body(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FigoChatClient.protocolClassesForTesting = [FakeAPI.self]
        FakeAPI.reset()
    }

    override func tearDown() {
        FigoChat.logout()
        FigoChatClient.protocolClassesForTesting = nil
        super.tearDown()
    }

    private func initialize(firstCustomerMessage: String? = nil) throws {
        try FigoChat.initialize(
            apiKey: "k", fullName: "Ada", emailAddress: "a@b.c", mobilePhone: "+1", assistantId: "asst-1",
            primaryColor: "#F97316", firstCustomerMessage: firstCustomerMessage
        )
    }

    /// Lets the fake requests and the main-queue notifications run until `condition` holds (or 3s pass).
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testInitializeLoadsTheAssistantDetailsForTitleIntroAndWaitingMessage() async throws {
        try initialize()
        XCTAssertNil(FigoChat.assistantInfo)
        await waitUntil { FigoChat.assistantInfo != nil }
        XCTAssertEqual(FigoChat.assistantInfo, FigoAssistantInfo(assistantName: "Support Bot", persona: "Dave", waitingMessage: "One moment…", introMessage: "<b>Hi!</b>"))
        XCTAssertEqual(FakeAPI.calls.first?.url, "https://api.figolabs.ai/api/v1/sdk/assistant/asst-1")
        XCTAssertEqual(FakeAPI.calls.first?.method, "GET")
        XCTAssertEqual(FakeAPI.calls.first?.auth, "Bearer k")
        XCTAssertNil(FigoChat.firstExchange)
    }

    func testFirstCustomerMessageIsSentOnInitializeKeepsTheThreadAndRaisesBothEvents() async throws {
        var events: [String] = []
        let token = FigoChat.addListener(onMessageSent: { events.append("sent: \($0)") }, onMessageReceived: { events.append("received: \($0)") })
        defer { FigoChat.removeListener(token) }

        try initialize(firstCustomerMessage: "  What is my balance?  ")
        let first = try XCTUnwrap(FigoChat.firstExchange)
        XCTAssertEqual(first.message.text, "What is my balance?")
        XCTAssertEqual(first.message.status, .sending)
        XCTAssertFalse(first.done)

        await waitUntil { FigoChat.firstExchange?.done == true && events.count == 2 }
        let done = try XCTUnwrap(FigoChat.firstExchange)
        XCTAssertEqual(done.message.status, .sent)
        XCTAssertEqual(done.reply?.text, "<p>Your balance is <b>₦500</b></p>")
        XCTAssertNil(done.error)
        XCTAssertEqual(FigoChat.threadId, "thread-42")
        let chat = try XCTUnwrap(FakeAPI.calls.first { $0.url.contains("/chat/assistant/") })
        XCTAssertEqual(chat.body as NSDictionary?, ["question": "What is my balance?", "fullName": "Ada", "emailAddress": "a@b.c", "phoneNumber": "+1"])
        XCTAssertEqual(events, ["sent: What is my balance?", "received: Your balance is ₦500"])
    }

    func testAFailedFirstCustomerMessageIsMarkedForRetryAndResetConversationClearsIt() async throws {
        FakeAPI.reset(failChat: true)
        try initialize(firstCustomerMessage: "Hello")
        await waitUntil { FigoChat.firstExchange?.done == true }
        XCTAssertEqual(FigoChat.firstExchange?.message.status, .error)
        XCTAssertEqual(FigoChat.firstExchange?.error?.code, "401")

        FakeAPI.reset()
        FigoChat.retryFirstMessage()
        XCTAssertEqual(FigoChat.firstExchange?.message.status, .sending)
        await waitUntil { FigoChat.firstExchange?.done == true }
        XCTAssertEqual(FigoChat.firstExchange?.message.status, .sent)
        XCTAssertEqual(FigoChat.firstExchange?.message.text, "Hello")

        FigoChat.resetConversation()
        XCTAssertNil(FigoChat.firstExchange)
        XCTAssertNil(FigoChat.threadId)
    }

    func testTheChatStillWorksWhenTheAssistantDetailsCannotLoad() async throws {
        FakeAPI.reset(offline: true)
        try initialize()
        await waitUntil { !FakeAPI.calls.isEmpty }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(FigoChat.assistantInfo)
        XCTAssertTrue(FigoChat.isInitialized)
        FigoChat.logout()
        XCTAssertFalse(FigoChat.isInitialized)
    }
}
