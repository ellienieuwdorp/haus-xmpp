import SwiftUI

@main
struct HausXMPPApp: App {
    @UIApplicationDelegateAdaptor(PushRegistration.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var appearance = AppearanceStore.shared

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .themedRoot()
                .environment(\.appearance, appearance)
                .task { await model.prepare() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.setForeground(true) }
                    else if phase == .background { model.setForeground(false) }
                }
        }
    }
}
