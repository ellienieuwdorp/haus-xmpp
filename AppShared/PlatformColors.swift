import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Colour and image seams shared by the apps and their share extensions; the app-only seams are in
// `PlatformSupport.swift`. On iOS each is the plain iOS call.

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
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }
}
#endif

extension Color {
    static var groupedBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var secondaryGroupedBackground: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var tertiaryFill: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemFill)
        #else
        Color(nsColor: .tertiarySystemFill)
        #endif
    }

    static var placeholderGray: Color {
        #if os(iOS)
        Color(.systemGray3)
        #else
        Color(nsColor: .systemGray)
        #endif
    }
}

extension Color {
    static var secondaryLabel: Color {
        #if os(iOS)
        Color(uiColor: .secondaryLabel)
        #else
        Color(nsColor: .secondaryLabelColor)
        #endif
    }
}
