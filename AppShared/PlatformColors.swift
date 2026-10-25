import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// The colour and image seams shared by the apps and their share extensions (`PlatformSupport.swift` holds the rest,
// which only an app may call). Each one is the iOS call it replaced, unchanged, on iOS.

#if os(iOS)
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#else
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#endif

extension Color {
    init(platform color: PlatformColor) {
        #if os(iOS)
        self.init(uiColor: color)
        #else
        self.init(nsColor: color)
        #endif
    }
}

extension Image {
    init(platformImage image: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

extension PlatformColor {
    /// One colour per appearance, resolved by the view or layer that draws it.
    static func dynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        #if os(iOS)
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        #else
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
        #endif
    }
}

#if os(macOS)
extension NSImage {
    /// `UIImage(cgImage:)`: the image at its pixel size, one point per pixel.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }
}
#endif

/// The system colours the shared screens name, with the Mac's nearest equivalent where macOS has no such colour.
extension Color {
    /// iOS `systemGroupedBackground`: the page behind grouped lists and sheets.
    static var groupedBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// iOS `secondarySystemGroupedBackground`: a card or tile on the grouped background.
    static var secondaryGroupedBackground: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// iOS `tertiarySystemFill`: the received bubble's fill.
    static var tertiaryFill: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemFill)
        #else
        Color(nsColor: .tertiarySystemFill)
        #endif
    }

    /// iOS `systemGray3`: an avatar circle with no address to colour it by.
    static var placeholderGray: Color {
        #if os(iOS)
        Color(.systemGray3)
        #else
        Color(nsColor: .systemGray)
        #endif
    }
}

extension Color {
    /// iOS `secondaryLabel`.
    static var secondaryLabel: Color {
        #if os(iOS)
        Color(uiColor: .secondaryLabel)
        #else
        Color(nsColor: .secondaryLabelColor)
        #endif
    }
}
