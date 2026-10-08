import SwiftUI

/// The Settings window (⌘,): the iPhone's settings screen as the General pane, and Appearance as a pane of its own.
struct MacSettingsView: View {
    enum Pane: String { case general, appearance }

    @Bindable var model: AppModel
    @State private var pane = Pane.general
    @State private var showingConnection = false

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) {
                NavigationStack {
                    SettingsView(model: model, showingConnection: $showingConnection)
                }
            }
            Tab("Appearance", systemImage: "paintpalette", value: .appearance) {
                NavigationStack {
                    AppearanceView()
                }
            }
        }
        .toggleStyle(.switch)
        .frame(width: 560, height: 620)
        .sheet(isPresented: $showingConnection) {
            SignInView(model: model)
                .frame(minWidth: 460, idealWidth: 480, minHeight: 560, idealHeight: 620)
                .themedRoot()
        }
        #if DEBUG
        .onAppear { if let value = MacDebugHooks.value(after: "-haus-settings"), let pane = Pane(rawValue: value) { self.pane = pane } }
        #endif
    }
}
