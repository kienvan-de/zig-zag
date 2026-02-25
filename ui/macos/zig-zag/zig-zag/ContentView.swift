import SwiftUI

struct ContentView: View {
    @State private var running: Bool = isServerRunning()
    @State private var port: UInt16 = getServerPort()

    var body: some View {
        // Status
        Label(
            running ? "Running on port \(port)" : "Stopped",
            systemImage: running ? "circle.fill" : "circle"
        )
        .foregroundColor(running ? .green : .red)

        Divider()

        // Start / Stop
        Button(running ? "Stop Server" : "Start Server") {
            if running {
                stopServer()
            } else {
                _ = startServer()
            }
            running = isServerRunning()
            port = getServerPort()
        }

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
