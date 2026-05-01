// Cross-platform aliases so the same source compiles on iOS and macOS.
// Prefer these in shared code; reach for UIKit/AppKit only inside `#if`.

import SwiftUI

#if os(iOS)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#else
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#endif

extension Image {
    /// Bridges a `PlatformImage` into SwiftUI without requiring callers to
    /// pick `Image(uiImage:)` vs `Image(nsImage:)` per platform.
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension View {
    /// `fullScreenCover` doesn't exist on macOS. This shim falls back to
    /// `.sheet` there, which is the closest native presentation.
    @ViewBuilder
    func platformFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        self.sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }
}

// MARK: - macOS polyfills for iOS-only SwiftUI modifiers
//
// Goal: keep the call sites (`.navigationBarTitleDisplayMode(.inline)`,
// `.keyboardType(.URL)`, etc.) identical across platforms. On iOS the SDK
// modifier is used; on macOS these no-op shims absorb the call so the same
// source compiles on both. Each polyfill only exists when the iOS-only
// SDK type doesn't, so there's no symbol clash on iOS.

#if os(macOS)
import SwiftUI

/// Stand-in mirror of UIKit's `NavigationBarItem.TitleDisplayMode`. macOS
/// has no concept of an inline navigation bar — every case maps to a no-op.
enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}

/// Mirror of UIKit's `UIKeyboardType` cases. The few cases the project
/// actually uses (`.URL`, `.numberPad`) are enumerated here; expand if a
/// new keyboard type starts being referenced from shared code.
enum UIKeyboardType { case `default`, URL, numberPad, decimalPad, emailAddress, phonePad }

enum UITextAutocapitalizationType { case none, words, sentences, allCharacters }

extension View {
    func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View { self }
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
    func autocapitalization(_ type: UITextAutocapitalizationType?) -> some View { self }

    /// `listSectionSpacing` is iOS-only — macOS uses default List spacing,
    /// which the shipped design tolerates without visual regression.
    func listSectionSpacing(_ spacing: ListSectionSpacing) -> some View { self }
}

enum ListSectionSpacing { case compact, `default` }

/// Polyfill of SwiftUI's iOS-only `TextInputAutocapitalization` so call sites
/// like `.textInputAutocapitalization(.never)` keep compiling on macOS.
struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}

extension View {
    func textInputAutocapitalization(_ autocap: TextInputAutocapitalization?) -> some View { self }
}

/// `.topBarTrailing` doesn't exist on macOS toolbars; `.primaryAction` is
/// the standard equivalent (right-side toolbar item).
extension ToolbarItemPlacement {
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
}
#endif

extension PlatformImage {
    /// PNG-encoded representation. `UIImage.pngData()` is iOS-only;
    /// macOS goes through a bitmap rep.
    func platformPNGData() -> Data? {
        #if os(iOS)
        return self.pngData()
        #else
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #endif
    }
}
