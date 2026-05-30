//! MCP capability declarations and protocol-version negotiation.
//!
//! A present (non-null) capability struct means "I support this"; its sub-flags
//! refine the support. With `emit_null_optional_fields = false`, an absent
//! capability is omitted from the JSON entirely, and an empty struct like
//! `tools: .{}` serializes to `"tools":{}` — exactly MCP's "supported, no
//! sub-features" shape.

const std = @import("std");

pub const ClientCapabilities = struct {
    /// The client can expose filesystem roots.
    roots: ?struct { listChanged: ?bool = null } = null,
    /// The client can service `sampling/createMessage` requests.
    sampling: ?struct {} = null,
    /// The client can service `elicitation/create` requests.
    elicitation: ?struct {} = null,
    experimental: ?std.json.Value = null,
};

pub const ServerCapabilities = struct {
    tools: ?struct { listChanged: ?bool = null } = null,
    resources: ?struct { subscribe: ?bool = null, listChanged: ?bool = null } = null,
    prompts: ?struct { listChanged: ?bool = null } = null,
    logging: ?struct {} = null,
};

/// Versions this library understands, newest (and preferred) first.
pub const supported_versions = [_][]const u8{
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

/// The version we advertise when initiating, and our fallback when a peer
/// requests something we don't recognize.
pub const preferred_version = supported_versions[0];

/// Given the version a client requested in `initialize`, return the version the
/// server should respond with: the requested one if we support it, otherwise
/// our preferred version (the client then decides whether to proceed).
pub fn negotiateVersion(requested: []const u8) []const u8 {
    for (supported_versions) |v| {
        if (std.mem.eql(u8, v, requested)) return v;
    }
    return preferred_version;
}

pub fn isSupported(v: []const u8) bool {
    for (supported_versions) |s| {
        if (std.mem.eql(u8, s, v)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "negotiateVersion" {
    try testing.expectEqualStrings("2025-06-18", negotiateVersion("2025-06-18"));
    try testing.expectEqualStrings("2024-11-05", negotiateVersion("2024-11-05"));
    // Unknown -> fall back to preferred.
    try testing.expectEqualStrings(preferred_version, negotiateVersion("1999-01-01"));
}

test "capability serialization shape" {
    const s = try std.json.Stringify.valueAlloc(
        testing.allocator,
        ServerCapabilities{ .tools = .{}, .resources = .{ .subscribe = true } },
        .{ .emit_null_optional_fields = false },
    );
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(
        \\{"tools":{},"resources":{"subscribe":true}}
    , s);
}
