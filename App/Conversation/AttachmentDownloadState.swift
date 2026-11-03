import Foundation

enum AttachmentDownloadHold: Equatable, Sendable {
    // A 1:1 chat we never wrote in: no request to the sender's host unasked.
    case sender
    case size
    case network
}

enum AttachmentDownloadState: Equatable, Sendable {
    case loading
    case tapToDownload(AttachmentDownloadHold)
    case failed
    // The body was longer than announced; fetching it again cannot succeed.
    case mismatch
    case tooLarge

    var canRequest: Bool {
        switch self {
        case .tapToDownload, .failed: true
        case .loading, .mismatch, .tooLarge: false
        }
    }
}
