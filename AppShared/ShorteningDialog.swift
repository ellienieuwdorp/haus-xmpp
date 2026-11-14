import SwiftUI

extension View {
    // Dismissing the dialog any other way declines; each offer is answered once, so a decline after a tap does nothing.
    func shorteningDialog(_ offer: AttachmentPreparer.Shortening?,
                          answer: @escaping (AttachmentPreparer.Shortening, _ accepted: Bool) -> Void) -> some View {
        confirmationDialog(AttachmentPreparer.Shortening.title, isPresented: Binding(
            get: { offer != nil }, set: { if !$0, let offer { answer(offer, false) } }
        ), titleVisibility: .visible, presenting: offer) { offer in
            Button(offer.confirmation) { answer(offer, true) }
            Button("Cancel", role: .cancel) { answer(offer, false) }
        } message: { offer in
            Text(offer.message)
        }
    }
}
