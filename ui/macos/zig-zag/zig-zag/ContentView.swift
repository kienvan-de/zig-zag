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

// MARK: - Server Statistics Model

struct ServerStats {
    // Server state
    var status: ServerStatus = ServerStatusStopped
    var errorCode: ServerErrorCode = ServerErrorNone
    var port: UInt16 = 0
    
    // Performance metrics
    var uptimeSeconds: UInt64 = 0
    var memoryBytes: UInt64 = 0
    var cpuPercent: Float = 0.0
    var cpuTimeUs: UInt64 = 0
    var networkRxBytes: UInt64 = 0
    var networkTxBytes: UInt64 = 0
    
    // LLM metrics
    var llmProviderConfigured: UInt32 = 0
    var llmProviderActive: UInt32 = 0
    var inputTokens: UInt64 = 0
    var outputTokens: UInt64 = 0
    
    // Cost metrics
    var totalCost: Float = 0.0
    var inputCost: Float = 0.0
    var outputCost: Float = 0.0
    
    // Statistics display options
    var showPerformance: Bool = true
    var showLLM: Bool = true
    var showCost: Bool = true
    
    // Cost controls
    var costControlsEnabled: Bool = false
    var costBudget: Float = 0.0
    
    // Initialize from C struct
    init(_ cStats: CServerStats) {
        self.status = cStats.status
        self.errorCode = cStats.error_code
        self.port = cStats.port
        self.uptimeSeconds = cStats.uptime_seconds
        self.memoryBytes = cStats.memory_bytes
        self.cpuPercent = cStats.cpu_percent
        self.cpuTimeUs = cStats.cpu_time_us
        self.networkRxBytes = cStats.network_rx_bytes
        self.networkTxBytes = cStats.network_tx_bytes
        self.llmProviderConfigured = cStats.llm_provider_configured
        self.llmProviderActive = cStats.llm_provider_active
        self.inputTokens = cStats.input_tokens
        self.outputTokens = cStats.output_tokens
        self.totalCost = cStats.total_cost
        self.inputCost = cStats.input_cost
        self.outputCost = cStats.output_cost
        self.showPerformance = cStats.show_performance
        self.showLLM = cStats.show_llm
        self.showCost = cStats.show_cost
        self.costControlsEnabled = cStats.cost_controls_enabled
        self.costBudget = cStats.cost_budget
    }
    
    // Default initializer
    init() {}
    
    // MARK: - Convenience Properties
    
    var isRunning: Bool {
        status == ServerStatusRunning
    }
    
    var isStarting: Bool {
        status == ServerStatusStarting
    }
    
    var isStopped: Bool {
        status == ServerStatusStopped
    }
    
    var hasError: Bool {
        status == ServerStatusError
    }
    
    var errorMessage: String? {
        guard hasError else { return nil }
        switch errorCode {
        case ServerErrorConfigLoadFailed:
            return "Config load failed"
        case ServerErrorPortInUse:
            return "Port in use"
        case ServerErrorWorkerPoolInitFailed:
            return "Worker pool init failed"
        case ServerErrorLogInitFailed:
            return "Log init failed"
        case ServerErrorThreadSpawnFailed:
            return "Thread spawn failed"
        case ServerErrorAuthFailed:
            return "Auth failed"
        default:
            return "Unknown error"
        }
    }
    
    /// Whether the cost row should be visible
    var shouldShowCostRow: Bool {
        costControlsEnabled || showCost
    }
    
    /// Cost display value: remaining budget or total spent
    var formattedCostDisplay: String {
        if costControlsEnabled {
            let remaining = costBudget - totalCost
            return formatCost(remaining) + " left"
        }
        return formattedTotalCost
    }
    
    /// Cost icon: gauge for budget mode, dollar sign for normal
    var costIcon: String {
        costControlsEnabled ? "gauge.with.needle" : "dollarsign.circle"
    }
    
    /// Cost icon color based on budget remaining
    var costIconColor: Color {
        guard costControlsEnabled, costBudget > 0 else { return .secondary }
        let remaining = costBudget - totalCost
        let ratio = remaining / costBudget
        if ratio <= 0 { return .red }
        if ratio <= 0.2 { return .orange }
        return .secondary
    }
    
    /// Cost tooltip based on mode
    var costTooltip: String {
        costControlsEnabled ? "Budget remaining" : "Total cost"
    }
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
            // Row 1: Status (always visible)
            statusRow
            
            // Rows 2-4 only when running
            if serverState.stats.isRunning {
                // Row 2: Performance (RAM, CPU, Network)
                if serverState.stats.showPerformance {
                    Divider()
                        .padding(.vertical, 4)
                    statsRow
                }
                
                // Row 3: LLM (Providers, Tokens)
                if serverState.stats.showLLM {
                    Divider()
                        .padding(.vertical, 4)
                    llmRow
                }
                
                // Row 4: Cost
                if serverState.stats.shouldShowCostRow {
                    Divider()
                        .padding(.vertical, 4)
                    costRow
                }
            }
            
