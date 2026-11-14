import Foundation
import Synchronization
import Testing
@testable import MessagingCore

// XEP-0386 enables carbons inside the Bind 2 request, so setup asks the server's features but never for carbons again.
struct InlineCarbonsSetupTests {
    private final class Steps: Sendable {
        let names = Mutex<[String]>([])
        func add(_ name: String) { names.withLock { $0.append(name) } }
    }

    private func operations(_ steps: Steps) -> ConnectionSetup.Operations {
        ConnectionSetup.Operations(
            features: { steps.add("features"); return [ConnectionSetup.carbonsFeature, ConnectionSetup.archiveFeature] },
            enableCarbons: { steps.add("carbons") }, discoverUploads: {}, initializeEncryption: { steps.add("initialize") },
            rejoinGroups: {}, catchUp: { _ in steps.add("walk") }, retryPending: {})
    }

    @Test(arguments: [true, false])
    func carbonsEnabledInTheBindAreNotAskedForAgain(_ inline: Bool) async {
        let steps = Steps()
        let events = Mutex<[ConnectionSetup.Event]>([])
        await ConnectionSetup(identityExists: true, carbonsInline: inline).run(operations: operations(steps)) { event in
            events.withLock { $0.append(event) }
        }
        let names = steps.names.withLock { $0 }
        #expect(names.contains("features") && names.contains("initialize") && names.contains("walk"))
        #expect(names.contains("carbons") == !inline)
        #expect(events.withLock { $0.last } == .settled)
    }
}
