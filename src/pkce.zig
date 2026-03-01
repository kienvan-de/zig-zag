//! PKCE (Proof Key for Code Exchange) Module
//!
//! Implements RFC 7636 for secure OAuth 2.0 authorization code flow.
//! Used by providers that require PKCE (e.g., HAI with OIDC).
//!
//! Algorithm:
//! 1. Generate 32 cryptographically random bytes
//! 2. Base64URL encode (no padding) → code_verifier (43 chars)
//! 3. SHA256(code_verifier) → 32 bytes hash
//! 4. Base64URL encode hash (no padding) → code_challenge (43 chars)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64url = std.base64.url_safe_no_pad;

/// PKCE code verifier and challenge pair
pub const PKCE = struct {
    /// Random 32 bytes, base64url encoded (43 chars)
    code_verifier: []const u8,
    /// SHA256(code_verifier), base64url encoded (43 chars)
    code_challenge: []const u8,

    /// Free allocated memory
    pub fn deinit(self: *PKCE, allocator: Allocator) void {
        allocator.free(self.code_verifier);
        allocator.free(self.code_challenge);
        self.* = undefined;
    }
};

/// Generate a new PKCE code verifier and challenge pair
///
/// Returns a PKCE struct with:
/// - code_verifier: 43 character base64url string (from 32 random bytes)
/// - code_challenge: 43 character base64url string (SHA256 of verifier)
///
/// Caller owns the returned memory and must call `deinit()` to free.
pub fn generate(allocator: Allocator) !PKCE {
    // Step 1: Generate 32 cryptographically random bytes
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Step 2: Base64URL encode (no padding) → code_verifier
    // 32 bytes → 43 base64url characters
    const verifier_len = base64url.Encoder.calcSize(32);
    const code_verifier = try allocator.alloc(u8, verifier_len);
    errdefer allocator.free(code_verifier);
    _ = base64url.Encoder.encode(code_verifier, &random_bytes);

    // Step 3: SHA256(code_verifier) → 32 bytes hash
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(code_verifier, &hash, .{});

    // Step 4: Base64URL encode hash (no padding) → code_challenge
    // 32 bytes → 43 base64url characters
    const challenge_len = base64url.Encoder.calcSize(Sha256.digest_length);
    const code_challenge = try allocator.alloc(u8, challenge_len);
    errdefer allocator.free(code_challenge);
    _ = base64url.Encoder.encode(code_challenge, &hash);

    return PKCE{
        .code_verifier = code_verifier,
        .code_challenge = code_challenge,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "generate produces valid PKCE pair" {
    const allocator = std.testing.allocator;

    var pkce = try generate(allocator);
    defer pkce.deinit(allocator);

    // Verify lengths: 32 bytes base64url encoded = 43 chars
    try std.testing.expectEqual(@as(usize, 43), pkce.code_verifier.len);
    try std.testing.expectEqual(@as(usize, 43), pkce.code_challenge.len);

    // Verify challenge is SHA256 of verifier
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(pkce.code_verifier, &hash, .{});

    var expected_challenge: [43]u8 = undefined;
    _ = base64url.Encoder.encode(&expected_challenge, &hash);

    try std.testing.expectEqualSlices(u8, &expected_challenge, pkce.code_challenge);
}

test "generate produces unique values" {
    const allocator = std.testing.allocator;

    var pkce1 = try generate(allocator);
    defer pkce1.deinit(allocator);

    var pkce2 = try generate(allocator);
    defer pkce2.deinit(allocator);

    // Two generations should produce different verifiers
    try std.testing.expect(!std.mem.eql(u8, pkce1.code_verifier, pkce2.code_verifier));
    try std.testing.expect(!std.mem.eql(u8, pkce1.code_challenge, pkce2.code_challenge));
}
