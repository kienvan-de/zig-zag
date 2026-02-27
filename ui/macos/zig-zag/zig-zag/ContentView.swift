import SwiftUI

// MARK: - Server Statistics Model

struct ServerStats {
    // Server state
    var running: Bool = false
    var port: UInt16 = 0
    
    // Performance metrics
    var uptimeSeconds: UInt64 = 0
    var memoryBytes: UInt64 = 0
    var cpuPercent: Float = 0.0
    var networkRxBytes: UInt64 = 0
    var networkTxBytes: UInt64 = 0
    
    // LLM metrics
    var llmProviderCount: UInt32 = 0
    var totalTokens: UInt64 = 0
    
    // Initialize from C struct
    init(_ cStats: CServerStats) {
        self.running = cStats.running
        self.port = cStats.port
        self.uptimeSeconds = cStats.uptime_seconds
        self.memoryBytes = cStats.memory_bytes
        self.cpuPercent = cStats.cpu_percent
        self.networkRxBytes = cStats.network_rx_bytes
        self.networkTxBytes = cStats.network_tx_bytes
        self.llmProviderCount = cStats.llm_provider_count
        self.totalTokens = cStats.total_tokens
    }
    
    // Default initializer
    init() {}
}

// MARK: - Formatting Helpers

extension ServerStats {
    var formattedUptime: String {
        let hours = uptimeSeconds / 3600
        let minutes = (uptimeSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            let seconds = uptimeSeconds % 60
            return "\(minutes)m \(seconds)s"
        }
    }
    
    var formattedMemory: String {
        let mb = Double(memoryBytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
    
    var formattedCPU: String {
        return String(format: "%.0f%%", cpuPercent)
    }
    
    var formattedNetworkTotal: String {
        let total = networkRxBytes + networkTxBytes
        let mb = Double(total) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
    
    var formattedTokens: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
        } else if totalTokens >= 1_000 {
            return String(format: "%.1fK", Double(totalTokens) / 1_000)
        }
        return "\(totalTokens)"
    }
}

// MARK: - Compact Menu View

struct ContentView: View {
    var serverState: ServerState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status Row
            statusRow
            
            Divider()
                .padding(.vertical, 4)
            
            // Stats Row (only when running)
            if serverState.stats.running {
                statsRow
                
                Divider()
                    .padding(.vertical, 4)
                
                llmRow
                
                Divider()
                    .padding(.vertical, 4)
            }
            
            // Action Button
            actionButton
            
            Divider()
                .padding(.vertical, 4)
            
            // Quit Button
            quitButton
        }
        .padding(.vertical, 8)
        .frame(width: 280)
    }
    
    // MARK: - Status Row
    
    private var statusRow: some View {
        HStack {
            Image(systemName: serverState.stats.running ? "circle.fill" : "circle")
                .foregroundColor(serverState.stats.running ? .green : .red)
                .font(.system(size: 8))
            
            Text(serverState.stats.running ? "Running on :\(serverState.stats.port)" : "Stopped")
                .font(.system(size: 13, weight: .medium))
            
            Spacer()
            
            if serverState.stats.running {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                
                Text(serverState.stats.formattedUptime)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
    
    // MARK: - Stats Row
    
    private var statsRow: some View {
        HStack(spacing: 16) {
            StatItem(icon: "memorychip", value: serverState.stats.formattedMemory)
            StatItem(icon: "bolt.fill", value: serverState.stats.formattedCPU)
            StatItem(icon: "network", value: serverState.stats.formattedNetworkTotal)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    // MARK: - LLM Row
    
    private var llmRow: some View {
        HStack(spacing: 16) {
            StatItem(
                icon: "cpu",
                label: "providers",
                value: "\(serverState.stats.llmProviderCount)"
            )
            StatItem(
                icon: "text.bubble",
                label: "tokens",
                value: serverState.stats.formattedTokens
            )
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    
    // MARK: - Action Button
    
    private var actionButton: some View {
        Button(action: {
            if serverState.stats.running {
                serverState.stop()
            } else {
                serverState.start()
            }
        }) {
            HStack {
                Image(systemName: serverState.stats.running ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                Text(serverState.stats.running ? "Stop Server" : "Start Server")
                    .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
    
    // MARK: - Quit Button
    
    private var quitButton: some View {
        Button(action: {
            serverState.stop()
            NSApp.terminate(nil)
        }) {
            HStack {
                Text("Quit")
                    .font(.system(size: 13))
                Spacer()
                Text("⌘Q")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - Stat Item Component

struct StatItem: View {
    let icon: String
    var label: String? = nil
    let value: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            
            if let label = label {
                Text("\(value) \(label)")
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
            } else {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let state = ServerState()
    state.stats = ServerStats.mock
    
    return ContentView(serverState: state)
        .frame(width: 300, height: 250)
}

// MARK: - Mock Data for Preview

extension ServerStats {
    static var mock: ServerStats {
        var stats = ServerStats()
        stats.running = true
        stats.port = 8080
        stats.uptimeSeconds = 9252
        stats.memoryBytes = 134_217_728
        stats.cpuPercent = 12.3
        stats.networkRxBytes = 48_000_000
        stats.networkTxBytes = 2_200_000
        stats.llmProviderCount = 3
        stats.totalTokens = 1_234_567
        return stats
    }
}
