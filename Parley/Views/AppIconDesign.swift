import SwiftUI
import UIKit

/// The Parley app icon, drawn in SwiftUI so it renders at any size cleanly.
///
/// Two ways to export it as a PNG for the asset catalog:
///
///   A. Use the in-app exporter (recommended): long-press the "Parley" title
///      in the top bar of the running app. A sheet opens with a Share button
///      that writes a 1024×1024 PNG and lets you AirDrop it to your Mac.
///
///   B. In Xcode 16+, right-click the preview canvas below → "Export Preview…".
///      Pick PNG. (This menu doesn't exist in older Xcode and is sometimes
///      flaky even when it does — use option A if it fails.)
///
/// Drop the resulting `AppIcon-1024.png` into
/// `Parley/Resources/Assets.xcassets/AppIcon.appiconset/`.
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

/// Sheet shown when the user long-presses the title — renders the icon, writes the PNG to
/// a temp file, and surfaces a share button so it can be AirDropped to a Mac.
struct IconExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var exportedURL: URL?

    var body: some View {
        ZStack {
            BraunPalette.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Export app icon").braunLabel(size: 11).padding(.top, 12)

                ParleyIconView()
                    .scaleEffect(220.0 / 1024.0)     // visually show at 220 pt
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 48, style: .continuous)
                            .stroke(BraunPalette.divider, lineWidth: 1)
                    )

                Text("Saves AppIcon-1024.png and opens the share sheet so you can AirDrop it to your Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(BraunPalette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let url = exportedURL {
                    ShareLink(item: url, preview: SharePreview("Parley app icon", image: Image(systemName: "app.fill"))) {
                        Text("Share PNG").braunLabel(size: 11)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Rectangle().stroke(BraunPalette.foreground, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        exportedURL = renderAndWritePNG()
                    } label: {
                        Text("Render PNG").braunLabel(size: 11)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Rectangle().stroke(BraunPalette.foreground, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button("Close") { dismiss() }
                    .foregroundStyle(BraunPalette.secondary)
                    .padding(.bottom, 16)
            }
        }
    }

    @MainActor
    private func renderAndWritePNG() -> URL? {
        let renderer = ImageRenderer(content: ParleyIconView())
        renderer.scale = 1.0      // ParleyIconView is already 1024×1024
        guard let uiImage = renderer.uiImage,
              let data = uiImage.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-1024.png")
        do {
            try data.write(to: url)
            return url
        } catch {
            print("[IconExport] write failed: \(error)")
            return nil
        }
    }
}

#Preview("Icon at home-screen size") {
    ParleyIconView()
        .scaleEffect(180.0 / 1024.0)
        .frame(width: 180, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .padding()
}
