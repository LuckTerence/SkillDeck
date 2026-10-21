import AppKit
import SwiftUI

/// AgentIconView renders an Agent's bundled brand logo, falling back to its SF Symbol.
///
/// Monochrome logos are loaded as template images, so callers can tint them with
/// `.foregroundStyle`. Colour logos keep their original appearance.
struct AgentIconView: View {

    let agentType: AgentType
    var size: CGFloat = 16

    var body: some View {
        if let image = bundledImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: agentType.iconName)
                .font(.system(size: size * 0.85))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private var bundledImage: NSImage? {
        guard let name = agentType.iconResourceName else { return nil }
        return BundledIconCache.shared.image(
            named: name,
            subdirectory: "AgentIcons",
            isTemplate: agentType.usesTemplateIcon
        )
    }
}
