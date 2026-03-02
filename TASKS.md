# Story 5 (fix): Cross-request token + api_base persistence

## Problem
Client is created fresh per request — `api_token` and `api_base` were lost between requests,
causing a token endpoint hit on every single request.

## Solution
- `api_token`  → store/restore via `token_cache` (keyed `"copilot"`)
- `api_base`   → store/restore via `app_cache`   (keyed `"copilot:api_base"`)

## Tasks

- [x] 5.f1: Import `token_cache` in `client.zig`
- [x] 5.f2: After `fetchCopilotToken()` succeeds, persist `api_token` to `token_cache` and `api_base` to `app_cache`
- [x] 5.f3: In `getAccessToken()`, check `token_cache` as fast path 2 (before hitting token endpoint)
- [x] 5.f4: On token_cache hit, restore `api_base` from `app_cache` into `self.api_base`
- [x] 5.f5: Build ✅

## Story 5: COMPLETE ✅
