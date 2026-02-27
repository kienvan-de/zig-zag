import SwiftUI
import Observation

@Observable
class ServerState {
    var stats: ServerStats = ServerStats()
    
    private var statsTimer: Timer?
    private var lastCpuTimeUs: UInt64 = 0
    private var lastPollTime: Date = Date()
    
    func start() {
        if startServer() {
            // Initialize CPU tracking
            let cStats = getServerStats()
            lastCpuTimeUs = cStats.cpu_time_us
            lastPollTime = Date()
            stats = ServerStats(cStats)
            startStatsPolling()
        }
    }
    
    func stop() {
        stopStatsPolling()
        stopServer()
        stats = ServerStats()
        lastCpuTimeUs = 0
    }
    
    func refresh() {
        let cStats = getServerStats()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPollTime)
        
        // Calculate CPU percentage from delta
        var cpuPercent: Float = 0.0
        if elapsed > 0 && cStats.cpu_time_us >= lastCpuTimeUs {
            let cpuDeltaUs = cStats.cpu_time_us - lastCpuTimeUs
            let elapsedUs = elapsed * 1_000_000
            cpuPercent = Float(Double(cpuDeltaUs) / elapsedUs * 100.0)
        }
        
        lastCpuTimeUs = cStats.cpu_time_us
        lastPollTime = now
        
        stats = ServerStats(cStats)
        stats.cpuPercent = cpuPercent
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
