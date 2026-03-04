// Copyright 2025 kienvan.de
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SwiftUI
import Observation

@Observable
class ServerState {
    var stats: ServerStats = ServerStats()
    var isStopping: Bool = false
    
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
        isStopping = true
        
        // Run blocking stopServer() on background thread to keep UI responsive
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            stopServer()
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                let cStats = getServerStats()
                self.stats = ServerStats(cStats)
                self.lastCpuTimeUs = 0
                self.isStopping = false
            }
        }
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
        
        // Stop polling if server is no longer running
        if !stats.isRunning && !stats.isStarting {
            stopStatsPolling()
        }
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
