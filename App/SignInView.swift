import SwiftUI
import XMPPProtocol

struct SignInView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var password = ""
    @State private var server = ""
    @State private var port = ""
    @State private var security = XMPPTransportSecurity.startTLS
    @State private var consent = false
    @State private var showingAdvanced = false
    @State private var showingRestore = false

    init(model: AppModel) {
        self.model = model
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-lab-ui-test") {
            _address = State(initialValue: ProcessInfo.processInfo.environment["HAUS_LAB_USERNAME"] ?? "")
            _password = State(initialValue: ProcessInfo.processInfo.environment["HAUS_LAB_PASSWORD"] ?? "")
        }
        #endif
    }

    /// The address's domain. A bare username has one only in DEBUG, the lab's; Release takes full addresses only.
    private var domain: String? {
        let parts = address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]).lowercased() : AppModel.bareUsernameDomain
    }
    /// A bare username, or an address on a lab domain, keeps the disposable-account safeguard (DEBUG only).
    private var isLab: Bool {
        #if DEBUG
        domain.map(AppModel.labDomains.contains) ?? false
        #else
        false
        #endif
    }
    private var serverHost: String { server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var serverPort: UInt16? {
        let text = port.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? security.defaultPort : UInt16(text).flatMap { $0 > 0 ? $0 : nil }
    }
    /// A server entered by hand is the only endpoint tried; nil lets the app find the domain's server.
    private var manualServer: XMPPEndpoint? {
        guard !serverHost.isEmpty, let serverPort else { return nil }
        return XMPPEndpoint(host: serverHost, port: serverPort, security: security)
    }
    private var route: String {
        let name = { (security: XMPPTransportSecurity) in security == .directTLS ? "Direct TLS" : "STARTTLS" }
        if !serverHost.isEmpty, serverPort == nil { return "Port must be a number from 1 to 65535." }
        guard let domain else { return address.isEmpty ? "" : "Enter your full address, such as name@example.org." }
        if let manualServer { return "\(manualServer.host):\(manualServer.port) · \(name(manualServer.security))" }
        #if DEBUG
        if isLab { return "\(domain == "localhost" ? DevelopmentEndpoint.host : domain):5223 · Direct TLS" }
        #endif
        return "\(domain) · Server found automatically"
    }
    private var canConnect: Bool {
        (!isLab || consent) && domain != nil && !address.isEmpty && !password.isEmpty && !model.session.isConnecting
            && (serverHost.isEmpty || serverPort != nil)
    }

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
                            .noAutocapitalization().autocorrectionDisabled()
                            .keyboard(.emailAddress)
                            .textContentType(.username)
                            .accessibilityIdentifier("labUsername")
                    }
                    row("Password") {
                        SecureField("Required", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("labPassword")
                    }
                    #if DEBUG
                    if isLab {
                        Toggle("Use a disposable lab account", isOn: $consent)
                            .accessibilityIdentifier("labConsent")
                    }
                    #endif
                } footer: {
                    Text(route)
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
                        row("Server") {
                            TextField("Automatic", text: $server)
                                .noAutocapitalization().autocorrectionDisabled()
                                .keyboard(.URL)
                                .accessibilityIdentifier("serverHost")
                        }
                        if !serverHost.isEmpty {
                            row("Security") {
                                Picker("Security", selection: $security) {
                                    Text("STARTTLS").tag(XMPPTransportSecurity.startTLS)
                                    Text("Direct TLS").tag(XMPPTransportSecurity.directTLS)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .accessibilityIdentifier("serverSecurity")
                            }
                            row("Port") {
                                TextField(String(security.defaultPort), text: $port)
                                    .keyboard(.numberPad)
                                    .accessibilityIdentifier("serverPort")
                            }
                        }
                    }
                }
                Section {
                    VStack(spacing: 16) {
                        Button {
                            Task {
                                if await model.connect(username: address, password: password, server: manualServer) {
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
                        if model.canRestoreTransfer {
                            Button("Restore from a transfer…") { showingRestore = true }
                                .accessibilityIdentifier("signInRestoreTransfer")
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showingRestore) { RestoreTransferView(model: model).themedRoot() }
            // A restore signs this install in as the transferred account: nothing is left to sign in to here.
            .onChange(of: model.transferRestored) { _, restored in if restored { dismiss() } }
        }
    }

    private func row<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            field()
        }
    }
}
