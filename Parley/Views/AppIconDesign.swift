import SwiftUI

/// The Parley app icon, drawn in SwiftUI so it renders at any size cleanly.
/// I can't write binary PNGs from this environment, so the workflow is:
///
///   1. In Xcode, open this file.
///   2. The #Preview at the bottom shows the icon. Right-click the canvas →
///      "Export Preview…" → save as `AppIcon-1024.png`.
///   3. Drop the file into Parley/Resources/Assets.xcassets/AppIcon.appiconset/.
///
/// The design: warm Braun beige background, charcoal lowercase "p" mark slightly
/// off-center to make room for the signature Braun-orange dot in the corner —
/// the same dot used as the recording cue in the app.
struct ParleyIconView: View {
    var body: some View {
        ZStack {
            Color(red: 0.910, green: 0.885, blue: 0.825)
            Text("p")
                .font(.system(size: 720, weight: .medium, design: .serif))
                .foregroundStyle(Color(red: 0.145, green: 0.145, blue: 0.145))
                .offset(x: -40, y: 60)
            Circle()
                .fill(Color(red: 0.905, green: 0.290, blue: 0.110))
                .frame(width: 140, height: 140)
                .offset(x: 260, y: -260)
        }
        .frame(width: 1024, height: 1024)
    }
}

#Preview("App icon 1024 × 1024") {
    ParleyIconView()
}

#Preview("App icon at home-screen size") {
    ParleyIconView()
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
}
