import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: RecordingStore
    @EnvironmentObject private var session: SessionStore
    @State private var query: String = ""
    @State private var showImporter = false
    @State private var importError: String?

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateAndTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var filtered: [Recording] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return library.recordings }
        return library.recordings.filter { $0.searchableText.contains(q) }
    }

    /// Groups recordings into Today / Yesterday / This Week / This Month / Older sections,
    /// preserving the newest-first order within each.
    private var sections: [(title: String, items: [Recording])] {
        let cal = Calendar.current
        let now = Date()
        var today: [Recording] = []
        var yesterday: [Recording] = []
        var thisWeek: [Recording] = []
        var thisMonth: [Recording] = []
        var older: [Recording] = []

        for rec in filtered {
            if cal.isDateInToday(rec.createdAt) {
                today.append(rec)
            } else if cal.isDateInYesterday(rec.createdAt) {
                yesterday.append(rec)
            } else if cal.isDate(rec.createdAt, equalTo: now, toGranularity: .weekOfYear) {
                thisWeek.append(rec)
            } else if cal.isDate(rec.createdAt, equalTo: now, toGranularity: .month) {
                thisMonth.append(rec)
            } else {
                older.append(rec)
            }
        }
        var out: [(String, [Recording])] = []
        if !today.isEmpty     { out.append(("Today", today)) }
        if !yesterday.isEmpty { out.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty  { out.append(("This week", thisWeek)) }
        if !thisMonth.isEmpty { out.append(("This month", thisMonth)) }
        if !older.isEmpty     { out.append(("Older", older)) }
        return out
    }

    var body: some View {
        ZStack {
            BraunPalette.background.ignoresSafeArea()
            if library.recordings.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatches
            } else {
                list
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search recordings")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Library").braunLabel(size: 11)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(BraunPalette.foreground)
                }
                .disabled(session.modelState != .ready)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    if let err = await importExternalAudio(from: url, session: session, library: library) {
                        importError = err
                    }
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Couldn't import file", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var list: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.items) { rec in
                        row(for: rec)
                            .listRowBackground(BraunPalette.background)
                            .listRowSeparatorTint(BraunPalette.divider)
                            .listRowInsets(EdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24))
                            // Value-based link in the background hides List's disclosure
                            // chevron while keeping the whole row tappable — the right edge
                            // stays a clean column of dates.
                            .background {
                                NavigationLink(value: rec) { EmptyView() }.opacity(0)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    library.delete(rec)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(section.title)
                        .braunLabel(size: 10)
                        // Optically center the all-caps label on its cap-height: trim the
                        // empty descender space beneath the glyphs, then pad symmetrically.
                        .padding(.bottom, -2)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(for rec: Recording) -> some View {
        // Three tonal levels carry the hierarchy: title (foreground), summary preview
        // (secondary), metadata (faint). Spacing is uniform so the rows share one rhythm.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(rec.title ?? "Untitled recording")
                    .font(.system(size: 15, weight: .semibold))
                    .kerning(-0.1)
                    .foregroundStyle(BraunPalette.foreground)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(timeStamp(for: rec))
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(BraunPalette.secondary)
            }
            if let summary = rec.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(BraunPalette.secondary)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Text(metaText(for: rec))
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(1.6)
                .textCase(.uppercase)
                .monospacedDigit()
                .foregroundStyle(BraunPalette.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    /// One metadata line: duration · speaker count, in tracked small caps with tabular digits.
    private func metaText(for rec: Recording) -> String {
        let dur = durationText(rec.duration)
        let speakers = rec.distinctSpeakerLabels.count
        guard speakers > 0 else { return dur }
        return "\(dur)  ·  \(speakers) speaker\(speakers == 1 ? "" : "s")"
    }

    private func timeStamp(for rec: Recording) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(rec.createdAt) || cal.isDateInYesterday(rec.createdAt) {
            return Self.timeOnly.string(from: rec.createdAt)
        }
        return Self.dateAndTime.string(from: rec.createdAt)
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

    private var noMatches: some View {
        VStack(spacing: 10) {
            Text("No matches").braunLabel()
            Text("Nothing in your library matches \"\(query)\".")
                .font(.system(size: 12))
                .foregroundStyle(BraunPalette.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
