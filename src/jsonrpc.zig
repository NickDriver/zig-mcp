//! JSON-RPC 2.0 framing for MCP.
//!
//! MCP messages are JSON-RPC 2.0 over a transport. This module owns the
//! envelope: parsing incoming bytes into a `Message` view and serializing
//! outgoing requests / responses / notifications. The typed payloads
//! (params/result bodies) live in `protocol.zig`.
//!
//! Note: MCP forbids JSON-RPC batching, so we only ever deal with single
//! top-level messages.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Writer = std.Io.Writer;

pub const version = "2.0";

/// Standard JSON-RPC 2.0 error codes (MCP reuses these verbatim).
pub const error_code = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};

/// A JSON-RPC id: `null`, an integer, or a string. Echoed verbatim in the
/// matching response so the peer can correlate it.
pub const Id = union(enum) {
    null,
    number: i64,
    string: []const u8,

    /// Build an `Id` from the `id` field of a parsed message. Anything that
    /// isn't an integer or string (including a missing field) becomes `.null`.
    pub fn fromValue(v: Value) Id {
        return switch (v) {
            .integer => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            else => .null,
        };
    }

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .null => b == .null,
            .number => |x| b == .number and b.number == x,
            .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        };
    }

    pub fn jsonStringify(self: Id, jw: anytype) !void {
        switch (self) {
            .null => try jw.write(null),
            .number => |n| try jw.write(n),
            .string => |s| try jw.write(s),
        }
    }
};

/// A read-only view over a parsed incoming JSON-RPC message. Owns the arena
/// backing the parsed value; call `deinit` when done.
pub const Message = struct {
    parsed: std.json.Parsed(Value),

    pub fn parse(gpa: Allocator, bytes: []const u8) std.json.ParseError(std.json.Scanner)!Message {
        // `alloc_always` makes the parsed value own all of its string data in
        // its own arena, so the caller may free `bytes` immediately and the
        // `Message` remains valid until `deinit`.
        return .{ .parsed = try std.json.parseFromSlice(Value, gpa, bytes, .{ .allocate = .alloc_always }) };
    }

    pub fn deinit(self: *Message) void {
        self.parsed.deinit();
    }

    pub fn root(self: Message) Value {
        return self.parsed.value;
    }

    fn field(self: Message, key: []const u8) ?Value {
        return switch (self.parsed.value) {
            .object => |o| o.get(key),
            else => null,
        };
    }

    pub fn method(self: Message) ?[]const u8 {
        const m = self.field("method") orelse return null;
        return switch (m) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn hasId(self: Message) bool {
        return self.field("id") != null;
    }

    pub fn id(self: Message) Id {
        return Id.fromValue(self.field("id") orelse return .null);
    }

    /// The `params` value, or JSON `null` if absent.
    pub fn params(self: Message) Value {
        return self.field("params") orelse Value.null;
    }

    pub fn result(self: Message) ?Value {
        return self.field("result");
    }

    pub fn err(self: Message) ?Value {
        return self.field("error");
    }

    pub fn isRequest(self: Message) bool {
        return self.method() != null and self.hasId();
    }

    pub fn isNotification(self: Message) bool {
        return self.method() != null and !self.hasId();
    }

    pub fn isResponse(self: Message) bool {
        return self.method() == null and (self.result() != null or self.err() != null);
    }
};

const stringify_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// Pass this as the `params`/`result` argument to omit the field entirely.
pub const omit = null;

fn writeOptionalField(jw: *std.json.Stringify, name: []const u8, payload: anytype) !void {
    if (@TypeOf(payload) == @TypeOf(null)) return;
    try jw.objectField(name);
    try jw.write(payload);
}

/// Serialize a request. Pass `jsonrpc.omit` for `params` to drop the field.
/// Caller owns the returned slice.
pub fn writeRequest(gpa: Allocator, id: Id, method: []const u8, params: anytype) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = stringify_options };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write(version);
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("method");
    try jw.write(method);
    try writeOptionalField(&jw, "params", params);
    try jw.endObject();
    return try aw.toOwnedSlice();
}

/// Serialize a notification (a request with no id). Caller owns the slice.
pub fn writeNotification(gpa: Allocator, method: []const u8, params: anytype) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = stringify_options };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write(version);
    try jw.objectField("method");
    try jw.write(method);
    try writeOptionalField(&jw, "params", params);
    try jw.endObject();
    return try aw.toOwnedSlice();
}

/// Serialize a successful response. Caller owns the slice.
pub fn writeResult(gpa: Allocator, id: Id, result: anytype) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = stringify_options };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write(version);
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("result");
    try jw.write(result);
    try jw.endObject();
    return try aw.toOwnedSlice();
}

/// Serialize an error response. Caller owns the slice.
pub fn writeError(gpa: Allocator, id: Id, code: i32, message: []const u8) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = stringify_options };
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write(version);
    try jw.objectField("id");
    try jw.write(id);
    try jw.objectField("error");
    try jw.beginObject();
    try jw.objectField("code");
    try jw.write(code);
    try jw.objectField("message");
    try jw.write(message);
    try jw.endObject();
    try jw.endObject();
    return try aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "writeRequest with and without params" {
    const a = testing.allocator;

    const with = try writeRequest(a, .{ .number = 1 }, "tools/list", .{ .cursor = "abc" });
    defer a.free(with);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"abc"}}
    , with);

    const without = try writeRequest(a, .{ .string = "req-7" }, "ping", omit);
    defer a.free(without);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":"req-7","method":"ping"}
    , without);
}

test "writeNotification" {
    const a = testing.allocator;
    const n = try writeNotification(a, "notifications/initialized", omit);
    defer a.free(n);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    , n);
}

test "writeResult and writeError" {
    const a = testing.allocator;

    const ok = try writeResult(a, .{ .number = 2 }, .{ .pong = true });
    defer a.free(ok);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"result":{"pong":true}}
    , ok);

    const bad = try writeError(a, .null, error_code.method_not_found, "Method not found");
    defer a.free(bad);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32601,"message":"Method not found"}}
    , bad);
}

test "Message parse: request / notification / response" {
    const a = testing.allocator;

    var req = try Message.parse(a,
        \\{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"add"}}
    );
    defer req.deinit();
    try testing.expect(req.isRequest());
    try testing.expect(!req.isNotification());
    try testing.expectEqualStrings("tools/call", req.method().?);
    try testing.expect(req.id().eql(.{ .number = 42 }));
    try testing.expectEqualStrings("add", req.params().object.get("name").?.string);

    var note = try Message.parse(a,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer note.deinit();
    try testing.expect(note.isNotification());
    try testing.expect(!note.isRequest());

    var resp = try Message.parse(a,
        \\{"jsonrpc":"2.0","id":"x","result":{"ok":true}}
    );
    defer resp.deinit();
    try testing.expect(resp.isResponse());
    try testing.expect(resp.id().eql(.{ .string = "x" }));
    try testing.expect(resp.result().?.object.get("ok").?.bool);
}

test "Id.eql" {
    try testing.expect((Id{ .number = 5 }).eql(.{ .number = 5 }));
    try testing.expect(!(Id{ .number = 5 }).eql(.{ .number = 6 }));
    try testing.expect((Id{ .string = "a" }).eql(.{ .string = "a" }));
    try testing.expect(!(Id{ .string = "a" }).eql(.{ .number = 1 }));
    try testing.expect((Id{ .null = {} }).eql(.null));
}
