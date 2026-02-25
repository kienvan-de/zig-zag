import SwiftUI

struct ContentView: View {
    var serverState: ServerState

    var body: some View {
        Label(
            serverState.running ? "Running on port \(serverState.port)" : "Stopped",
            systemImage: serverState.running ? "circle.fill" : "circle"
        )
        .foregroundColor(serverState.running ? .green : .red)

        Divider()

        Button(serverState.running ? "Stop Server" : "Start Server") {
            if serverState.running {
                serverState.stop()
            } else {
                serverState.start()
            }
        }

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
