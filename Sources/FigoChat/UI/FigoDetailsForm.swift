import Combine
import SwiftUI

/// State and validation behind the details form shown to anonymous visitors before the chat.
@MainActor
final class FigoDetailsFormModel: ObservableObject {
    enum Field: Hashable { case fullName, emailAddress, mobilePhone }

    @Published var fullName = ""
    @Published var emailAddress = ""
    /// The local number as typed; the selected country's dialing code is added on submit.
    @Published var mobilePhone = ""
    @Published var country: FigoCountry
    @Published private(set) var error: String?
    /// The field the error is about, so the view can focus it.
    @Published private(set) var errorField: Field?
    /// The consent checkbox ("I have read and agreed to the Terms, conditions, and privacy policy").
    @Published var agreed = false
    /// Terms and privacy policy to agree to; nil (no checkbox) unless the assistant details carry both. The details
    /// can load after the form is shown, so this follows `FigoChat.changes`.
    @Published private(set) var consent: FigoConsentLinks?

    private var changes: AnyCancellable?

    init(defaultCountry: String?) {
        country = FigoCountry.preferred(defaultCountry)
        consent = FigoChat.assistantInfo?.consentLinks
        changes = FigoChat.changes.sink { [weak self] in
            self?.consent = FigoChat.assistantInfo?.consentLinks
        }
    }

    /// "Start chat" is enabled once the visitor has agreed, when there is something to agree to.
    var canSubmit: Bool { consent == nil || agreed }

    /// "🇳🇬 +234", as shown on the country button.
    var countryLabel: String { country.label }

    /// Checks the fields (name, then email, then phone) and returns the error message for the first bad one.
    static func validate(fullName: String, emailAddress: String, mobilePhone: String, country: FigoCountry) -> (FigoCustomerDetails?, String?, Field?) {
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = country.internationalNumber(mobilePhone.trimmingCharacters(in: .whitespacesAndNewlines))
        let national = phone.filter(\.isNumber).count - country.dial.count

        if name.count < 2 { return (nil, "Please enter your full name.", .fullName) }
        if email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#, options: .regularExpression) == nil {
            return (nil, "Please enter a valid email address.", .emailAddress)
        }
        if national < 6 || national > 14 { return (nil, "Please enter a valid phone number.", .mobilePhone) }
        return (FigoCustomerDetails(fullName: name, emailAddress: email, mobilePhone: phone), nil, nil)
    }

    /// "Start chat": validates, then saves the details for this assistant and starts the chat with them.
    func submit() {
        guard canSubmit else { return }
        let (details, message, field) = Self.validate(fullName: fullName, emailAddress: emailAddress, mobilePhone: mobilePhone, country: country)
        error = message
        errorField = field
        if let details { FigoChat.submitDetails(details) }
    }

    /// "Skip": chats without details.
    func skip() {
        error = nil
        errorField = nil
        FigoChat.skipDetails()
    }
}

/// Asks an anonymous visitor for their name, email and phone before the chat starts.
struct FigoDetailsFormView: View {
    let primary: Color
    let onPrimary: Color

    @StateObject private var form: FigoDetailsFormModel
    @FocusState private var focused: FigoDetailsFormModel.Field?
    @State private var pickingCountry = false

    init(defaultCountry: String?, primary: Color, onPrimary: Color) {
        self.primary = primary
        self.onPrimary = onPrimary
        _form = StateObject(wrappedValue: FigoDetailsFormModel(defaultCountry: defaultCountry))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Personalize your chat")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(textDark)
                    Text("Tell us a little about yourself so we can tailor this conversation to you.")
                        .font(.system(size: 14))
                        .foregroundColor(textMuted)
                }

                field("Full name") {
                    TextField("", text: $form.fullName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .fullName)
                        .onSubmit { focused = .emailAddress }
                        .modifier(FieldStyle(primary: primary, invalid: form.errorField == .fullName))
                }

