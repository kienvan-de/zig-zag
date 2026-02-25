import SwiftUI
import Observation

@Observable
class ServerState {
    var running: Bool = false
    var port: UInt16 = 0

    init() {
        refresh()
    }

    func refresh() {
        running = isServerRunning()
        port = getServerPort()
    }

    func start() {
        _ = startServer()
        refresh()
    }

    func stop() {
        stopServer()
        refresh()
    }
}
