#ifndef ZIG_ZAG_H
#define ZIG_ZAG_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Server statistics and metrics returned by getServerStats()
typedef struct {
    // Server state
    bool running;
    uint16_t port;
    
    // Performance metrics
    uint64_t uptime_seconds;
    uint64_t memory_bytes;      // Process RSS from OS
    float cpu_percent;          // Placeholder: always 0.0
    uint64_t network_rx_bytes;
    uint64_t network_tx_bytes;
    
    // LLM metrics
    uint32_t llm_provider_count;
    uint64_t total_tokens;      // Accumulated tokens from LLM responses
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

#ifdef __cplusplus
}
#endif

#endif // ZIG_ZAG_H