                field("Email address") {
                    TextField("", text: $form.emailAddress)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .emailAddress)
                        .onSubmit { focused = .mobilePhone }
                        .modifier(FieldStyle(primary: primary, invalid: form.errorField == .emailAddress))
                }

                field("Phone number") {
                    HStack(spacing: 8) {
                        Button { pickingCountry = true } label: {
                            HStack(spacing: 4) {
                                Text(form.countryLabel).font(.system(size: 15)).foregroundColor(textDark)
                                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundColor(textMuted)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 10).fill(bubbleGrey))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Country code \(form.country.name) +\(form.country.dial)")

                        TextField("", text: $form.mobilePhone)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                            .focused($focused, equals: .mobilePhone)
                            .modifier(FieldStyle(primary: primary, invalid: form.errorField == .mobilePhone))
                    }
                }

                if let consent = form.consent {
                    FigoConsentRow(consent: consent, agreed: $form.agreed, primary: primary)
                }

                if let error = form.error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(errorRed)
                }

                Button {
                    form.submit()
                    focused = form.errorField
                } label: {
                    Text("Start chat")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(onPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 12).fill(primary))
                        .opacity(form.canSubmit ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!form.canSubmit)

                Button {
                    focused = nil
                    form.skip()
                } label: {
                    Text("Skip")
                        .font(.system(size: 15))
                        .foregroundColor(textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $pickingCountry) {
            FigoCountryPicker(selected: form.country, primary: primary) { form.country = $0 }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(textDark)
            content()
        }
    }
}

/// Checkbox for agreeing to the company's terms and privacy policy. "Terms, conditions" and "privacy policy" open
/// their pages when they are http(s) links, like the "Figo AI Labs" link in the footer.
struct FigoConsentRow: View {
    let consent: FigoConsentLinks
    @Binding var agreed: Bool
    let primary: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { agreed.toggle() } label: {
                Image(systemName: agreed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundColor(agreed ? primary : textMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FigoConsentRow.label)
            .accessibilityValue(agreed ? "Checked" : "Unchecked")
            .accessibilityAddTraits(agreed ? [.isButton, .isSelected] : .isButton)

            Text(FigoConsentRow.text(consent, linkColor: primary))
                .font(.system(size: 13))
                .foregroundColor(textDark)
                .tint(primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }

    static let label = "I have read and agreed to the Terms, conditions, and privacy policy"

    /// The label, with "Terms, conditions" and "privacy policy" linked when their values are http(s) URLs.
    static func text(_ consent: FigoConsentLinks, linkColor: Color) -> AttributedString {
        func part(_ title: String, _ url: URL?) -> AttributedString {
            var part = AttributedString(title)
            if let url {
                part.link = url
                part.foregroundColor = linkColor
                part.underlineStyle = .single
            }
            return part
        }
        return AttributedString("I have read and agreed to the ") + part("Terms, conditions", consent.termsURL)
            + AttributedString(", and ") + part("privacy policy", consent.privacyURL)
    }
}

private struct FieldStyle: ViewModifier {
    let primary: Color
    let invalid: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 15))
            .foregroundColor(textDark)
            .tint(primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10).fill(bubbleGrey))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(errorRed, lineWidth: invalid ? 1 : 0))
    }
}

/// Searchable list of countries (flag, name, dialing code) for the phone field.
private struct FigoCountryPicker: View {
    let selected: FigoCountry
    let primary: Color
    let onSelect: (FigoCountry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(FigoCountry.all.filter { $0.matches(query) }) { country in
                Button {
                    onSelect(country)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text(country.flag)
                        Text(country.name).foregroundColor(textDark)
                        Spacer()
                        Text("+\(country.dial)").foregroundColor(textMuted)
                        if country == selected {
                            Image(systemName: "checkmark").foregroundColor(primary)
                        }
                    }
                    .font(.system(size: 15))
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search countries")
            .navigationTitle("Country code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(primary)
                }
            }
        }
    }
}
