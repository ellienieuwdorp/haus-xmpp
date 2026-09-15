import SwiftUI

struct SignInView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var password = ""
    @State private var server = ""
    @State private var consent = false
    @State private var showingAdvanced = false

    init(model: AppModel) {
        self.model = model
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-lab-ui-test") {
            _address = State(initialValue: ProcessInfo.processInfo.environment["XMPP_LAB_USERNAME"] ?? "")
            _password = State(initialValue: ProcessInfo.processInfo.environment["XMPP_LAB_PASSWORD"] ?? "")
        }
        #endif
    }

    private var domain: String {
        let parts = address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]).lowercased() : DevelopmentEndpoint.domain
    }
    /// A bare username, or an address on a lab domain, keeps the disposable-account safeguard.
    private var isLab: Bool { AppModel.labDomains.contains(domain) }
    private var host: String {
        if isLab { return domain == "localhost" ? DevelopmentEndpoint.host : domain }
        let override = server.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? domain : override.lowercased()
    }
    private var canConnect: Bool { (!isLab || consent) && !address.isEmpty && !password.isEmpty && !model.session.isConnecting }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 72, height: 72)
                            .overlay { Image(systemName: "bubble.left.fill").font(.system(size: 34)).foregroundStyle(.white) }
                            .accessibilityHidden(true)
                        Text("Sign in").font(.title.bold()).padding(.top, 6)
                        Text("Use your XMPP address.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    row("Address") {
                        TextField("name@example.org", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .accessibilityIdentifier("labUsername")
                    }
                    row("Password") {
                        SecureField("Required", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("labPassword")
                    }
                    if isLab {
                        Toggle("Use a disposable lab account", isOn: $consent)
                            .accessibilityIdentifier("labConsent")
                    }
                } footer: {
                    Text("\(host):5223 · Direct TLS")
                }
                if !isLab {
                    Section {
                        DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
                            row("Server") {
                                TextField(domain, text: $server)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .accessibilityIdentifier("serverHost")
                            }
                        }
                    } footer: {
                        Text("Only needed when the server’s host differs from the address domain.")
                    }
                }
                Section {
                    VStack(spacing: 16) {
                        Button {
                            Task {
                                if await model.connect(username: address, password: password, host: server) {
                                    password = ""
                                    dismiss()
                                }
                            }
                        } label: {
                            Text(model.session.isConnecting ? "Connecting…" : "Connect")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(!canConnect)
                        Text(model.session.label).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            field()
        }
    }
}
