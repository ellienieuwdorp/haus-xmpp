import SwiftUI

extension View {
    // An alert rather than a confirmation dialog: on the iPhone a dialog over the whole screen becomes a popover with no
    // Cancel. Dismissing it any other way declines; each offer is answered once, so a decline after a tap does nothing.
    func shorteningDialog(_ offer: AttachmentPreparer.Shortening?,
                          answer: @escaping (AttachmentPreparer.Shortening, _ accepted: Bool) -> Void) -> some View {
        alert(AttachmentPreparer.Shortening.title, isPresented: Binding(
            get: { offer != nil }, set: { if !$0, let offer { answer(offer, false) } }
        ), presenting: offer) { offer in
            Button(offer.confirmation) { answer(offer, true) }
            Button("Cancel", role: .cancel) { answer(offer, false) }
        } message: { offer in
            Text(offer.message)
        }
    }
}
