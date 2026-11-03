import AppKit

extension NSObject {
    // `accessibilityAttributeValue(_:)` is deprecated, but table row elements answer nothing newer; sending it by
    // selector reads them as an assistive app does.
    func legacyAccessibilityValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard responds(to: selector) else { return nil }
        return perform(selector, with: attribute.rawValue)?.takeUnretainedValue()
    }
}
