@testable import FigoChat
import XCTest

final class FigoCryptoTests: XCTestCase {
    func testRoundTripsWithAFreshNonceEachTime() throws {
        let crypto = FigoCrypto()
        for value in ["a1b2c3d4e5f6", "eu", "ünïcødé ✓ key", ""] {
            let first = try crypto.encrypt(value)
            let second = try crypto.encrypt(value)
            XCTAssertNotEqual(first, second)
            // only long values: a short one like "eu" can turn up by chance in random base64
            if value.count >= 8 { XCTAssertFalse(first.contains(value)) }
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
    /// `responseData` of GET /api/v1/chat/messages/asst-1/thread-42; nil answers 404.
    static var history: [[String: Any]]?
    private static let lock = NSLock()
    private static var _calls: [Call] = []
    static var calls: [Call] { lock.withLock { _calls } }

    static func reset(
        assistant: [String: Any] = ["assistantName": "Support Bot", "persona": "Dave", "waitingMessage": "One moment…", "introMessage": "<b>Hi!</b>"],
        answer: String = "<p>Your balance is <b>₦500</b></p>",
        failChat: Bool = false,
        offline: Bool = false,
        history: [[String: Any]]? = nil
    ) {
        lock.withLock {
            self.history = history
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
        let (assistant, answer, failChat, offline, history) = Self.lock.withLock { () -> ([String: Any], String, Bool, Bool, [[String: Any]]?) in
            Self._calls.append(Call(url: url, method: request.httpMethod, auth: request.value(forHTTPHeaderField: "Authorization"), body: Self.body(of: request)))
            return (Self.assistant, Self.answer, Self.failChat, Self.offline, Self.history)
        }
        if offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if url.hasSuffix("/api/v1/sdk/assistant/asst-1") {
            respond(200, ["responseCode": "00", "responseData": assistant])
        } else if url.hasSuffix("/api/v1/chat/messages/asst-1/thread-42"), let history {
            respond(200, ["responseCode": "00", "responseMessage": "Success", "responseData": history])
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

    func testAssistantDetailsDecodeTheDisclaimerAndCompanyLinksAndTolerateNulls() async throws {
        FakeAPI.reset(assistant: [
            "persona": "Dave", "disclaimerMessage": "AI can make mistakes. Double-check sensitive information",
            "company": ["termsAndCondition": "https://shop.example.com/terms", "privacyPolicy": NSNull()],
        ])
        try initialize()
        await waitUntil { FigoChat.assistantInfo != nil }
        XCTAssertEqual(FigoChat.assistantInfo, FigoAssistantInfo(
            persona: "Dave", disclaimerMessage: "AI can make mistakes. Double-check sensitive information",
            company: FigoCompanyInfo(termsAndCondition: "https://shop.example.com/terms", privacyPolicy: nil)
        ))
        XCTAssertEqual(FigoChat.assistantInfo?.disclaimer, "AI can make mistakes. Double-check sensitive information")

        FigoChat.logout()
        FakeAPI.reset(assistant: ["persona": "Dave", "disclaimerMessage": NSNull(), "company": NSNull()])
        try initialize()
        await waitUntil { FigoChat.assistantInfo != nil }
        XCTAssertEqual(FigoChat.assistantInfo, FigoAssistantInfo(persona: "Dave"))
        XCTAssertNil(FigoChat.assistantInfo?.disclaimer)
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

// MARK: - Details form (anonymous visitors), against a fake API

@MainActor
final class DetailsFormTests: XCTestCase {
    private let suite = "figochat.tests.details"
    private var storage: UserDefaults!

    override func setUp() {
        super.setUp()
        FigoChatClient.protocolClassesForTesting = [FakeAPI.self]
        FakeAPI.reset()
        storage = UserDefaults(suiteName: suite)
        FigoChat.storageForTesting = storage
        reset()
    }

    override func tearDown() {
        reset()
        FigoChat.storageForTesting = nil
        FigoChatClient.protocolClassesForTesting = nil
        super.tearDown()
    }

    /// Like a fresh install: no session, nothing saved, nothing skipped.
    private func reset() {
        if FigoChat.isInitialized { FigoChat.logout() }
        storage.removePersistentDomain(forName: suite)
        FigoChat.forgetSessionsForTesting()
        FigoChat.clock = { Date() }
    }

    private func initializeAnonymous(firstCustomerMessage: String? = nil, askForDetails: Bool = true, defaultCountry: String? = nil) throws {
        try FigoChat.initialize(
            apiKey: "k", assistantId: "asst-1", primaryColor: "#F97316", firstCustomerMessage: firstCustomerMessage,
            askForDetails: askForDetails, defaultCountry: defaultCountry
        )
    }

    private var chatCalls: [FakeAPI.Call] { FakeAPI.calls.filter { $0.url.contains("/chat/assistant/") } }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func savedDetails() throws -> FigoCustomerDetails? {
        try storage.data(forKey: "figochat.details.asst-1").map { try JSONDecoder().decode(FigoCustomerDetails.self, from: $0) }
    }

    /// Submits the form like a visitor would, with a UK number typed with its trunk 0.
    private func fillAndSubmit(_ form: FigoDetailsFormModel) throws {
        form.fullName = "Ada Lovelace"
        form.emailAddress = "ada@example.com"
        form.country = try XCTUnwrap(FigoCountry.find("GB"))
        form.mobilePhone = "07700 900123"
        form.submit()
    }

    func testWithoutNameEmailAndPhoneTheChatAsksForThemAndTheFirstMessageWaitsForTheForm() async throws {
        try initializeAnonymous(firstCustomerMessage: "Where is my order?", defaultCountry: "NG")
        let screen = FigoChatViewModel()
        XCTAssertTrue(FigoChat.needsDetails)
        XCTAssertTrue(screen.needsDetails)
        XCTAssertNil(FigoChat.firstExchange)
        let form = FigoDetailsFormModel(defaultCountry: try FigoChat.config.defaultCountry)
        XCTAssertEqual(form.countryLabel, "🇳🇬 +234")
        XCTAssertGreaterThan(FigoCountry.all.count, 200)
        await waitUntil { FigoChat.assistantInfo != nil }
        XCTAssertEqual(chatCalls.count, 0, "not sent before the form")

        // validation
        form.submit()
        XCTAssertEqual(form.error, "Please enter your full name.")
        form.fullName = "Ada Lovelace"
        form.emailAddress = "ada@"
        form.submit()
        XCTAssertEqual(form.error, "Please enter a valid email address.")
        form.emailAddress = "ada@example.com"
        form.mobilePhone = "12"
        form.submit()
        XCTAssertEqual(form.error, "Please enter a valid phone number.")
        XCTAssertTrue(FigoChat.needsDetails)

        // a GB number typed with its trunk 0
        form.country = try XCTUnwrap(FigoCountry.find("GB"))
        XCTAssertEqual(form.countryLabel, "🇬🇧 +44")
        form.mobilePhone = "07700 900123"
        form.submit()
        XCTAssertNil(form.error)

        XCTAssertFalse(FigoChat.needsDetails)
        await waitUntil { !screen.needsDetails }
        let details = FigoCustomerDetails(fullName: "Ada Lovelace", emailAddress: "ada@example.com", mobilePhone: "+447700900123")
        XCTAssertEqual(FigoChat.customerDetails, details)
        await waitUntil { FigoChat.firstExchange?.done == true }
        let chat = try XCTUnwrap(chatCalls.first)
        XCTAssertEqual(chat.body as NSDictionary?, [
            "question": "Where is my order?", "fullName": "Ada Lovelace", "emailAddress": "ada@example.com", "phoneNumber": "+447700900123",
        ])
        XCTAssertNil(try savedDetails(), "form details stay in memory")
        XCTAssertNil(storage.dictionaryRepresentation().keys.first { $0.hasPrefix("figochat.") })
    }

    func testTheCountryIsTheDefaultCountryWhenKnownElseNigeria() {
        XCTAssertEqual(FigoCountry.preferred(nil).code, "NG")
        XCTAssertEqual(FigoCountry.preferred("").code, "NG")
        XCTAssertEqual(FigoCountry.preferred("XX").code, "NG")
        XCTAssertEqual(FigoCountry.preferred(" gb \n").code, "GB")
        XCTAssertEqual(FigoDetailsFormModel(defaultCountry: nil).country.code, "NG")
        XCTAssertEqual(FigoDetailsFormModel(defaultCountry: "us").country.code, "US")
    }

    func testConsentIsAskedOnlyWhenTheCompanyHasBothTermsAndAPrivacyPolicy() {
        func links(_ terms: String?, _ privacy: String?) -> FigoConsentLinks? {
            FigoAssistantInfo(company: FigoCompanyInfo(termsAndCondition: terms, privacyPolicy: privacy)).consentLinks
        }
        XCTAssertNil(FigoAssistantInfo().consentLinks)
        XCTAssertNil(links("https://x.io/terms", nil))
        XCTAssertNil(links(nil, "https://x.io/privacy"))
        XCTAssertNil(links("https://x.io/terms", "   "))
        XCTAssertEqual(links(" https://x.io/terms ", "Our privacy policy"), FigoConsentLinks(terms: "https://x.io/terms", privacy: "Our privacy policy"))

        let consent = FigoConsentLinks(terms: "https://x.io/terms", privacy: "Our privacy policy")
        XCTAssertEqual(consent.termsURL, URL(string: "https://x.io/terms"))
        XCTAssertNil(consent.privacyURL, "not a link: plain text")
        XCTAssertNil(FigoConsentLinks.webURL("javascript:alert(1)"))
        XCTAssertNil(FigoConsentLinks.webURL("mailto:a@b.c"))

        let text = FigoConsentRow.text(consent, linkColor: .orange)
        XCTAssertEqual(String(text.characters), "I have read and agreed to the Terms, conditions, and privacy policy")
        XCTAssertEqual(FigoConsentRow.label, String(text.characters))
        let linked = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0) } }
        XCTAssertEqual(linked.map(\.0), ["Terms, conditions"])
        XCTAssertEqual(linked.map(\.1), [URL(string: "https://x.io/terms")!])
    }

    func testStartChatWaitsForConsentThatArrivesWithTheAssistantDetails() async throws {
        FakeAPI.reset(assistant: ["persona": "Dave", "company": ["termsAndCondition": "https://x.io/terms", "privacyPolicy": "https://x.io/privacy"]])
        try initializeAnonymous()
        let form = FigoDetailsFormModel(defaultCountry: nil) // shown before the details load
        XCTAssertNil(form.consent)
        await waitUntil { form.consent != nil }
        XCTAssertEqual(form.consent, FigoConsentLinks(terms: "https://x.io/terms", privacy: "https://x.io/privacy"))
        XCTAssertFalse(form.canSubmit)

        try fillAndSubmit(form)
        XCTAssertTrue(FigoChat.needsDetails, "not started without consent")
        form.agreed = true
        XCTAssertTrue(form.canSubmit)
        form.submit()
        XCTAssertFalse(FigoChat.needsDetails)
    }

    func testSkipStaysAvailableWithoutConsent() async throws {
        FakeAPI.reset(assistant: ["company": ["termsAndCondition": "https://x.io/terms", "privacyPolicy": "https://x.io/privacy"]])
        try initializeAnonymous()
        await waitUntil { FigoChat.assistantInfo != nil }
        let form = FigoDetailsFormModel(defaultCountry: nil)
        XCTAssertFalse(form.canSubmit)
        form.skip()
        XCTAssertFalse(FigoChat.needsDetails)
    }

    func testDetailsAreKeptInMemoryForTheSessionNotOnTheDeviceAndLogoutForgetsThem() async throws {
        // what an older version saved is removed on initialize
        storage.set(try JSONEncoder().encode(FigoCustomerDetails(fullName: "Old", emailAddress: "old@x.io", mobilePhone: "+1")), forKey: "figochat.details.asst-1")
        try initializeAnonymous()
        XCTAssertNil(storage.data(forKey: "figochat.details.asst-1"))
        XCTAssertTrue(FigoChat.needsDetails, "the old saved details aren't used")

        try fillAndSubmit(FigoDetailsFormModel(defaultCountry: nil))
        XCTAssertNil(try savedDetails())

        try initializeAnonymous() // e.g. opening the chat again later in the same run
        XCTAssertFalse(FigoChat.needsDetails)
        XCTAssertEqual(FigoChat.customerDetails.emailAddress, "ada@example.com")
        XCTAssertEqual(try FigoChat.config.mobilePhone, "+447700900123")
        XCTAssertNil(try savedDetails())

        FigoChat.logout()
        try initializeAnonymous()
        XCTAssertTrue(FigoChat.needsDetails)

        // a new app run starts with nothing (in-memory only)
        try fillAndSubmit(FigoDetailsFormModel(defaultCountry: nil))
        FigoChat.forgetSessionsForTesting()
        try initializeAnonymous()
        XCTAssertTrue(FigoChat.needsDetails)
        XCTAssertEqual(FigoChat.customerDetails, FigoCustomerDetails())
    }

    func testAfterAnHourWithoutActivityTheThreadAndDetailsAreForgottenAndTheFormIsShownAgain() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        FigoChat.clock = { now }
        try initializeAnonymous()
        let screen = FigoChatViewModel()
        try fillAndSubmit(FigoDetailsFormModel(defaultCountry: nil))
        _ = try await FigoChat.client.sendMessage("Hello")
        XCTAssertEqual(FigoChat.threadId, "thread-42")
        screen.messages = [FigoChatMessage(id: "m1", role: .user, text: "Hello")]

        now += FigoChat.sessionLifetime - 1
        XCTAssertFalse(FigoChat.expireSessionIfNeeded())
        XCTAssertEqual(FigoChat.threadId, "thread-42")

        now += 1
        XCTAssertTrue(FigoChat.expireSessionIfNeeded())
        XCTAssertNil(FigoChat.threadId)
        XCTAssertEqual(FigoChat.customerDetails, FigoCustomerDetails())
        XCTAssertTrue(FigoChat.needsDetails)
        XCTAssertNil(FigoChat.firstExchange)
        XCTAssertTrue(screen.needsDetails)
        XCTAssertTrue(screen.messages.isEmpty)
        XCTAssertFalse(FigoChat.expireSessionIfNeeded(), "nothing left to expire")

        // the next message goes without the old details or thread
        try fillAndSubmit(FigoDetailsFormModel(defaultCountry: nil))
        _ = try await FigoChat.client.sendMessage("Hi again")
        XCTAssertNil(chatCalls.last?.body?["threadId"])

        // initialize after an hour also starts over
        now += FigoChat.sessionLifetime
        try initializeAnonymous()
        XCTAssertTrue(FigoChat.needsDetails)
        XCTAssertNil(FigoChat.threadId)
    }

    func testActivityKeepsTheSessionAliveAndInitializeContinuesIt() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        FigoChat.clock = { now }
        try initializeAnonymous()
        try fillAndSubmit(FigoDetailsFormModel(defaultCountry: nil))
        _ = try await FigoChat.client.sendMessage("Hello")

        now += 50 * 60
        _ = try await FigoChat.client.sendMessage("Still there?") // a message sent and its reply
        now += 50 * 60
        FigoChat.noteActivity() // a live agent message
        now += 50 * 60
        XCTAssertFalse(FigoChat.expireSessionIfNeeded())

        try initializeAnonymous() // the same visitor opens the chat again within the hour
        XCTAssertFalse(FigoChat.needsDetails)
        XCTAssertEqual(FigoChat.threadId, "thread-42")
        XCTAssertEqual(FigoChat.customerDetails.fullName, "Ada Lovelace")

        now += FigoChat.sessionLifetime
        XCTAssertTrue(FigoChat.expireSessionIfNeeded())
        XCTAssertTrue(FigoChat.needsDetails)
    }

    func testExpiryKeepsDetailsTheAppPassedAndDoesNotAskForThem() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        FigoChat.clock = { now }
        try FigoChat.initialize(apiKey: "k", fullName: "Ada", emailAddress: "a@b.c", mobilePhone: "+1", assistantId: "asst-1", primaryColor: "#F97316")
        _ = try await FigoChat.client.sendMessage("Hello")
        now += FigoChat.sessionLifetime
        XCTAssertTrue(FigoChat.expireSessionIfNeeded())
        XCTAssertNil(FigoChat.threadId)
        XCTAssertFalse(FigoChat.needsDetails)
        XCTAssertEqual(FigoChat.customerDetails, FigoCustomerDetails(fullName: "Ada", emailAddress: "a@b.c", mobilePhone: "+1"))
    }

    func testSkippingChatsWithoutDetailsAndIsRememberedForThisRun() async throws {
        try initializeAnonymous(firstCustomerMessage: "Hi")
        XCTAssertTrue(FigoChat.needsDetails)
        FigoDetailsFormModel(defaultCountry: nil).skip()
        XCTAssertFalse(FigoChat.needsDetails)
        await waitUntil { FigoChat.firstExchange?.done == true }
        let chat = try XCTUnwrap(chatCalls.first)
        XCTAssertEqual(chat.body as NSDictionary?, ["question": "Hi", "fullName": "", "emailAddress": "", "phoneNumber": ""])
        XCTAssertTrue(FigoChat.hasSkippedDetails("asst-1"))
        XCTAssertNil(try savedDetails())

        try initializeAnonymous() // e.g. opening the chat again later in the same run
        XCTAssertFalse(FigoChat.needsDetails)
        FigoChat.clock = { Date() + FigoChat.sessionLifetime }
        XCTAssertTrue(FigoChat.expireSessionIfNeeded())
        XCTAssertTrue(FigoChat.needsDetails, "the skip ends with the session")
        XCTAssertFalse(FigoChat.hasSkippedDetails("asst-1"))
        FigoChat.clock = { Date() }
        FigoDetailsFormModel(defaultCountry: nil).skip()
        FigoChat.logout()
        XCTAssertFalse(FigoChat.hasSkippedDetails("asst-1"))
    }

    func testSetCustomerDetailsOrAskForDetailsFalseAvoidTheForm() async throws {
        try initializeAnonymous()
        XCTAssertTrue(FigoChat.needsDetails)
        FigoChat.setCustomerDetails(fullName: " Grace ", emailAddress: "g@x.io", mobilePhone: "+15550100")
        XCTAssertFalse(FigoChat.needsDetails)
        XCTAssertEqual(FigoChat.customerDetails, FigoCustomerDetails(fullName: "Grace", emailAddress: "g@x.io", mobilePhone: "+15550100"))
        XCTAssertNil(try savedDetails(), "only the form remembers details")

        _ = try await FigoChat.client.sendMessage("Hello")
        XCTAssertEqual(chatCalls.last?.body?["fullName"] as? String, "Grace")
        XCTAssertEqual(chatCalls.last?.body?["phoneNumber"] as? String, "+15550100")

        reset()
        try initializeAnonymous(askForDetails: false)
        XCTAssertFalse(FigoChat.needsDetails)
        XCTAssertEqual(FigoChat.customerDetails, FigoCustomerDetails())
    }
}

// MARK: - Conversation history, against a fake API

@MainActor
final class HistoryTests: XCTestCase {
    private let history: [[String: Any]] = [
        ["role": "user", "message": "Where is my order?", "isLiveAgent": false, "dateCreated": "2026-11-28T09:15:02.1234567"],
        ["role": "assistant", "message": "<p>It ships <b>today</b></p>", "isLiveAgent": false, "dateCreated": "2026-11-28T09:15:04Z"],
        ["role": "assistant", "message": "Hi, Sam here", "isLiveAgent": true, "dateCreated": "2026-11-28T10:15:05.5+01:00"],
    ]

