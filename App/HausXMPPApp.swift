import MessagingCore
import SwiftUI

@main
struct HausXMPPApp: App {
    @UIApplicationDelegateAdaptor(PushRegistration.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    @State private var lifecycle: SceneLifecycle
    @State private var appearance = AppearanceStore.shared

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _lifecycle = State(initialValue: SceneLifecycle(model: model))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .themedRoot()
                .environment(\.appearance, appearance)
                .task { await model.prepare() }
                // Observed on the content, as before: the app has one scene (UIApplicationSupportsMultipleScenes is
                // off), so this runs once per process.
                .onChange(of: scenePhase) { previous, phase in
                    lifecycle.phaseChanged(from: .init(previous), to: .init(phase))
                }
        }
    }
}

/// The iOS lifecycle owner: it holds `SceneLifecycleDriver` and hands the model its updates, the way `MacLifecycle`
/// does for the Mac. The scene phase drives all four signals together, and a launch into the background (a
/// notification action) starts away until its first activation.
@MainActor final class SceneLifecycle {
    private var driver = SceneLifecycleDriver()
    private unowned let model: AppModel
    private var backgroundLaunchObserver: (any NSObjectProtocol)?
    /// Begun as the scene leaves `.active`, while the app is still in front: iOS grants background time asynchronously,
    /// so it is asked for before the app can be suspended. Ends at `.active` again, or at `.background` once the model's
    /// transition has begun its own.
    private var departure: BackgroundActivity?

    init(model: AppModel) {
        self.model = model
        model.lifecycleAtLaunch = { [weak self] in self?.launched() ?? [] }
    }

    func phaseChanged(from previous: SceneLifecycleDriver.Phase, to phase: SceneLifecycleDriver.Phase) {
        if phase == .inactive, departure == nil { departure = BackgroundActivity("Leave the foreground") }
        model.applyLifecycle(driver.updates(for: .phaseChanged(from: previous, to: phase)))
        if phase != .inactive { departure?.end(); departure = nil }
    }

    /// At the start of `prepare()`: a launch into the background must not connect, and its first activation counts as
    /// a return to the foreground even if the scene phase was never seen to change.
    private func launched() -> [LifecycleUpdate] {
        let inBackground = PlatformApplication.isInBackground
        let updates = driver.updates(for: .launched(inBackground: inBackground))
        guard inBackground else { return updates }
        backgroundLaunchObserver = NotificationCenter.default.addObserver(forName: PlatformApplication.didBecomeActiveNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.backgroundLaunchObserver { NotificationCenter.default.removeObserver(observer) }
                self.backgroundLaunchObserver = nil
                self.model.applyLifecycle(self.driver.updates(for: .becameActive))
            }
        }
        return updates
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
