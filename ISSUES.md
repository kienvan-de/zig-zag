# Issues

## High
- Unbounded request body/header growth in `src/server.zig` (`handleConnection`) enables memory-exhaustion/slow-loris DoS (no size limits, no timeouts).
- Use-after-free risk in `src/providers/sap_ai_core/transformer.zig` (`transformResponse`): `choices` shallow-copied from parsed JSON then `parsed.deinit()`.

## Medium
- “Streaming” buffers full upstream responses in `src/providers/*/client.zig` (`sendStreamingRequest`) causing memory spikes and defeating streaming.
- Model list allocations not freed after response in `src/handlers/models.zig` (`transformModelsResponse` results leak per request).