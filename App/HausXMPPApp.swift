import SwiftUI

@main
struct HausXMPPApp: App {
    @UIApplicationDelegateAdaptor(PushRegistration.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @AppStorage(AccentTheme.storageKey) private var accentRaw = AccentTheme.indigo.rawValue
    @AppStorage(AppearanceView.modeKey) private var appearanceMode = "automatic"

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(Color(uiColor: (AccentTheme(rawValue: accentRaw) ?? .indigo).tint))
                .preferredColorScheme(AppearanceView.colorScheme(for: appearanceMode))
                .task { await model.prepare() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.setForeground(true) }
                    else if phase == .background { model.setForeground(false) }
                }
        }
    }
}
