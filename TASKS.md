# TASKS.md - Implementation Tasks

## Story 2: OIDC Discovery Module

### Status: ✅ Complete

### Acceptance Criteria
- [ ] Fetch `{auth_domain}{oidc_config_path}` from configured endpoint
- [ ] Parse JSON response into `OIDCConfig` struct
- [ ] Extract: `authorization_endpoint`, `token_endpoint`, `jwks_uri`, `end_session_endpoint`
- [ ] Cache OIDC configs in `app_cache.zig`
- [ ] Design as member/component for provider client integration
- [ ] Place in `src/oidc.zig` for reuse

### Design

OIDC helper as a **member** of provider client (like HttpClient):

```zig
// Provider client owns OIDC helper
pub const HaiClient = struct {
    http_client: HttpClient,
    oidc: OIDC,              // OIDC helper as member
    // ...
};
```

### Interface

```zig
// src/oidc.zig

pub const OIDC = struct {
    allocator: Allocator,
    auth_domain: []const u8,
    config_path: []const u8,
    config: ?OIDCConfig,      // Cached discovery result
    
    pub fn init(allocator: Allocator, auth_domain: []const u8, config_path: []const u8) OIDC;
    pub fn deinit(self: *OIDC) void;
    
    /// Discover OIDC endpoints (checks app_cache, then fetches)
    pub fn discover(self: *OIDC, http_client: *HttpClient) !*const OIDCConfig;
};

pub const OIDCConfig = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    jwks_uri: []const u8,
    end_session_endpoint: ?[]const u8,
};
```

### Tasks

#### Task 2.1: Create `src/oidc.zig` with module structure ✅
- [x] Create new file with module documentation
- [x] Add imports: std, HttpClient, app_cache, log

#### Task 2.2: Implement `OIDCConfig` struct ✅
- [x] Define struct with required fields (issuer, authorization_endpoint, token_endpoint, jwks_uri)
- [x] Add optional field: end_session_endpoint
- [x] Implement `deinit()` to free allocated strings

#### Task 2.3: Implement `OIDC` struct ✅
- [x] Define struct with allocator, auth_domain, config_path, config fields
- [x] Implement `init()` - store config, set config to null
- [x] Implement `deinit()` - free config if set

#### Task 2.4: Implement `discover()` function ✅
- [x] Check if self.config already set → return cached (Level 1: instance cache)
- [x] Build cache key: `oidc:{auth_domain}`
- [x] Check app_cache for cached config (Level 2: app cache)
- [x] If cache miss: fetch from `{auth_domain}{config_path}` (Level 3: HTTP)
- [x] Parse JSON response into OIDCConfig
- [x] Store in app_cache (raw JSON for reuse)
- [x] Store in self.config (parsed struct)
- [x] Return pointer to config

#### Task 2.5: Verify build ✅
- [x] Run `zig build` - compilation succeeds

### Caching Strategy

```
discover() called:
  1. Check self.config (instance cache) → return if set
  2. Check app_cache with key "oidc:{auth_domain}" → parse and return if hit
  3. HTTP GET {auth_domain}{config_path}
  4. Parse JSON → OIDCConfig
  5. Store in app_cache (raw JSON for reuse across instances)
  6. Store in self.config (parsed struct for this instance)
  7. Return &self.config
```

### Files
- `src/oidc.zig` (NEW)
- `src/cache/app_cache.zig` (existing, used for caching)

### Dependencies
- Story 0 (Config Design) ✅ Complete
- Story 1 (PKCE Module) ✅ Complete

---
