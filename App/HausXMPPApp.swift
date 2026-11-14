import MessagingCore
import OSLog
import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct HausXMPPApp: App {
    @UIApplicationDelegateAdaptor(PushRegistration.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    @State private var lifecycle: SceneLifecycle
    @State private var appearance = AppearanceStore.shared

    init() {
        // The share extension draws its send button in the accent chosen here.
        AppearanceStore.shared.mirror = SharedSession.groupDefaults
        #if DEBUG
        // Lab runs: the share extension only queues, so the app's own connection must send what it shared.
        SharedSession.groupDefaults?.set(ProcessInfo.processInfo.arguments.contains("-haus-share-queue-only"), forKey: "debug.shareQueueOnly")
        #endif
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
                // The app has one scene (UIApplicationSupportsMultipleScenes is off), so this runs once per process.
                .onChange(of: scenePhase) { previous, phase in
                    lifecycle.phaseChanged(from: .init(previous), to: .init(phase))
                }
        }
    }
}

// A launch into the background (a notification action) starts away until its first activation. UIKit's own
// notifications report the phases too, since SwiftUI's can come late (an in-app Safari view handing off); the merge
// hands the driver each change once.
@MainActor final class SceneLifecycle {
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "lifecycle")
    private var driver = SceneLifecycleDriver()
    private var merge = ScenePhaseMerge()
    private unowned let model: AppModel
    private var backgroundLaunchObserver: (any NSObjectProtocol)?
    private var observers: [any NSObjectProtocol] = []
    // Begun as the scene leaves `.active`: iOS grants background time asynchronously, so it is asked for before
    // suspension. Ends at `.active` again, or at `.background` once the model's transition holds its own.
    private var departure: BackgroundActivity?

    init(model: AppModel) {
        self.model = model
        model.lifecycleAtLaunch = { [weak self] in self?.launched() ?? [] }
        #if os(iOS)
        let center = NotificationCenter.default
        let reports: [(Notification.Name, SceneLifecycleDriver.Phase)] = [(UIApplication.willResignActiveNotification, .inactive),
                                                                          (UIApplication.didEnterBackgroundNotification, .background),
                                                                          (UIApplication.didBecomeActiveNotification, .active)]
        for (name, phase) in reports {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(from: nil, to: phase, source: "uikit") }
            })
        }
        observers.append(center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { _ in
            Self.log.notice("scene disconnected")
        })
        // Posted inside `applicationWillTerminate`, which a swipe from the app switcher calls on a running app.
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.flushBeforeTermination() }
        })
        #endif
    }

    func phaseChanged(from previous: SceneLifecycleDriver.Phase, to phase: SceneLifecycleDriver.Phase) {
        report(from: previous, to: phase, source: "swiftui")
    }

    private func report(from previous: SceneLifecycleDriver.Phase?, to phase: SceneLifecycleDriver.Phase, source: String) {
        guard let step = merge.step(from: previous, to: phase) else { return }
        let change = "\(step.from) → \(step.to)"
        Self.log.notice("scene \(change, privacy: .public) (\(source, privacy: .public))")
        if step.to == .inactive, departure == nil {
            departure = BackgroundActivity("Leave the foreground", onExpire: { [weak self] in self?.model.engine.backgroundTimeExpiring() })
        }
        StorageParking.shared.sceneChanged(active: step.to == .active)
        model.applyLifecycle(driver.updates(for: .phaseChanged(from: step.from, to: step.to)))
        if step.to != .inactive { departure?.end(); departure = nil }
        // The scene can step from `.active` to `.background` with no `.inactive` between, so no departure ends to park.
        if step.to == .background { StorageParking.shared.parkIfIdle() }
    }

    // A launch into the background must not connect, and its first activation counts as a foreground return.
    private func launched() -> [LifecycleUpdate] {
        let inBackground = PlatformApplication.isInBackground
        if inBackground { merge = ScenePhaseMerge(applied: .background) }
        let updates = driver.updates(for: .launched(inBackground: inBackground))
        guard inBackground else { return updates }
        StorageParking.shared.sceneChanged(active: false)
        backgroundLaunchObserver = NotificationCenter.default.addObserver(forName: PlatformApplication.didBecomeActiveNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.backgroundLaunchObserver { NotificationCenter.default.removeObserver(observer) }
                self.backgroundLaunchObserver = nil
                StorageParking.shared.sceneChanged(active: true)
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
        default: self = .inactive
        }
    }
}
