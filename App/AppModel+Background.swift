import Foundation
import MessageStore
import MessagingCore
import OSLog
import UserNotifications
import XMPPProtocol

// Liveness answers whose probe has not settled and files still uploading each hold the grace open.
@MainActor final class BackgroundGraceState {
    var livenessPromises = 0
    var livenessPromiseBroken = false
    var uploads = false
    var giveWay: ExtensionGiveWay.Ask?
    var unsentWanted = false
    var livenessResponder: AppLiveness.Responder?
}

extension AppModel {

    // A push for this live session is presented once, by the app: on the Mac while it runs, on the iPhone only in the
    // grace. A UI test session's store is not the one the extension opens.
    func startLivenessResponder() {
        guard grace.livenessResponder == nil, let container = try? SharedStorage.groupContainer() else { return }
        let responder = AppLiveness.Responder(files: AppLiveness.Files(groupRoot: container),
                                              conditions: { [weak self] in self?.livenessConditions ?? Self.silent },
                                              answered: { [weak self] in self?.keepLivenessPromise() })
        if responder.start() { grace.livenessResponder = responder }
        else { Self.syncLog.error("liveness responder could not observe its ring") }
    }

    private static let silent = LivenessConditions(wantsConnection: false, quiescing: true, ownsLease: false, servesExtensionAccount: false,
                                                   presentsCatchUp: false)
    private static let graceProbe: Duration = .seconds(3)

    // The answer promises this process keeps the lease and presents what was pushed, for the extension's account.
    private var livenessConditions: LivenessConditions {
        LivenessConditions(wantsConnection: wantsConnection && testSessionID == nil, quiescing: quiescing,
                           ownsLease: hasTransportOwnership,
                           servesExtensionAccount: sessionAccount.map { saved in
                               (try? NotificationAccount.load())?.accountID == saved.accountID
                           } ?? false,
                           presentsCatchUp: Self.attention.holdsCatchUpBanners,
                           graceWithLiveStream: graceAnswers)
    }

    private var graceAnswers: Bool {
        testSessionID == nil && engine.backgroundPhase == .grace && engine.streamOnline && hasTransportOwnership
            && (engine.graceTimeLeft ?? .zero) >= Self.graceProbe + .seconds(1)
    }

    // The server pushed because an acknowledgement was overdue, so the socket may be dead without an error: probe it (a
    // dead stream ends and the reconciler resumes it, replaying what the server queued), or connect at once.
    private func keepLivenessPromise() {
        Self.syncLog.notice("liveness answered, connected=\(self.isConnected, privacy: .public)")
        if engine.backgroundPhase == .grace, let client { return keepGraceLivenessPromise(client) }
        guard isConnected, let client else {
            networkBecameReachable()
            return
        }
        Task { [weak self] in
            let alive = await client.probeLiveness(within: .seconds(5))
            Self.syncLog.notice("liveness probe answered=\(alive, privacy: .public)")
            if !alive { self?.networkBecameReachable() }
        }
    }

    // A dead stream cannot deliver what was pushed for, so the grace's end posts the extension's fallback instead.
    private func keepGraceLivenessPromise(_ client: XMPPClient) {
        grace.livenessPromises += 1
        engine.graceWorkChanged()
        Task { [weak self] in
            let alive = await client.probeLiveness(within: Self.graceProbe)
            Self.syncLog.notice("grace liveness probe answered=\(alive, privacy: .public)")
            // A second for what the probe flushed to be processed; cancelling only shortens it.
            if alive { try? await Task.sleep(for: .seconds(1)) }
            guard let self else { return }
            if !alive { self.grace.livenessPromiseBroken = true }
            self.grace.livenessPromises -= 1
            self.engine.graceWorkChanged()
        }
    }


    // Synchronous, before anything is awaited: iOS grants background time asynchronously, and an app it suspends while
    // holding the lease's file lock is killed. The activity's expiry ends a grace and hard-closes a quiesce.
    func beginTransition(_ transition: LifecycleTransition) -> BackgroundActivity? {
        if transition.resumesTransport, !transition.quiescesTransport { engine.foregroundRequested() }
        guard transition.quiescesTransport else { return nil }
        engine.backgroundRequested(grace: Self.attention.holdsBackgroundGrace)
        return BackgroundActivity("Finish encrypted synchronization", onExpire: { [weak self] in self?.engine.backgroundTimeExpiring() })
    }

    // A background transition that began meanwhile keeps new work refused until its own foreground.
    func reopenAfterQuiesce() {
        if engine.backgroundPhase == .foreground { quiescing = false }
    }

    // Whichever store holds the lease gives it up, the recovery screen's too; a restore releases its own.
    func releaseHeldLeases() async -> Bool {
        guard !restoringData else { return true }
        hasTransportOwnership = false
        var released = true
        if let store { released = await engine.releaseLease(store) }
        if let recoveryStore, await recoveryStore.holdsTransportOwnership { released = await engine.releaseLease(recoveryStore) && released }
        if released, !runsNotificationAction, MessageStore.processHoldsTransportLock {
            Self.lifecycleLog.fault("the transport lock is still held by a store no quiesce knows")
        }
        return released
    }

    // Kept or taken, never by force: false when another process holds it for ten seconds, or once transport is unwanted.
    func takeLease(_ store: MessageStore, whileWanted: Bool = false) async -> Bool {
        var leased = await store.holdsTransportOwnership
        for _ in 0..<40 where !leased && (!whileWanted || transportWanted) {
            do { try await store.acquireTransportOwnership(); leased = true }
            catch MessageStoreError.transportOwnedElsewhere { guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { break } }
            catch { Self.lifecycleLog.error("lease not taken: \(String(describing: error), privacy: .public)"); break }
        }
        return leased
    }

