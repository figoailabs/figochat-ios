# FigoChat SDK for iOS

Native iOS (Swift, SwiftUI) SDK for chatting with a Figo AI assistant. Users can type, send voice notes and upload photos or files (images are read with OCR), and see live agent replies. The screen uses your brand color. It works in both SwiftUI and UIKit apps.

- **iOS 16+**
- **Swift Package Manager**
- **Depends on:** [PusherSwift](https://github.com/pusher/pusher-websocket-swift)

## What's new

### 2.3.0

- **Consent checkbox:** when the company has both Terms and conditions and a Privacy policy set in the FigoChat admin, the details form shows "I have read and agreed to the Terms, conditions, and privacy policy" with a checkbox. "Terms, conditions" and "privacy policy" open their pages (when they're web links), and **Start chat** stays disabled until the box is checked. **Skip** still works. With only one of the two set, there's no checkbox.
- **Disclaimer:** the chatbot's disclaimer (for example "AI can make mistakes. Double-check sensitive information") is shown in small grey text above the "Powered by Figo AI Labs" footer, on the chat and the details form.
- **Nigeria is the default country:** the phone field preselects `defaultCountry` (an ISO code such as `GB`, any case) when it's valid, otherwise Nigeria (`NG`). The device region is no longer used.
- `FigoAssistantInfo` has new `disclaimerMessage` and `company` (`termsAndCondition`, `privacyPolicy`) fields.

## Install

The SDK is open source at [github.com/figoailabs/figochat-ios](https://github.com/figoailabs/figochat-ios).

In Xcode, choose **File → Add Package Dependencies…**, enter `https://github.com/figoailabs/figochat-ios`, choose **Up to Next Major Version** from `2.0.0`, and add the `FigoChat` library to your app target.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/figoailabs/figochat-ios.git", from: "2.3.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "FigoChat", package: "figochat-ios")]),
]
```

Add the microphone usage description to your app's `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Record voice messages for chat.</string>
```

The photo picker and the file importer don't need extra permissions.

## Initialize

```swift
import FigoChat

try FigoChat.initialize(
    apiKey: "YOUR_API_KEY",
    fullName: "Ada Lovelace",
    emailAddress: "ada@example.com",
    mobilePhone: "+2348012345678",
    assistantId: "YOUR_ASSISTANT_ID",
    primaryColor: "#F97316",
    // optional: send the customer's first question for them
    firstCustomerMessage: "Where is my order #1042?"
)
```

The header title, welcome message and waiting message come from the chatbot's settings in the FigoChat admin (**AI Chatbots** → your chatbot → **Edit**: **Persona** or **Name**, **Welcome Message**, **Choose a Waiting Message**), so they aren't passed to `initialize`. `firstCustomerMessage` is sent for the customer straight away; the chat opens with it and its reply, and continues the same thread.

`initialize` throws `FigoChatError` with code `CONFIG` if a required value is empty or the color isn't hex.

**Users you don't know:** leave `fullName`, `emailAddress` and `mobilePhone` out and the chat asks for them with a short form (name, email, phone with a searchable country-code picker) that the user can skip. Submitted details are used as if passed to `initialize` and remembered on the device (UserDefaults); `logout` forgets them. Set `askForDetails: false` to skip the form, `defaultCountry` to preselect a country (ISO code; Nigeria when unset or unknown), and call `setCustomerDetails` when the user signs in later. If the company has both Terms and conditions and a Privacy policy, the form asks the user to agree to them before **Start chat**. The chatbot's disclaimer, if set, appears above the footer.

## Show the chat

```swift
// SwiftUI
.fullScreenCover(isPresented: $showChat) {
    FigoChatView(onClose: { showChat = false })
}

// UIKit
FigoChat.present(from: self)
```

`FigoChatView` parameters: `onClose`, `showHeader`, `placeholder`, `enableVoice`, `enableAttachments`, `onError`. `FigoChatViewController` is the UIKit container if you want to push it yourself.

## Other calls

```swift
FigoChat.threadId             // save it to resume later via initialize(threadId:)
FigoChat.resetConversation()  // next message starts a new thread
FigoChat.logout()             // clear settings on sign-out

// Build your own UI
let reply = try await FigoChat.client.sendMessage("Hello")
let text = try await FigoChat.client.transcribe(audioFile: fileURL)
let urls = try await FigoChat.client.uploadFiles([FigoUploadFile(name: "receipt.jpg", data: data, mimeType: "image/jpeg")])
```

### Events

```swift
let token = FigoChat.addListener(
    onMessageSent: { text in /* the user's message, after the API accepts it */ },
    onMessageReceived: { text in /* assistant or live agent reply, HTML stripped */ }
)
// later
FigoChat.removeListener(token)
```

Both are called on the main thread. Listeners can be added before `initialize` and stay registered after `logout`.

### Formatted replies

Assistant replies arrive as HTML. The chat renders them natively as formatted text (bold, italics, underline, headings, lists, line breaks, tappable links), so users never see tags or markdown symbols. For your own UI, `htmlToRuns(html)` returns the same styled runs and `htmlToText(html)` returns plain text.

Errors are `FigoChatError` with a `code` (`401`, `49`, `TIMEOUT`, `NETWORK`, …). The chat screen never shows these technical messages to users. It shows friendly text instead, such as "Chat isn't available right now. Please try again later." for a bad key, no credits or a plan limit, and "You seem to be offline…" for network problems. `onError` still receives the full technical error for your logs. Apps with their own UI can use `friendlyMessage(error)`.

## Live agent messages

After the first reply, the chat subscribes to the Pusher channel named after the conversation's thread id. Messages a live agent sends from Tawk.to, Zoho SalesIQ or FreshChat appear on the left, like assistant replies. The Pusher key and cluster come from `GET /api/v1/realtime/config`. They're kept encrypted in memory with `FigoCrypto` (CryptoKit AES-256-GCM with a random per-session key) and decrypted only when subscribing.

## Example app

`Example/FigoChatExample.xcodeproj` is a small SwiftUI app that uses the package from this repository. Open it in Xcode, add `FIGO_API_KEY` and `FIGO_ASSISTANT_ID` under **Product → Scheme → Edit Scheme → Run → Environment Variables**, and run it on a simulator. Without them the chat still opens, and messages fail with the friendly "Chat isn't available right now" text.

## API key security

The API key ships inside your app, so anyone who unpacks the app can read it and call every API-key endpoint, spending the company's credits. Create a key just for the SDK under **API Keys** in the FigoChat admin ([app.figolabs.ai](https://app.figolabs.ai)). Keys expire 3 years after they're created. If a key leaks, delete it there and ship an update with a new key. For stronger protection, have your own backend issue short-lived keys and pass them to `initialize` after sign-in.
