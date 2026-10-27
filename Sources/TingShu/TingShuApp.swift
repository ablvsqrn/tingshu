import SwiftUI

@main
struct TingShuApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
        }
        .onChange(of: scenePhase) { phase in
            // Returning from another app: if playback was interrupted while
            // away and nothing is making sound, let the player recover.
            if phase == .active { player.appBecameActive() }
        }
    }
}
