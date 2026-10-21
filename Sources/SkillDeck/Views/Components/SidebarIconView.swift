import SwiftUI

/// Renders one of the monochrome overview icons bundled in `Resources/SidebarIcons`.
///
/// The icons are template images, so they follow `tint` in both light and dark mode.
struct SidebarIconView: View {

    let resourceName: String
    let fallbackSymbol: String
    var size: CGFloat = 16
    var tint: Color

    var body: some View {
        Group {
            if let image = BundledIconCache.shared.image(
                named: resourceName,
                subdirectory: "SidebarIcons",
                isTemplate: true
            ) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.85))
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }
}

extension SidebarIconView {
    init(item: SidebarItem, size: CGFloat = 16) {
        self.init(
            resourceName: item.iconResourceName ?? "",
            fallbackSymbol: item.iconFallbackSymbol,
            size: size,
            tint: item.brandColor
        )
    }
}
