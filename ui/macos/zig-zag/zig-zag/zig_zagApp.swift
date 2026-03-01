import SwiftUI

@main
struct zig_zagApp: App {
    @State private var serverState = ServerState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private var menuBarIcon: String {
        switch serverState.stats.status {
        case ServerStatusRunning:
            return "waveform.path.ecg.rectangle.fill"
        case ServerStatusStarting:
            return "waveform.path.ecg.rectangle"
        case ServerStatusStopped, ServerStatusError:
            return "waveform.path.ecg.rectangle"
        default:
            return "waveform.path.ecg.rectangle"
        }
    }

    var body: some Scene {
        MenuBarExtra("zig-zag", systemImage: menuBarIcon) {
            ContentView(serverState: serverState)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: serverState.stats.status) {
            appDelegate.serverState = serverState
        }
    }
}
