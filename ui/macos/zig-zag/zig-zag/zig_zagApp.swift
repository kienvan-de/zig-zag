import SwiftUI

@main
struct zig_zagApp: App {
    var body: some Scene {
        MenuBarExtra("zig-zag", systemImage: "network") {
            ContentView()
        }
        .menuBarExtraStyle(.menu)
    }
}
