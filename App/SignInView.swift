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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Connect a disposable account on the local development server. New messages require end-to-end encryption and approved recipient devices.")
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("labUsername")
                    SecureField("Password", text: $password).accessibilityIdentifier("labPassword")
                    Toggle("Use a disposable lab account", isOn: $consent)
                        .accessibilityIdentifier("labConsent")
                } footer: {
                    Text("\(DevelopmentEndpoint.host):5223 · Direct TLS. The lab certificate must be trusted by this connection. Enabling notifications stores this account in this device’s protected Keychain for background synchronization.")
                }
                Section {
                    Button(model.isConnecting ? "Connecting…" : "Connect") {
                        Task {
                            if await model.connect(username: username, password: password) {
                                password = ""
                                dismiss()
                            }
                        }
                    }.disabled(!consent || username.isEmpty || password.isEmpty || model.isConnecting)
                    Text(model.connectionStatus).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(DevelopmentEndpoint.domain == "localhost" ? "Local lab" : "Staging lab")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
