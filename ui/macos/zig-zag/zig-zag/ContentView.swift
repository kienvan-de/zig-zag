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
    var cpuTimeUs: UInt64 = 0
    var networkRxBytes: UInt64 = 0
    var networkTxBytes: UInt64 = 0
    
    // LLM metrics
    var llmProviderCount: UInt32 = 0
    var inputTokens: UInt64 = 0
    var outputTokens: UInt64 = 0
    
    // Cost metrics (placeholder)
    var totalCost: Float = 0.0
    var inputCost: Float = 0.0
    var outputCost: Float = 0.0
    
    // Initialize from C struct
    init(_ cStats: CServerStats) {
        self.running = cStats.running
        self.port = cStats.port
        self.uptimeSeconds = cStats.uptime_seconds
        self.memoryBytes = cStats.memory_bytes
        self.cpuPercent = cStats.cpu_percent
        self.cpuTimeUs = cStats.cpu_time_us
        self.networkRxBytes = cStats.network_rx_bytes
        self.networkTxBytes = cStats.network_tx_bytes
        self.llmProviderCount = cStats.llm_provider_count
        self.inputTokens = cStats.input_tokens
        self.outputTokens = cStats.output_tokens
        self.totalCost = cStats.total_cost
        self.inputCost = cStats.input_cost
        self.outputCost = cStats.output_cost
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
    
    var formattedInputTokens: String {
        formatTokenCount(inputTokens)
    }
    
    var formattedOutputTokens: String {
        formatTokenCount(outputTokens)
    }
    
    private func formatTokenCount(_ tokens: UInt64) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }
    
    var formattedTotalCost: String {
        formatCost(totalCost)
    }
    
    var formattedInputCost: String {
        formatCost(inputCost)
    }
    
    var formattedOutputCost: String {
        formatCost(outputCost)
    }
    
    private func formatCost(_ cost: Float) -> String {
        if cost >= 1.0 {
            return String(format: "$%.2f", cost)
        } else if cost >= 0.01 {
            return String(format: "$%.3f", cost)
        }
        return String(format: "$%.4f", cost)
    }
}

// MARK: - Compact Menu View

struct ContentView: View {
    var serverState: ServerState
    
    var body: some View {
        VStack(alignment: .center, spacing: 0) {
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
                
                costRow
                
                Divider()
                    .padding(.vertical, 4)
            }
            
            // Action Buttons Row
            actionButtonsRow
        }
        .padding(.vertical, 8)
        .frame(width: 240)
    }
    
    // MARK: - Status Row
    
    private var statusRow: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .foregroundColor(serverState.stats.running ? .green : .red)
                    .font(.system(size: 12))
                
                Text(serverState.stats.running ? ":\(String(serverState.stats.port))" : "Stopped")
                    .font(.system(size: 13, weight: .medium))
            }
            
            Spacer()
            
            if serverState.stats.running {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    
                    Text(serverState.stats.formattedUptime)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
    
    // MARK: - Stats Row
    
    private var statsRow: some View {
        HStack {
            StatItem(icon: "memorychip", value: serverState.stats.formattedMemory)
            
            Spacer()
            
            StatItem(icon: "bolt.fill", value: serverState.stats.formattedCPU)
            
            Spacer()
            
            StatItem(icon: "arrow.up.arrow.down", value: serverState.stats.formattedNetworkTotal)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
    
    // MARK: - LLM Row
    
    private var llmRow: some View {
        HStack {
            StatItem(
                icon: "cpu",
                label: "providers",
                value: "\(serverState.stats.llmProviderCount)"
            )
            
            Spacer()
            
            StatItem(
                icon: "arrow.down.circle",
                value: serverState.stats.formattedInputTokens
            )
            
            StatItem(
                icon: "arrow.up.circle",
                value: serverState.stats.formattedOutputTokens
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
    
    // MARK: - Cost Row
    
    private var costRow: some View {
        HStack {
            StatItem(
                icon: "dollarsign.circle",
                value: serverState.stats.formattedTotalCost
            )
            
            Spacer()
            
            StatItem(
                icon: "arrow.down.circle",
                value: serverState.stats.formattedInputCost
            )
            
            StatItem(
                icon: "arrow.up.circle",
                value: serverState.stats.formattedOutputCost
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
    
    // MARK: - Action Buttons Row
    
    private var actionButtonsRow: some View {
        HStack(spacing: 0) {
            // Start/Stop Button
            Button(action: {
                if serverState.stats.running {
                    serverState.stop()
                } else {
                    serverState.start()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: serverState.stats.running ? "stop.fill" : "play.fill")
                        .font(.system(size: 11))
                    Text(serverState.stats.running ? "Stop" : "Start")
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity)
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
            
            Divider()
                .frame(height: 20)
            
            // Quit Button
            Button(action: {
                serverState.stop()
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                    Text("Quit")
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .keyboardShortcut("q", modifiers: .command)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .padding(.horizontal, 8)
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
        stats.inputTokens = 987_654
        stats.outputTokens = 246_913
        stats.totalCost = 1.23
        stats.inputCost = 0.45
        stats.outputCost = 0.78
        return stats
    }
}
