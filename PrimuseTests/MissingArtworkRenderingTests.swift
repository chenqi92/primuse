import PrimuseKit
import SwiftUI
import XCTest
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MissingArtworkRenderingTests: XCTestCase {
    func testOriginalPlaceholderRemainsDefaultAndIconRequiresOptIn() throws {
        try withDefaults { defaults in
            for scheme in [ColorScheme.light, .dark] {
                defaults.removeObject(forKey: MissingArtworkStyle.storageKey)
                let original = try render(missingCover, defaults: defaults, scheme: scheme)
                defaults.set("standard", forKey: MissingArtworkStyle.storageKey)
                XCTAssertEqual(original, try render(missingCover, defaults: defaults, scheme: scheme))
                defaults.set("appIcon", forKey: MissingArtworkStyle.storageKey)
                let icon = try render(missingCover, defaults: defaults, scheme: scheme)
                XCTAssertNotEqual(original, icon)
                XCTAssertGreaterThan(pinkPixels(icon), 1_000, "The opt-in must resolve the bundled P icon")
                XCTAssertLessThan(pinkPixels(original), 10, "The existing placeholder must remain neutral")
            }
        }
    }

    func testOptionalCoverFollowsTheSelectedAppIcon() throws {
        try withDefaults { defaults in
            defaults.set("appIcon", forKey: MissingArtworkStyle.storageKey)
            let current = try render(missingCover, defaults: defaults)
            #if os(macOS)
            defaults.set("AppIcon19", forKey: "pm.mac.appIcon")
            #else
            defaults.set("AppIcon19", forKey: "primuse.appIconChoice")
            #endif
            let alternative = try render(missingCover, defaults: defaults)
            XCTAssertNotEqual(current, alternative)
        }
    }

    func testRetiredIconSelectionsRenderThePrimaryArtwork() throws {
        try withDefaults { defaults in
            defaults.set("appIcon", forKey: MissingArtworkStyle.storageKey)
            let primary = try render(missingCover, defaults: defaults)
            for retired in ["AppIcon21", "AppIcon14"] {
                #if os(macOS)
                defaults.set(retired, forKey: "pm.mac.appIcon")
                #else
                defaults.set(retired, forKey: "primuse.appIconChoice")
                #endif
                XCTAssertEqual(primary, try render(missingCover, defaults: defaults))
            }
        }
    }

    #if !os(tvOS)
    func testExistingArtworkIsUnchangedByThePreference() throws {
        let cover = ImageRenderer(content: Color.blue.frame(width: 128, height: 128))
        let cg = try XCTUnwrap(cover.cgImage)
        #if os(macOS)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        #else
        let data = try XCTUnwrap(UIImage(cgImage: cg).pngData())
        #endif
        try withDefaults { defaults in
            let view = CoverArtView(data: data, size: 128, showsMissingArtworkIcon: true)
            let original = try render(view, defaults: defaults)
            defaults.set("appIcon", forKey: MissingArtworkStyle.storageKey)
            XCTAssertEqual(original, try render(view, defaults: defaults))
        }
    }
    #else
    func testBookAndPodcastPlaceholdersKeepTheirOriginalAppearance() throws {
        try withDefaults { defaults in
            for kind in [TVArtworkPlaceholderKind.book, .podcast] {
                defaults.set("standard", forKey: MissingArtworkStyle.storageKey)
                let view = TVMusicPlaceholder(tint: .pink, tint2: .purple, kind: kind, size: 128)
                let original = try render(view, defaults: defaults)
                defaults.set("appIcon", forKey: MissingArtworkStyle.storageKey)
                XCTAssertEqual(original, try render(view, defaults: defaults))
            }
        }
    }
    #endif

    private var missingCover: some View {
        #if os(tvOS)
        TVMusicPlaceholder(tint: .pink, tint2: .purple, size: 128)
        #else
        CoverArtView(data: nil, size: 128, showsMissingArtworkIcon: true)
        #endif
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "MissingArtworkRenderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func render<V: View>(_ view: V, defaults: UserDefaults, scheme: ColorScheme = .light) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view
            .frame(width: 128, height: 128)
            .background(scheme == .light ? Color.white : Color.black)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 128, height: 128,
                bitsPerComponent: 8, bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        }
        return pixels
    }

    private func pinkPixels(_ pixels: [UInt8]) -> Int {
        stride(from: 0, to: pixels.count, by: 4).filter { offset in
            Int(pixels[offset]) > Int(pixels[offset + 1]) + 40
                && Int(pixels[offset + 2]) > Int(pixels[offset + 1]) + 20
        }.count
    }
}
