import MessagingCore
import Photos
import SwiftUI

// Fills the composer's tray in the order things were picked. A video too long to send whole becomes an offer to send
// its start; the job that found it prepares that start, so its source is still at hand.
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

    func add(_ jobs: [Job], to state: ComposerState, model: AppModel) {
        guard !jobs.isEmpty else { return }
        let account = model.accountID
        let previous = batches
        running += 1
        batches = Task {
            defer { running -= 1 }
            await previous?.value
            let room = ComposerPlan.trayLimit - state.tray.count
            if jobs.count > room { model.error = "You can attach up to \(ComposerPlan.trayLimit) files at a time." }
            for job in jobs.prefix(max(0, room)) {
                guard let prepared = await prepare({ try await job(nil) }, model: model, account: account, source: .job(job)) else { continue }
                state.tray.append(PendingAttachment(prepared: prepared, preview: await AttachmentThumbnails.preview(of: prepared)))
            }
        }
    }

    func attach(asset: PHAsset, keepingFirst first: Int? = nil, to state: ComposerState, model: AppModel) async {
        let limit = model.attachmentLimit, account = model.accountID
        let previous = assetPicks
        let sends = state.sends
        let pick = Task { @MainActor in
            await previous?.value
            // Send took the tray while this pick waited; it must not land in the next message unasked.
            guard state.sends == sends else { return }
            guard state.tray.count < ComposerPlan.trayLimit else {
                model.error = "You can attach up to \(ComposerPlan.trayLimit) files at a time."
                return
            }
            let job = { try await AttachmentPreparer.prepare(asset: asset, limit: limit, keepingFirst: first) }
            guard let prepared = await prepare(job, model: model, account: account, fallback: "This photo could not be attached.", source: .asset(asset))
            else { return }
            let preview = await AttachmentThumbnails.preview(of: prepared)
            guard state.sends == sends, model.accountID == account else { return }
            state.tray.append(PendingAttachment(prepared: prepared, preview: preview, assetIdentifier: asset.localIdentifier))
        }
        assetPicks = pick
        await pick.value
    }

    func answer(_ shortening: AttachmentPreparer.Shortening, accepted: Bool, state: ComposerState, model: AppModel) {
        guard let index = offers.firstIndex(where: { $0.shortening.id == shortening.id }) else { return }
        let offer = offers.remove(at: index)
        guard accepted else { return }
        switch offer.source {
        case .job(let job): add([{ _ in try await job(shortening.seconds) }], to: state, model: model)
        case .asset(let asset): Task { await attach(asset: asset, keepingFirst: shortening.seconds, to: state, model: model) }
        }
    }

    func reset() { offers = [] }

    private func prepare(_ job: () async throws -> PreparedAttachment, model: AppModel, account: String,
                         fallback: String = "This file could not be attached.", source: Source) async -> PreparedAttachment? {
        do {
            let prepared = try await job()
            return model.accountID == account ? prepared : nil
        } catch AttachmentPreparer.Failure.tooLong(let seconds) {
            guard model.accountID == account else { return nil }
            offers.append(Offer(shortening: .init(seconds: seconds), source: source))
        } catch {
            guard model.accountID == account else { return nil }
            model.error = (error as? any LocalizedError)?.errorDescription ?? fallback
        }
        return nil
    }
}
