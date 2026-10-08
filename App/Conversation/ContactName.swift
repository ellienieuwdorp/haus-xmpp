import Foundation

/// How an address reads as a name. Shared with a Mac timeline, so nothing here may import UIKit or AppKit.
enum ContactName {
    /// A stored title, unless it is just the address; then the local part reads as the name.
    static func display(for address: String, title: String?) -> String {
        if let title, !title.isEmpty, title != address { return title }
        return address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address
    }
}
