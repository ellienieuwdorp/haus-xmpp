import Foundation

// What a received file's bubble shows before the file is on disk. Shared with a Mac timeline, so nothing here may
// import UIKit or AppKit; the downloads themselves stay in AttachmentDownloads.swift.

/// Why a received file waits for a tap instead of downloading on sight.
enum AttachmentDownloadHold: Equatable, Sendable {
    /// A 1:1 chat we never wrote in: no request to the sender's host unasked.
    case sender
    /// Larger than the automatic limit, or of unknown size.
    case size
    /// Low Data Mode, or a cellular network for a file above the expensive limit.
    case network
}

/// A received file of the open chat that is not on disk yet.
enum AttachmentDownloadState: Equatable, Sendable {
    /// Waiting for a download slot or transferring.
    case loading
    case tapToDownload(AttachmentDownloadHold)
    /// The transfer or its verification failed; a tap tries again.
    case failed
    /// The body was longer than its message or the server said it would be. Fetching it again cannot succeed.
    case mismatch
    /// Larger than this app downloads at all; nothing is fetched.
    case tooLarge

    var canRequest: Bool {
        switch self {
        case .tapToDownload, .failed: true
        case .loading, .mismatch, .tooLarge: false
        }
    }
}
