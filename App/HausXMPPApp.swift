import MessagingCore
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
                // The iOS lifecycle driver (`SceneLifecycleDriver`) turns the phase into the four lifecycle signals.
                .onChange(of: scenePhase) { previous, phase in
                    model.scenePhaseChanged(from: .init(previous), to: .init(phase))
                }
        }
    }
}

private extension SceneLifecycleDriver.Phase {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        // `.inactive`, and any future phase: neither turns the signals on nor off.
        default: self = .inactive
        }
    }
}
