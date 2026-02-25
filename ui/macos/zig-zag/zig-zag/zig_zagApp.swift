import SwiftUI

@main
struct zig_zagApp: App {
    @State private var serverState = ServerState()

    var body: some Scene {
        MenuBarExtra("zig-zag", systemImage: serverState.running ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle") {
            ContentView(serverState: serverState)
        }
        .menuBarExtraStyle(.menu)
    }
}
