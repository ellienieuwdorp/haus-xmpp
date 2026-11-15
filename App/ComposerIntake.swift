import MessagingCore
import Photos
import SwiftUI

// What the intake reads and reports through: the app model, or a stand-in in tests.
@MainActor protocol ComposerIntakeHost: AnyObject {
    var accountID: String { get }
    var attachmentLimit: Int { get }
    var error: String? { get set }
}

extension AppModel: ComposerIntakeHost {}

// Fills the composer's tray in the order things were picked. A video too long to send whole becomes an offer to send
// its start; the job that found it prepares that start, so its source is still at hand. `reset` stops what is still
// preparing, which deletes what it wrote.
@MainActor @Observable final class ComposerIntake {
    typealias Job = (_ keepingFirst: Int?) async throws -> PreparedAttachment
    // What prepares the start once it is taken: the same job, or the same rail pick.
    enum Source {
        case job(Job)
        case asset(PHAsset)
    }
    struct Offer {
        let shortening: AttachmentPreparer.Shortening
        let source: Source
    }

    private(set) var running = 0
    private(set) var offers: [Offer] = []
    var attaching: Bool { running > 0 }
    var offer: AttachmentPreparer.Shortening? { offers.first?.shortening }
    @ObservationIgnored private var batches: Task<Void, Never>?
    // Rail picks prepare one after another so the tray keeps tap order.
    @ObservationIgnored private var assetPicks: Task<Void, Never>?
    @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]

    func add(_ jobs: [Job], to state: ComposerState, model: any ComposerIntakeHost) {
        guard !jobs.isEmpty else { return }
        let account = model.accountID, sends = state.sends
        let previous = batches
        running += 1
        batches = track { [self] in
            defer { running -= 1 }
            await previous?.value
            let room = ComposerPlan.trayLimit - state.tray.count
            if jobs.count > room, !Task.isCancelled { model.error = "You can attach up to \(ComposerPlan.trayLimit) files at a time." }
            for job in jobs.prefix(max(0, room)) {
                guard !Task.isCancelled else { return }
                guard let prepared = await prepare({ try await job(nil) }, model: model, account: account, source: .job(job)) else { continue }
                let preview = await AttachmentThumbnails.preview(of: prepared)
                // Send took the tray, or the account changed, while this file prepared.
                guard !Task.isCancelled, state.sends == sends, model.accountID == account else { continue }
                state.tray.append(PendingAttachment(prepared: prepared, preview: preview))
            }
        }
    }

    func attach(asset: PHAsset, keepingFirst first: Int? = nil, to state: ComposerState, model: any ComposerIntakeHost) async {
        let limit = model.attachmentLimit, account = model.accountID
        let previous = assetPicks
        let sends = state.sends
        let pick = track { [self] in
            await previous?.value
            // Send took the tray while this pick waited; it must not land in the next message unasked.
            guard !Task.isCancelled, state.sends == sends else { return }
            guard state.tray.count < ComposerPlan.trayLimit else {
                model.error = "You can attach up to \(ComposerPlan.trayLimit) files at a time."
                return
            }
            let job = { try await AttachmentPreparer.prepare(asset: asset, limit: limit, keepingFirst: first) }
            guard let prepared = await prepare(job, model: model, account: account, fallback: "This photo could not be attached.", source: .asset(asset))
            else { return }
            let preview = await AttachmentThumbnails.preview(of: prepared)
            guard !Task.isCancelled, state.sends == sends, model.accountID == account else { return }
            state.tray.append(PendingAttachment(prepared: prepared, preview: preview, assetIdentifier: asset.localIdentifier))
        }
        assetPicks = pick
        await pick.value
    }

    func answer(_ shortening: AttachmentPreparer.Shortening, accepted: Bool, state: ComposerState, model: any ComposerIntakeHost) {
        guard let index = offers.firstIndex(where: { $0.shortening.id == shortening.id }) else { return }
        let offer = offers.remove(at: index)
        guard accepted else { return }
        switch offer.source {
        case .job(let job): add([{ _ in try await job(shortening.seconds) }], to: state, model: model)
        case .asset(let asset): Task { await attach(asset: asset, keepingFirst: shortening.seconds, to: state, model: model) }
        }
    }

    func reset() {
        offers = []
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
    }

    // Returns once the batches and picks started so far have ended.
    func settled() async {
        await batches?.value
        await assetPicks?.value
    }

    // Each task leaves the set as it ends, so `reset` cancels only work still running.
    private func track(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await work()
            self?.inFlight[id] = nil
        }
        inFlight[id] = task
        return task
    }

    private func prepare(_ job: () async throws -> PreparedAttachment, model: any ComposerIntakeHost, account: String,
                         fallback: String = "This file could not be attached.", source: Source) async -> PreparedAttachment? {
        do {
            let prepared = try await job()
            return model.accountID == account && !Task.isCancelled ? prepared : nil
        } catch AttachmentPreparer.Failure.tooLong(let seconds) {
            guard model.accountID == account, !Task.isCancelled else { return nil }
            offers.append(Offer(shortening: .init(seconds: seconds), source: source))
        } catch {
            guard model.accountID == account, !Task.isCancelled else { return nil }
            model.error = (error as? any LocalizedError)?.errorDescription ?? fallback
        }
        return nil
    }
}
