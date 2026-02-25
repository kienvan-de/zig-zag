# Issues

## High
- Unbounded request body/header growth in `src/server.zig` (`handleConnection`) enables memory-exhaustion/slow-loris DoS (no size limits, no timeouts).
- Use-after-free risk in `src/providers/sap_ai_core/transformer.zig` (`transformResponse`): `choices` shallow-copied from parsed JSON then `parsed.deinit()`.

## Medium
- “Streaming” buffers full upstream responses in `src/providers/*/client.zig` (`sendStreamingRequest`) causing memory spikes and defeating streaming.
- Model list allocations not freed after response in `src/handlers/models.zig` (`transformModelsResponse` results leak per request).

## Low
- `timeout_ms` config unused in provider clients (`src/providers/*/client.zig`), risking hung upstream calls.
- `worker_pool` queue uses `orderedRemove(0)` (`src/worker_pool.zig`), O(n) per task under load.
- `token_cache.get` returns raw pointers that can become stale if refreshed concurrently (`src/cache/token_cache.zig`).