    override func setUp() {
        super.setUp()
        FigoChatClient.protocolClassesForTesting = [FakeAPI.self]
        FakeAPI.reset()
        FigoChat.forgetSessionsForTesting()
    }

    override func tearDown() {
        FigoChat.logout()
        FigoChatClient.protocolClassesForTesting = nil
        super.tearDown()
    }

    private func initialize(threadId: String? = "thread-42", firstCustomerMessage: String? = nil) throws {
        try FigoChat.initialize(
            apiKey: "k", fullName: "Ada", emailAddress: "a@b.c", mobilePhone: "+1", assistantId: "asst-1",
            primaryColor: "#F97316", firstCustomerMessage: firstCustomerMessage, threadId: threadId
        )
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testGetMessagesDecodesTheThreadOldestFirst() async throws {
        FakeAPI.reset(history: history)
        try initialize()
        let messages = try await FigoChat.client.getMessages()
        let call = try XCTUnwrap(FakeAPI.calls.first { $0.url.contains("/chat/messages/") })
        XCTAssertEqual(call.url, "https://api.figolabs.ai/api/v1/chat/messages/asst-1/thread-42")
        XCTAssertEqual(call.method, "GET")
        XCTAssertEqual(call.auth, "Bearer k")

        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .assistant])
        XCTAssertEqual(messages.map(\.text), ["Where is my order?", "<p>It ships <b>today</b></p>", "Hi, Sam here"])
        XCTAssertEqual(messages.map(\.status), [.sent, .sent, .sent])
        XCTAssertEqual(Set(messages.map(\.id)).count, 3)
        let base = Date(timeIntervalSince1970: 1_795_857_300) // 2026-11-28T09:15:00Z
        XCTAssertEqual(messages[0].createdAt.timeIntervalSince(base), 2.1234567, accuracy: 0.001)
        XCTAssertEqual(messages[1].createdAt.timeIntervalSince(base), 4, accuracy: 0.001)
        XCTAssertEqual(messages[2].createdAt.timeIntervalSince(base), 5.5, accuracy: 0.001)
    }