            // Row 5: Action buttons (always visible)
            Divider()
                .padding(.vertical, 4)
            actionButtonsRow
        }
        .padding(.vertical, 8)
        .frame(width: 240)
    }
    
    // MARK: - Status Row
    
    private var statusGlobeColor: Color {
        if serverState.isStopping { return .orange }
        switch serverState.stats.status {
        case ServerStatusRunning:
            return .green
        case ServerStatusStarting:
            return .yellow
        case ServerStatusError:
            return .red
        case ServerStatusStopped:
            return .gray
        default:
            return .gray
        }
    }
    
    private var statusText: String {
        if serverState.isStopping { return "Stopping..." }
        switch serverState.stats.status {
        case ServerStatusRunning:
            return ":\(String(serverState.stats.port))"
        case ServerStatusStarting:
            return "Starting..."
        case ServerStatusError:
            return serverState.stats.errorMessage ?? "Error"
        case ServerStatusStopped:
            return "Stopped"
        default:
            return "Stopped"
        }
    }
    
    private var coreVersion: String {
        if let ptr = getVersion() {
            return String(cString: ptr)
        }
        return "?"
    }
    
    private var statusRow: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .foregroundColor(statusGlobeColor)
                    .font(.system(size: 12))
                
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
            }
            .toolTip("Server port")
            
            Spacer()
            
            if serverState.stats.isRunning && !serverState.isStopping {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    
                    Text(serverState.stats.formattedUptime)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .toolTip("Server uptime")
                
                Spacer()
            }
            
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                
                Text(coreVersion)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .toolTip("Core version")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
    
    // MARK: - Stats Row
    
    private var statsRow: some View {
        HStack {
            StatItem(icon: "memorychip", value: serverState.stats.formattedMemory, tooltip: "Memory usage")
            
            Spacer()
            
            StatItem(icon: "bolt.fill", value: serverState.stats.formattedCPU, tooltip: "CPU usage")
            
            Spacer()
            
            StatItem(icon: "arrow.up.arrow.down", value: serverState.stats.formattedNetworkTotal, tooltip: "Network I/O")
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
                value: "\(serverState.stats.llmProviderActive)/\(serverState.stats.llmProviderConfigured)",
                tooltip: "Active / configured"
            )
            
            Spacer()
            
            StatItem(
                icon: "arrow.down.circle",
                value: serverState.stats.formattedInputTokens,
                tooltip: "Input tokens"
            )
            
            StatItem(
                icon: "arrow.up.circle",
                value: serverState.stats.formattedOutputTokens,
                tooltip: "Output tokens"
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
    
    // MARK: - Cost Row
    
    private var costRow: some View {
        HStack {
            StatItem(
                icon: serverState.stats.costIcon,
                value: serverState.stats.formattedCostDisplay,
                tooltip: serverState.stats.costTooltip,
                iconColor: serverState.stats.costIconColor
            )
            
            Spacer()
            
            StatItem(
                icon: "arrow.down.circle",
                value: serverState.stats.formattedInputCost,
                tooltip: "Input cost"
            )
            
            StatItem(
                icon: "arrow.up.circle",
                value: serverState.stats.formattedOutputCost,
                tooltip: "Output cost"
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
    
    // MARK: - Action Buttons Row
    
    private var isStartButtonEnabled: Bool {
        !serverState.isStopping && (serverState.stats.isStopped || serverState.stats.hasError)
    }
    
    private var isStopButtonEnabled: Bool {
        !serverState.isStopping && serverState.stats.isRunning
    }
    
    private var actionButtonsRow: some View {
        HStack(spacing: 0) {
            // Start/Stop Button
            Button(action: {
                if serverState.stats.isRunning {
                    serverState.stop()
                } else {
                    serverState.start()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: serverState.stats.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 11))
                    Text(serverState.stats.isRunning ? "Stop" : "Start")
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
                .opacity(serverState.stats.isRunning ? (isStopButtonEnabled ? 1.0 : 0.5) : (isStartButtonEnabled ? 1.0 : 0.5))
            }
            .buttonStyle(.plain)
            .disabled(serverState.stats.isRunning ? !isStopButtonEnabled : !isStartButtonEnabled)
            .onHover { hovering in
                if hovering && (serverState.stats.isRunning ? isStopButtonEnabled : isStartButtonEnabled) {
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
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
    var tooltip: String? = nil
    var iconColor: Color = .secondary
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
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
        .toolTip(tooltip)
    }
}

// MARK: - Native Tooltip Support
// SwiftUI's .help() does not work inside MenuBarExtra(.window).
// This bridges to AppKit's native NSView.toolTip which works everywhere.

struct TooltipView: NSViewRepresentable {
    let tooltip: String
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    func toolTip(_ tip: String?) -> some View {
        overlay(Group {
            if let tip = tip, !tip.isEmpty {
                TooltipView(tooltip: tip)
            }
        })
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
        stats.status = ServerStatusRunning
        stats.errorCode = ServerErrorNone
        stats.port = 8080
        stats.uptimeSeconds = 9252
        stats.memoryBytes = 134_217_728
        stats.cpuPercent = 12.3
        stats.networkRxBytes = 48_000_000
        stats.networkTxBytes = 2_200_000
        stats.llmProviderConfigured = 3
        stats.llmProviderActive = 2
        stats.inputTokens = 987_654
        stats.outputTokens = 246_913
        stats.totalCost = 1.23
        stats.inputCost = 0.45
        stats.outputCost = 0.78
        stats.showPerformance = true
        stats.showLLM = true
        stats.showCost = true
        stats.costControlsEnabled = false
        stats.costBudget = 0.0
        return stats
    }
    
    static var mockStopped: ServerStats {
        var stats = ServerStats()
        stats.status = ServerStatusStopped
        return stats
    }
    
    static var mockStarting: ServerStats {
        var stats = ServerStats()
        stats.status = ServerStatusStarting
        return stats
    }
    
    static var mockError: ServerStats {
        var stats = ServerStats()
        stats.status = ServerStatusError
        stats.errorCode = ServerErrorConfigLoadFailed
        return stats
    }
}
