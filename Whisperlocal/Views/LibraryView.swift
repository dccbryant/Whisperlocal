import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: RecordingStore

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ZStack {
            BraunPalette.background.ignoresSafeArea()
            if library.recordings.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Library").braunLabel(size: 11)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(library.recordings) { rec in
                NavigationLink(value: rec) { row(for: rec) }
                    .listRowBackground(BraunPalette.background)
                    .listRowSeparatorTint(BraunPalette.divider)
                    .listRowInsets(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            library.delete(rec)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.shortDate.string(from: rec.createdAt))
                .braunDigit(size: 13)
            Text(rec.summary?.isEmpty == false ? rec.summary! : "—")
                .braunBody()
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            HStack(spacing: 14) {
                Text(durationText(rec.duration)).braunLabel(size: 9)
                let speakers = Set(rec.segments.map(\.speakerLabel)).count
                if speakers > 0 {
                    Text("\(speakers) speaker\(speakers == 1 ? "" : "s")").braunLabel(size: 9)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func durationText(_ s: TimeInterval) -> String {
        let secs = Int(s.rounded())
        let m = secs / 60
        let r = secs % 60
        return m > 0 ? String(format: "%d:%02d", m, r) : String(format: "%ds", r)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No recordings yet").braunLabel()
            Text("Recordings you make appear here.")
                .font(.system(size: 12))
                .foregroundStyle(BraunPalette.secondary)
        }
    }
}
