import SwiftUI

/// The Settings window (⌘,): the iPhone's settings screen as the General pane, and Appearance and About as panes of
/// their own.
struct MacSettingsView: View {
    enum Pane: String { case general, appearance, about }

    @Bindable var model: AppModel
    @State private var pane = Pane.general
    @State private var showingConnection = false

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) {
                NavigationStack {
                    SettingsView(model: model, showingConnection: $showingConnection)
                }
                .labelStyle(.listRow)
            }
            Tab("Appearance", systemImage: "paintpalette", value: .appearance) {
                NavigationStack {
                    AppearanceView()
                }
                .labelStyle(.listRow)
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                NavigationStack {
                    AboutView()
                }
                .labelStyle(.listRow)
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
        .background(MacUnobtrusive.Anchor())
        .onAppear { if let value = MacDebugHooks.value(after: "-haus-settings"), let pane = Pane(rawValue: value) { self.pane = pane } }
        .onChange(of: MacDebugHooks.tour.settingsPane, initial: true) { _, pane in if let pane { self.pane = pane } }
        #endif
    }
}

/// A list row's `Label` on the Mac: its icon (the shared screens' coloured tiles) and title 12 points apart, as the
/// iPhone's rows space them. The Mac's own list label set the tiles flush against their titles.
struct ListRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == ListRowLabelStyle {
    static var listRow: ListRowLabelStyle { ListRowLabelStyle() }
}
