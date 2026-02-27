import SwiftUI

@main
struct zig_zagApp: App {
    @State private var serverState = ServerState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("zig-zag", systemImage: serverState.stats.running ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle") {
            ContentView(serverState: serverState)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: serverState.stats.running) {
            appDelegate.serverState = serverState
        }
    }
}
