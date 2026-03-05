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


#ifndef ZIG_ZAG_H
#define ZIG_ZAG_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Server lifecycle status
typedef enum {
    ServerStatusStopped = 0,   // Server is not running
    ServerStatusStarting = 1,  // Server is initializing (loading config, auth flows, etc.)
    ServerStatusRunning = 2,   // Server is running and accepting requests
    ServerStatusError = 3      // Server encountered an error during startup
} ServerStatus;

/// Error codes for server startup failures
typedef enum {
    ServerErrorNone = 0,              // No error
    ServerErrorConfigLoadFailed = 1,  // Failed to load/parse config.json
    ServerErrorPortInUse = 2,         // Server port already in use
    ServerErrorWorkerPoolInitFailed = 3, // Failed to initialize worker pool
    ServerErrorLogInitFailed = 4,     // Failed to initialize logging
    ServerErrorThreadSpawnFailed = 5, // Failed to spawn server thread
} ServerErrorCode;

/// Server statistics and metrics returned by getServerStats()
typedef struct {
    // Server state
    ServerStatus status;       // Server lifecycle status
    ServerErrorCode error_code; // Error code if status == ServerStatusError
    uint16_t port;
    
    // Performance metrics
    uint64_t uptime_seconds;
    uint64_t memory_bytes;      // Process RSS from OS
    float cpu_percent;          // Placeholder: always 0.0 (calculated by Swift)
    uint64_t cpu_time_us;       // Total CPU time (user + system) in microseconds
    uint64_t network_rx_bytes;
    uint64_t network_tx_bytes;
    
    // LLM metrics
    uint32_t llm_provider_configured; // Total providers in config
    uint64_t input_tokens;      // Accumulated input/prompt tokens
    uint64_t output_tokens;     // Accumulated output/completion tokens
    
    // Cost metrics (placeholder: always 0.0)
    float total_cost;
    float input_cost;
    float output_cost;
    
    // Statistics display options
    bool show_performance;      // Show RAM, CPU, Network row
    bool show_llm;              // Show Providers, Tokens row
    bool show_cost;             // Show Cost row (overridden by cost_controls)
    
    // Cost controls
    bool cost_controls_enabled; // Budget mode active
    float cost_budget;          // Budget limit (0.0 if not enabled)
} CServerStats;

/// Start the server.
/// @return true on success, false if already running or startup fails.
bool startServer(void);

/// Stop the server. Blocks until the server thread has exited.
/// Safe to call if server is not running.
void stopServer(void);

/// Get current server statistics and metrics.
/// @return CServerStats struct with current values (zeroed if server not running)
CServerStats getServerStats(void);

/// Get the zig-zag core version string.
/// @return Null-terminated version string (e.g. "0.3.1"). Static lifetime.
const char* getVersion(void);

#ifdef __cplusplus
}
#endif

#endif // ZIG_ZAG_H
