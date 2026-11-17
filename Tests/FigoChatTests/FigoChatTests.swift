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
