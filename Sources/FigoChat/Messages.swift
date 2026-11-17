import Foundation

/// What the user was doing when the error happened; picks the fallback wording.
public enum FigoErrorContext { case chat, voice, recording, upload }

/// Turns an SDK error into a message that is safe to show to the app's users. Setup problems the user can't fix
/// (invalid or expired API key, no credits, plan limit) all read as "chat isn't available"; the technical message
/// stays on the error, which `onError` receives for logging.
public func friendlyMessage(_ error: Error, context: FigoErrorContext = .chat) -> String {
    switch (error as? FigoChatError)?.code {
    case "401", "403", "49", "CONFIG", "NOT_INITIALIZED":
        return "Chat isn't available right now. Please try again later."
    case "NETWORK":
        return "You seem to be offline. Check your internet connection and try again."
    case "TIMEOUT":
        return "This is taking longer than usual. Please try again."
    default:
        switch context {
        case .chat: return "Your message couldn't be sent. Please try again."
        case .voice: return "We couldn't process your voice message. Please try again."
        case .recording: return "The microphone couldn't start. Please try again."
        case .upload: return "We couldn't upload that file. Please try again."
        }
    }
}
