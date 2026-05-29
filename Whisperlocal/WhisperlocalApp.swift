import SwiftUI

@main
struct WhisperlocalApp: App {
    @StateObject private var library = RecordingStore()
    @StateObject private var session: SessionStore

    init() {
        let library = RecordingStore()
        _library = StateObject(wrappedValue: library)
        _session = StateObject(wrappedValue: SessionStore(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(library)
                .preferredColorScheme(.light)
                .tint(BraunPalette.accent)
        }
    }
}
