import AppKit
import SwiftUI
import XCTest
@testable import SkillDeck

final class SidebarIconTests: XCTestCase {

    private let overviewItems: [SidebarItem] = [.dashboard, .registry, .clawHub]

    func testOverviewItemsHaveBundledIcons() throws {
        for item in overviewItems {
            let name = try XCTUnwrap(item.iconResourceName, "Missing icon name for \(item)")
            let url = SkillDeckResources.bundle.url(
                forResource: name,
                withExtension: "svg",
                subdirectory: "SidebarIcons"
            )
            XCTAssertNotNil(url, "Missing bundled icon \(name).svg")
            XCTAssertFalse(item.iconFallbackSymbol.isEmpty)
        }
    }

    @MainActor
    func testOverviewIconsRenderVisiblePixels() throws {
        for item in overviewItems {
            let renderer = ImageRenderer(
                content: SidebarIconView(item: item, size: 32)
                    .frame(width: 32, height: 32)
            )
            renderer.scale = 1

            let image = try XCTUnwrap(renderer.nsImage, "\(item) icon did not render")
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))

            var visiblePixels = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                        visiblePixels += 1
                    }
                }
            }

            XCTAssertGreaterThan(visiblePixels, 20, "\(item) icon rendered blank")
        }
    }

    @MainActor
    func testOverviewIconsFollowTint() throws {
        for item in overviewItems {
            let name = try XCTUnwrap(item.iconResourceName)
            let renderer = ImageRenderer(
                content: SidebarIconView(
                    resourceName: name,
                    fallbackSymbol: item.iconFallbackSymbol,
                    size: 32,
                    tint: .red
                )
                .frame(width: 32, height: 32)
            )
            renderer.scale = 1

            let image = try XCTUnwrap(renderer.nsImage, "\(item) icon did not render")
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))

            var tintedPixels = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard
                        let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.alphaComponent > 0.5
                    else {
                        continue
                    }

                    if color.redComponent > 0.8,
                       color.redComponent > color.greenComponent * 2,
                       color.redComponent > color.blueComponent * 2 {
                        tintedPixels += 1
                    }
                }
            }

            XCTAssertGreaterThan(tintedPixels, 20, "\(item) icon did not follow the tint")
            XCTAssertLessThan(
                tintedPixels,
                rep.pixelsWide * rep.pixelsHigh * 9 / 10,
                "\(item) tinted the whole bounds instead of the logo shape"
            )
        }
    }
}