    func testGetMessagesIsEmptyForAnUnknownThreadOrNoThread() async throws {
        FakeAPI.reset(history: nil) // 404
        try initialize()
        let unknown = try await FigoChat.client.getMessages()
        XCTAssertEqual(unknown, [])

        try initialize(threadId: nil)
        let none = try await FigoChat.client.getMessages()
        XCTAssertEqual(none, [])
        XCTAssertFalse(FakeAPI.calls.contains { $0.url.contains("/chat/messages/") && !$0.url.hasSuffix("thread-42") })
    }

    func testGetMessagesThrowsOtherFailures() async throws {
        FakeAPI.reset(offline: true)
        try initialize()
        do {
            _ = try await FigoChat.client.getMessages()
            XCTFail("expected an error")
        } catch let error as FigoChatError {
            XCTAssertEqual(error.code, "NETWORK")
        }
    }

    func testDatesAreParsedLeniently() {
        let base = Date(timeIntervalSince1970: 1_795_857_300)
        XCTAssertEqual(parseAPIDate("2026-11-28T09:15:00"), base)
        XCTAssertEqual(parseAPIDate("2026-11-28 09:15"), base)
        XCTAssertEqual(parseAPIDate("2026-11-28T09:15:00Z"), base)
        XCTAssertEqual(parseAPIDate("2026-11-28T04:15:00-0500"), base)
        XCTAssertEqual(parseAPIDate("2026-11-28T09:15:00.25")?.timeIntervalSince(base) ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertNil(parseAPIDate("yesterday"))
        XCTAssertNil(parseAPIDate(nil))
    }

    func testTheChatShowsTheThreadsHistoryWhenItOpensOnAnActiveThread() async throws {
        FakeAPI.reset(history: history)
        try initialize()
        let screen = FigoChatViewModel()
        screen.appear()
        await waitUntil { screen.restoredHistory }
        await waitUntil { FigoChat.assistantInfo != nil && screen.assistant != nil }
        XCTAssertEqual(screen.displayMessages.map(\.id).first, "welcome", "the intro stays first")
        XCTAssertEqual(screen.displayMessages.dropFirst().map(\.text), ["Where is my order?", "<p>It ships <b>today</b></p>", "Hi, Sam here"])
        screen.disappear()

        // opened again later: fetched again into the new screen
        let again = FigoChatViewModel()
        again.appear()
        await waitUntil { again.restoredHistory }
        XCTAssertEqual(again.messages.count, 3)
        again.disappear()
    }

    func testTheHistoryReplacesTheFirstExchangeAndAFailedFetchChangesNothing() async throws {
        FakeAPI.reset(history: history)
        try initialize(threadId: nil, firstCustomerMessage: "Where is my order?")
        await waitUntil { FigoChat.firstExchange?.done == true }
        let screen = FigoChatViewModel()
        screen.appear()
        await waitUntil { screen.restoredHistory }
        XCTAssertFalse(screen.displayMessages.contains { $0.id.hasPrefix("first-") })
        XCTAssertEqual(screen.displayMessages.filter { $0.text == "Where is my order?" }.count, 1)
        screen.disappear()

        FakeAPI.reset(offline: true)
        let offline = FigoChatViewModel()
        offline.appear()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(offline.restoredHistory)
        XCTAssertTrue(offline.messages.isEmpty)
        XCTAssertTrue(offline.displayMessages.contains { $0.id.hasPrefix("first-") }, "the first exchange still shows")
        offline.disappear()
    }
}
