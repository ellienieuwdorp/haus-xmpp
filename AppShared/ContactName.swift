import Foundation

enum ContactName {
    static func display(for address: String, title: String?) -> String {
        if let title, !title.isEmpty, title != address { return title }
        return address.split(separator: "@", maxSplits: 1).first.map(String.init) ?? address
    }
}
