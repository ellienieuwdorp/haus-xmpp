import SwiftUI

@main
struct XMPPiOSApp: App {
    @UIApplicationDelegateAdaptor(PushRegistration.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(.indigo)
                .task { await model.prepare() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.setForeground(true) }
                    else if phase == .background { model.setForeground(false) }
                }
        }
    }
}
