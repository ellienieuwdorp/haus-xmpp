import SwiftUI

@main
struct XMPPiOSApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(.indigo)
                .task { await model.prepare() }
        }
    }
}
