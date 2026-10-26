import SwiftUI

@main
struct TingShuApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
        }
    }
}
