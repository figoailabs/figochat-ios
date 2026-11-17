import FigoChat
import SwiftUI

/// Example host app for the FigoChat iOS SDK.
/// Pass the key and assistant id as environment variables (Xcode scheme → Run → Arguments, or
/// `SIMCTL_CHILD_FIGO_API_KEY=... xcrun simctl launch ...`). Without them the chat opens and messages fail.
@main
struct FigoChatExampleApp: App {
    @State private var setupError: String?

    init() {
        let env = ProcessInfo.processInfo.environment
        do {
            try FigoChat.initialize(
                apiKey: env["FIGO_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? "missing-api-key",
                fullName: "Ada Lovelace",
                emailAddress: "ada@example.com",
                mobilePhone: "+2348012345678",
                assistantId: env["FIGO_ASSISTANT_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "missing-assistant-id",
                primaryColor: "#F97316",
                title: "Support",
                welcomeMessage: "<p><b>Hi Ada!</b> How can I help you today?</p><ul><li>Buy airtime or data</li><li>Pay bills</li></ul><p>Visit <a href=\"https://figolabs.ai\">our site</a>.</p>"
            )
        } catch {
            _setupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(setupError: setupError, hasKey: !(ProcessInfo.processInfo.environment["FIGO_API_KEY"] ?? "").isEmpty)
        }
    }
}

struct ContentView: View {
    let setupError: String?
    let hasKey: Bool
    @State private var showChat = false

    var body: some View {
        VStack(spacing: 16) {
            Text("My App").font(.largeTitle.bold())
            Text("FigoChat iOS SDK example").foregroundColor(.secondary)
            if let setupError {
                Text(setupError).foregroundColor(.red).multilineTextAlignment(.center)
            } else if !hasKey {
                Text("No FIGO_API_KEY set: messages will fail.").font(.footnote).foregroundColor(.red)
            }
            Button("Chat with us") { showChat = true }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.98, green: 0.45, blue: 0.09))
                .disabled(setupError != nil)
        }
        .padding(24)
        .fullScreenCover(isPresented: $showChat) {
            FigoChatView(onClose: { showChat = false })
        }
    }
}