    var holdsGrace: Bool { grace.livenessPromises > 0 || grace.uploads }

    func graceStarted() {
        // Before the store answers, so the first idle check cannot end the grace under a running upload.
        grace.uploads = true
        grace.livenessPromiseBroken = false
        if testSessionID == nil, let container = try? SharedStorage.groupContainer() {
            let until = Date().addingTimeInterval(Double((engine.graceTimeLeft ?? .zero) / .milliseconds(1)) / 1000)
            AppLiveness.Files(groupRoot: container).saveOffer(until: until)
        }
        startUploads()
        Task { await graceUploadsChanged() }
    }

    func graceEnding(_ end: GraceEnd) async {
        if testSessionID == nil, let container = try? SharedStorage.groupContainer() { AppLiveness.Files(groupRoot: container).removeOffer() }
        grace.uploads = false
        await refresh()
        if grace.livenessPromiseBroken || grace.livenessPromises > 0 { postNotificationFallback() }
        grace.livenessPromiseBroken = false
    }

    func graceUploadsChanged() async {
        guard engine.backgroundPhase == .grace, let store, !accountID.isEmpty else {
            grace.uploads = false
            return
        }
        grace.uploads = !((try? await store.attachmentsAwaitingUpload(accountID: accountID)) ?? []).isEmpty
        engine.graceWorkChanged()
    }

    // A stream kept through a cancelled grace announced away and inactive; it comes back without a reconnect.
    func resumeKeptStream() async -> Bool {
        guard engine.resumeForeground(), let client else { return false }
        Self.lifecycleLog.notice("back during the grace: stream kept")
        // A failed write ends the stream, and the reconciler then reconnects.
        try? await client.setAvailability(.active, clientActive: true)
        startOutbox()
        startUploads()
        return true
    }


    // Turns the main run loop so the main actor keeps sending, at most `limit`. Whatever this does not finish stays in
    // the durable outbox and journal and is recovered, never repeated, on the next launch.
    func flushBeforeTermination(within limit: Duration = .seconds(2)) {
        let pending = !engine.outboxIdle || holdsGrace
        let phase = String(describing: engine.backgroundPhase)
        Self.lifecycleLog.notice("terminating: phase \(phase, privacy: .public), pending \(pending, privacy: .public)")
        guard engine.streamOnline, hasTransportOwnership else { return }
        var finished = false
        Task { @MainActor [weak self] in
            let flushed = await self?.engine.flushOutbox(within: limit) ?? false
            Self.lifecycleLog.notice("termination flush emptied the outbox: \(flushed, privacy: .public)")
            finished = true
        }
        let end = Date().addingTimeInterval(Double(limit / .milliseconds(1)) / 1000 + 0.2)
        while !finished, Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }


    // `leaseTaken` promises the extension that the foreground claim presents what it left: only a foreground connect asks.
    private var asksGiveWay: Bool {
        testSessionID == nil && transportWanted && !quiescing && engine.backgroundPhase == .foreground
    }

    func leaseBusy() {
        guard asksGiveWay else { return }
        if grace.giveWay == nil {
            guard let container = try? SharedStorage.groupContainer() else { return }
            grace.giveWay = ExtensionGiveWay.Ask(files: ExtensionGiveWay.Files(groupRoot: container))
        }
        grace.giveWay?.leaseBusy()
    }

    func leaseWaitEnded(acquired: Bool) {
        guard let ask = grace.giveWay else { return }
        grace.giveWay = nil
        if acquired, asksGiveWay { ask.leaseTaken() } else { ask.withdraw() }
    }


    // Content-free, one at a time; an add that lands after a withdrawal is removed again.
    func unsentNotice(_ visible: Bool) {
        guard testSessionID == nil, !isDemo, !accountID.isEmpty else { return }
        grace.unsentWanted = visible
        let identifier = NotificationIdentity.unsent(accountID: accountID)
        let center = UNUserNotificationCenter.current()
        guard visible else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.body = NotificationPlanner.unsentBody
        content.categoryIdentifier = NotificationIdentity.fallbackCategory
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task { [weak self] in
            guard await Self.mayAlert() else { return }
            // A failed add leaves nothing to withdraw.
            try? await UNUserNotificationCenter.current().add(request)
            if self?.grace.unsentWanted != true { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier]) }
        }
    }

    // A notification action's drain may have sent what the notice was about.
    func withdrawUnsentNoticeIfSent() async {
        guard grace.unsentWanted, let store, !accountID.isEmpty,
              let ready = try? await store.queuedOutgoing(accountID: accountID),
              let uploading = try? await store.attachmentsAwaitingUpload(accountID: accountID) else { return }
        if ready.isEmpty, uploading.isEmpty { unsentNotice(false) }
    }

    private func postNotificationFallback() {
        guard testSessionID == nil, !accountID.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.body = NotificationPlanner.fallbackBody
        content.categoryIdentifier = NotificationIdentity.fallbackCategory
        content.sound = .default
        let request = UNNotificationRequest(identifier: NotificationIdentity.fallback(accountID: accountID), content: content, trigger: nil)
        Self.syncLog.notice("grace liveness promise broken: fallback posted")
        Task {
            guard await Self.mayAlert() else { return }
            // Best effort, as the extension's own fallback is.
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private nonisolated static func mayAlert() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        #if os(iOS)
        if status == .ephemeral { return true }
        #endif
        return status == .authorized || status == .provisional
    }
}
