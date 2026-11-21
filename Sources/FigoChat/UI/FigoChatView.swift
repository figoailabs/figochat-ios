import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

let bubbleGrey = Color(red: 0xF1 / 255, green: 0xF3 / 255, blue: 0xF5 / 255)
let textDark = Color(red: 0x1F / 255, green: 0x23 / 255, blue: 0x28 / 255)
let textMuted = Color(red: 0x6B / 255, green: 0x72 / 255, blue: 0x80 / 255)
let errorRed = Color(red: 0xD9 / 255, green: 0x30 / 255, blue: 0x25 / 255)

/// The FigoChat chat screen: message list, text input, voice notes and file attachments.
/// Call `FigoChat.initialize(...)` before showing it. For an anonymous visitor it first shows a form asking for their
/// name, email and phone (see `askForDetails` on `FigoChat.initialize`).
public struct FigoChatView: View {
    private let onClose: (() -> Void)?
    private let showHeader: Bool
    private let placeholder: String
    private let enableVoice: Bool
    private let enableAttachments: Bool
    private let onError: ((FigoChatError) -> Void)?

    @StateObject private var vm = FigoChatViewModel()
    @State private var initialized = FigoChat.isInitialized
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @FocusState private var inputFocused: Bool
    /// Changed after each send so the multi-line field is rebuilt and shrinks back to one line.
    @State private var inputGeneration = 0

    /// - Parameters:
    ///   - onClose: shows a close button in the header and is called when it is pressed
    ///   - showHeader: hide the header if the host app draws its own
    ///   - onError: called with every error the screen shows, for logging
    public init(
        onClose: (() -> Void)? = nil,
        showHeader: Bool = true,
        placeholder: String = "Type a message",
        enableVoice: Bool = true,
        enableAttachments: Bool = true,
        onError: ((FigoChatError) -> Void)? = nil
    ) {
        self.onClose = onClose
        self.showHeader = showHeader
        self.placeholder = placeholder
        self.enableVoice = enableVoice
        self.enableAttachments = enableAttachments
        self.onError = onError
    }

