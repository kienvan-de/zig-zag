import SwiftUI
import Observation

@Observable
class ServerState {
    var stats: ServerStats = ServerStats()
    
    private var statsTimer: Timer?
    
    func start() {
        if startServer() {
            refresh()
            startStatsPolling()
        }
    }
    
    func stop() {
        stopStatsPolling()
        stopServer()
        stats = ServerStats()
    }
    
    func refresh() {
        let cStats = getServerStats()
        stats = ServerStats(cStats)
    }
    
    private func startStatsPolling() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    
    private func stopStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = nil
    }
}
