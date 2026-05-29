import SwiftUI

/// Braun / Dieter Rams 1968 inspired design tokens.
///
/// Restrained palette, generous negative space, uppercase letter-spaced labels, geometric
/// forms, no shadows, no gradients. Accent color used sparingly — only for the record state
/// and the most important affordance on screen.
enum BraunPalette {
    static let background  = Color(red: 0.945, green: 0.925, blue: 0.875)  // warm off-white
    static let surface     = Color(red: 0.910, green: 0.885, blue: 0.825)  // beige card
    static let foreground  = Color(red: 0.145, green: 0.145, blue: 0.145)  // charcoal
    static let secondary   = Color(red: 0.435, green: 0.415, blue: 0.380)  // warm gray
    static let divider     = Color(red: 0.780, green: 0.745, blue: 0.665)  // hairline
    static let accent      = Color(red: 0.905, green: 0.290, blue: 0.110)  // Braun orange
    static let recording   = Color(red: 0.700, green: 0.150, blue: 0.080)  // muted record red
}

struct BraunLabel: ViewModifier {
    var size: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .semibold))
            .kerning(2.2)
            .textCase(.uppercase)
            .foregroundStyle(BraunPalette.secondary)
    }
}

struct BraunBody: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(BraunPalette.foreground)
            .lineSpacing(2)
    }
}

struct BraunDigit: ViewModifier {
    var size: CGFloat = 13
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(BraunPalette.foreground)
    }
}

extension View {
    func braunLabel(size: CGFloat = 10) -> some View { modifier(BraunLabel(size: size)) }
    func braunBody() -> some View { modifier(BraunBody()) }
    func braunDigit(size: CGFloat = 13) -> some View { modifier(BraunDigit(size: size)) }
}

struct BraunCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).braunLabel()
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BraunPalette.surface)
    }
}

struct BraunDivider: View {
    var body: some View {
        Rectangle()
            .fill(BraunPalette.divider)
            .frame(height: 1)
    }
}

struct BraunIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(BraunPalette.foreground)
                .frame(width: 36, height: 36)
                .background(
                    Rectangle()
                        .stroke(BraunPalette.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