    public var body: some View {
        Group {
            if initialized, let config = try? FigoChat.config {
                chat(config: config)
            } else {
                Text("FigoChat is not initialized. Call FigoChat.initialize(...) first.")
                    .foregroundColor(textMuted)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white)
        .onReceive(FigoChat.changes) { initialized = FigoChat.isInitialized }
    }

    private func chat(config: FigoChatConfig) -> some View {
        let primary = Color(hex: config.primaryColor)
        let onPrimary = Color.contrasting(hex: config.primaryColor)

        return VStack(spacing: 0) {
            if showHeader { header(title: vm.title, primary: primary, onPrimary: onPrimary) }

            if vm.needsDetails {
                // anonymous visitor: the details form replaces the conversation until it's submitted or skipped
                FigoDetailsFormView(defaultCountry: config.defaultCountry, primary: primary, onPrimary: onPrimary)
                    .frame(maxHeight: .infinity)
            } else {
                conversation(config: config, primary: primary, onPrimary: onPrimary)
            }

            Text(poweredBy)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#9AA0A6"))
                .tint(Color(hex: "#9AA0A6"))
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .padding(.bottom, 6)
        }
        .onAppear {
            vm.onError = onError
            vm.appear()
        }
        .onDisappear { vm.disappear() }
    }

    /// Messages, notices, pending files and the input (or recording) bar.
    @ViewBuilder
    private func conversation(config: FigoChatConfig, primary: Color, onPrimary: Color) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(vm.displayMessages) { message in
                                MessageBubble(message: message, primary: primary, onPrimary: onPrimary) { vm.retry(message) }
                                    .id(message.id)
                            }
                            if vm.waiting { WaitingBubble(text: vm.waitingText).id("typing") }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(12)
                        // at least as tall as the visible area, aligned to the bottom: a short conversation
                        // sits just above the input instead of under the header
                        .frame(minHeight: geo.size.height, alignment: .bottom)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    // tapping the conversation closes the keyboard; simultaneous so links and "retry" still work
                    .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
                    .onChange(of: vm.displayMessages.count) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: vm.waiting) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            if let notice = vm.notice {
                Text(notice)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.2)))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            if !vm.pending.isEmpty { pendingRow(primary: primary) }
            Divider()

            if vm.recording || vm.transcribing {
                recordingBar(primary: primary, onPrimary: onPrimary)
            } else {
                inputBar(primary: primary, onPrimary: onPrimary)
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: max(1, config.maxFiles - vm.pending.count), matching: .images)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            vm.addPhotos(items)
            photoItems = []
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): vm.addFiles(urls)
            case .failure(let error): vm.showNotice(friendlyMessage(error, context: .upload))
            }
        }
    }

    private func header(title: String, primary: Color, onPrimary: Color) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(onPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !vm.needsDetails {
                Button(action: vm.newConversation) {
                    Image(systemName: "arrow.clockwise").foregroundColor(onPrimary)
                }
                .accessibilityLabel("New conversation")
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").foregroundColor(onPrimary)
                }
                .accessibilityLabel("Close chat")
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(primary.ignoresSafeArea(edges: .top))
    }

    private func pendingRow(primary: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vm.pending) { file in
                    HStack(spacing: 6) {
                        if file.uploading { ProgressView().tint(primary).scaleEffect(0.6).frame(width: 12, height: 12) }
                        Text(file.failed ? "Failed: \(file.name)" : file.name)
                            .font(.system(size: 12))
                            .foregroundColor(textDark)
                            .lineLimit(1)
                            .frame(maxWidth: 160)
                        Button { vm.removePending(file.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(textMuted)
                        }
                        .accessibilityLabel("Remove \(file.name)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(file.failed ? Color(red: 0.99, green: 0.93, blue: 0.92) : bubbleGrey))
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
    }

    private func inputBar(primary: Color, onPrimary: Color) -> some View {
        let hasText = !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = !vm.waiting && (hasText || vm.pending.contains { $0.url != nil && !$0.failed })
        let showMic = enableVoice && !canSend && !hasText

        return HStack(alignment: .bottom, spacing: 8) {
            if enableAttachments {
                Menu {
                    Button { showPhotos = true } label: { Label("Photo library", systemImage: "photo") }
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 20)).foregroundColor(textMuted).frame(width: 40, height: 40)
                }
                .disabled(vm.waiting)
                .accessibilityLabel("Attach files")
            }

            TextField(placeholder, text: $vm.input, axis: .vertical)
                .focused($inputFocused)
                .id(inputGeneration)
                .lineLimit(1...5)
                .font(.system(size: 15))
                .foregroundColor(textDark)
                .tint(primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20).fill(bubbleGrey))

            RoundButton(color: primary, enabled: showMic ? !vm.waiting : canSend) {
                if showMic {
                    inputFocused = false
                    vm.startRecording()
                } else {
                    vm.send()
                    inputGeneration += 1
                    inputFocused = true
                }
            } label: {
                Image(systemName: showMic ? "mic.fill" : "paperplane.fill").foregroundColor(onPrimary)
            }
            .accessibilityLabel(showMic ? "Record a voice message" : "Send message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func recordingBar(primary: Color, onPrimary: Color) -> some View {
        HStack(spacing: 10) {
            if vm.transcribing {
                ProgressView().tint(primary)
                Text("Processing your voice message…").font(.system(size: 15)).foregroundColor(textDark)
                Spacer()
            } else {
                Circle().fill(errorRed).frame(width: 10, height: 10)
                Text(String(format: "Recording %d:%02d", vm.recordingSeconds / 60, vm.recordingSeconds % 60))
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundColor(textDark)
                Spacer()
                Button("Cancel") { vm.stopRecording(discard: true) }.foregroundColor(textMuted)
                RoundButton(color: primary) { vm.stopRecording() } label: {
                    RoundedRectangle(cornerRadius: 2).fill(onPrimary).frame(width: 14, height: 14)
                }
                .accessibilityLabel("Stop recording and send")
            }
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct RoundButton<Label: View>: View {
    let color: Color
    var enabled = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label().frame(width: 40, height: 40).background(Circle().fill(color))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct MessageBubble: View {
    let message: FigoChatMessage
    let primary: Color
    let onPrimary: Color
    let onRetry: () -> Void

    var body: some View {
        if message.role == .system {
            Text(message.text)
                .font(.system(size: 12))
                .foregroundColor(Color(red: 0.70, green: 0.15, blue: 0.12))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.99, green: 0.93, blue: 0.92)))
                .frame(maxWidth: .infinity)
        } else {
            let mine = message.role == .user
            let textColor = mine ? onPrimary : textDark
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.attachments) { AttachmentView(attachment: $0, color: textColor) }
                    Text(richText(mine ? plainToRuns(message.text) : htmlToRuns(message.text), linkColor: mine ? onPrimary : primary))
                        .font(.system(size: 15))
                        .foregroundColor(textColor)
                        .tint(mine ? onPrimary : primary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    BubbleShape(bottomLeading: mine ? 18 : 4, bottomTrailing: mine ? 4 : 18)
                        .fill(mine ? primary : bubbleGrey)
                )

                if mine && message.status == .sending {
                    Text("Sending…").font(.system(size: 11)).foregroundColor(textMuted)
                }
                if mine && message.status == .error {
                    Button("Not sent. Tap to retry", action: onRetry).font(.system(size: 11)).foregroundColor(errorRed)
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        }
    }
}

private struct AttachmentView: View {
    let attachment: FigoAttachment
    let color: Color
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: attachment.url) { openURL(url) }
        } label: {
            if attachment.isImage {
                Group {
                    if let data = attachment.data, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        AsyncImage(url: URL(string: attachment.url)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.black.opacity(0.06)
                        }
                    }
                }
                .frame(width: 200, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "doc").font(.system(size: 14))
                    Text(attachment.name).font(.system(size: 13)).lineLimit(1)
                }
                .foregroundColor(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.5), lineWidth: 0.5))
                .frame(maxWidth: 240, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Shown on the left while a reply is on its way: the assistant's waiting message followed by animated dots, or
/// just the dots when there is no waiting message.
private struct WaitingBubble: View {
    let text: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let dots = String(repeating: "•", count: Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3 + 1)
            Group {
                if let text {
                    (Text(text).italic().foregroundColor(textMuted)
                        + Text(" " + dots).foregroundColor(Color(hex: "#9AA0A6")))
                        .font(.system(size: 15))
                        .accessibilityLabel(text)
                } else {
                    Text(dots)
                        .font(.system(size: 15))
                        .foregroundColor(textMuted)
                        .frame(width: 24, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                BubbleShape(bottomLeading: 4, bottomTrailing: 18)
                    .fill(bubbleGrey)
            )
            .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Rounded rectangle with 18pt top corners and its own bottom corners (the "tail" corner is tighter).
private struct BubbleShape: Shape {
    var top: CGFloat = 18
    let bottomLeading: CGFloat
    let bottomTrailing: CGFloat

    func path(in rect: CGRect) -> Path {
        let tl = min(top, rect.height / 2), tr = tl
        let bl = min(bottomLeading, rect.height / 2), br = min(bottomTrailing, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        p.closeSubpath()
        return p
    }
}

/// Footer: "Powered by Figo AI Labs", with "Figo AI Labs" linking to https://figolabs.ai.
private let poweredBy: AttributedString = {
    var link = AttributedString("Figo AI Labs")
    link.link = URL(string: "https://figolabs.ai")
    link.foregroundColor = Color(hex: "#9AA0A6")
    link.underlineStyle = .single
    return AttributedString("Powered by ") + link
}()

/// Builds the bubble text from styled runs: assistant and agent messages come from `htmlToRuns(_:)` (bold, italics,
/// underline, lists, tappable links), text the user typed from `plainToRuns(_:)` (only urls are tappable).
func richText(_ runs: [FigoTextRun], linkColor: Color) -> AttributedString {
    var result = AttributedString()
    for run in runs {
        var part = AttributedString(run.text)
        var intent: InlinePresentationIntent = []
        if run.bold { intent.insert(.stronglyEmphasized) }
        if run.italic { intent.insert(.emphasized) }
        if !intent.isEmpty { part.inlinePresentationIntent = intent }
        if run.underline { part.underlineStyle = .single }
        if let link = run.link, let url = URL(string: link) {
            part.link = url
            part.foregroundColor = linkColor
            part.underlineStyle = .single
        }
        result += part
    }
    return result
}

extension Color {
    /// Parses #RGB, #RRGGBB or #RRGGBBAA.
    init(hex: String) {
        let (r, g, b, a) = Color.components(hex: hex)
        self.init(red: r, green: g, blue: b, opacity: a)
    }

    /// Black or white, whichever reads better on the given background.
    static func contrasting(hex: String) -> Color {
        let (r, g, b, _) = components(hex: hex)
        let lin: (Double) -> Double = { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return luminance > 0.45 ? Color(red: 0.07, green: 0.07, blue: 0.07) : .white
    }

    fileprivate static func components(hex: String) -> (Double, Double, Double, Double) {
        var h = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let value = UInt64(h, radix: 16) else { return (0.15, 0.39, 0.92, 1) }
        if h.count == 6 {
            return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255, 1)
        }
        return (Double((value >> 24) & 0xFF) / 255, Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
