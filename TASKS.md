# TASKS.md - Implementation Tasks

## Story 1: PKCE Module

### Status: ✅ Complete

### Acceptance Criteria
- [ ] Generate cryptographically random 32-byte code verifier
- [ ] Base64URL encode (no padding) the verifier
- [ ] Generate SHA256 code challenge from verifier
- [ ] Place in `src/pkce.zig` for reuse

### Algorithm (RFC 7636)

```
1. Generate 32 cryptographically random bytes
2. Base64URL encode (no padding) → code_verifier (43 chars)
3. SHA256(code_verifier) → 32 bytes hash
4. Base64URL encode hash (no padding) → code_challenge (43 chars)
```

### Interface

```zig
pub const PKCE = struct {
    code_verifier: []const u8,   // Random 32 bytes, base64url encoded (43 chars)
    code_challenge: []const u8,  // SHA256(code_verifier), base64url encoded (43 chars)
};

pub fn generate(allocator: Allocator) !PKCE
pub fn deinit(self: *PKCE, allocator: Allocator) void
```

### Tasks

#### Task 1.1: Create `src/pkce.zig` with module structure ✅
- [x] Create new file with module documentation
- [x] Add imports: std, crypto, base64

#### Task 1.2: Implement `PKCE` struct ✅
- [x] Define struct with `code_verifier` and `code_challenge` fields
- [x] Both fields are `[]const u8` (allocated slices)

#### Task 1.3: Implement `generate(allocator)` function ✅
- [x] Generate 32 random bytes using `std.crypto.random`
- [x] Base64URL encode (no padding) → code_verifier
- [x] SHA256 hash the code_verifier string
- [x] Base64URL encode hash (no padding) → code_challenge
- [x] Return PKCE struct with both values

#### Task 1.4: Implement `deinit(self, allocator)` function ✅
- [x] Free code_verifier slice
- [x] Free code_challenge slice

#### Task 1.5: Verify build ✅
- [x] Run `zig build` - compilation succeeds
- [x] Run `zig test src/pkce.zig` - 2 tests pass

### Files
- `src/pkce.zig` (NEW)

### Dependencies
- None

### Usage Example (for HAI client in Story 5/6)

```zig
// Generate PKCE pair
var pkce = try pkce_mod.generate(allocator);
defer pkce.deinit(allocator);

// Use code_challenge in auth URL
const auth_url = try buildAuthUrl(pkce.code_challenge, state);

// Use code_verifier in token exchange
const tokens = try oidc.exchangeCode(auth_code, pkce.code_verifier, ...);
```

---
