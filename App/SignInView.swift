import SwiftUI

struct SignInView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var consent = false

    init(model: AppModel) {
        self.model = model
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-lab-ui-test") {
            _username = State(initialValue: ProcessInfo.processInfo.environment["XMPP_LAB_USERNAME"] ?? "")
            _password = State(initialValue: ProcessInfo.processInfo.environment["XMPP_LAB_PASSWORD"] ?? "")
        }
        #endif
    }

    private var canConnect: Bool { consent && !username.isEmpty && !password.isEmpty && !model.isConnecting }

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
                        Text("Use your lab account.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    row("Address") {
                        TextField("name", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textContentType(.username)
                            .accessibilityIdentifier("labUsername")
                    }
                    row("Password") {
                        SecureField("Required", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("labPassword")
                    }
                    Toggle("Use a disposable lab account", isOn: $consent)
                        .accessibilityIdentifier("labConsent")
                } footer: {
                    Text("\(DevelopmentEndpoint.host):5223 · Direct TLS")
                }
                Section {
                    VStack(spacing: 16) {
                        Button {
                            Task {
                                if await model.connect(username: username, password: password) {
                                    password = ""
                                    dismiss()
                                }
                            }
                        } label: {
                            Text(model.isConnecting ? "Connecting…" : "Connect")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(!canConnect)
                        Text(model.connectionStatus).font(.subheadline).foregroundStyle(.secondary)
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
