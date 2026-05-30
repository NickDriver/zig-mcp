//! MCP protocol payload types (the bodies of `params` / `result`).
//!
//! Field names are deliberately camelCase to match the MCP wire format, so the
//! default `std.json` struct serialization (with `emit_null_optional_fields =
//! false`) produces spec-correct JSON with no per-field customization. Only the
//! polymorphic `Content` / `ResourceContents` unions need a custom
//! `jsonStringify`, because MCP tags them with a `"type"` field rather than the
//! `{tag: payload}` shape Zig unions serialize to by default.

const std = @import("std");
const Value = std.json.Value;
const capabilities = @import("capabilities.zig");

/// Identifies an MCP client or server implementation.
pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
};

// --- Lifecycle: initialize ------------------------------------------------

pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: capabilities.ClientCapabilities = .{},
    clientInfo: Implementation,
};

pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: capabilities.ServerCapabilities = .{},
    serverInfo: Implementation,
    instructions: ?[]const u8 = null,
};

// --- Content blocks -------------------------------------------------------

/// A piece of content returned by a tool call or carried in a prompt message.
/// MCP serializes these as `{"type": "...", ...}`.
pub const Content = union(enum) {
    text: struct { text: []const u8 },
    image: struct { data: []const u8, mimeType: []const u8 },
    audio: struct { data: []const u8, mimeType: []const u8 },

    pub fn text_(s: []const u8) Content {
        return .{ .text = .{ .text = s } };
    }

    pub fn jsonStringify(self: Content, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        switch (self) {
            .text => |t| {
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(t.text);
            },
            .image => |i| {
                try jw.write("image");
                try jw.objectField("data");
                try jw.write(i.data);
                try jw.objectField("mimeType");
                try jw.write(i.mimeType);
            },
            .audio => |au| {
                try jw.write("audio");
                try jw.objectField("data");
                try jw.write(au.data);
                try jw.objectField("mimeType");
                try jw.write(au.mimeType);
            },
        }
        try jw.endObject();
    }

    /// Parse the `{"type": "...", ...}` wire shape back into a `Content`.
    /// Strings are duped into `allocator` so the result outlives `source`.
    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: Value, options: std.json.ParseOptions) std.json.ParseFromValueError!Content {
        _ = options;
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        const type_str = switch (obj.get("type") orelse return error.MissingField) {
            .string => |s| s,
            else => return error.UnexpectedToken,
        };
        if (std.mem.eql(u8, type_str, "text")) {
            return .{ .text = .{ .text = try dupeStr(allocator, obj, "text") } };
        } else if (std.mem.eql(u8, type_str, "image")) {
            return .{ .image = .{ .data = try dupeStr(allocator, obj, "data"), .mimeType = try dupeStr(allocator, obj, "mimeType") } };
        } else if (std.mem.eql(u8, type_str, "audio")) {
            return .{ .audio = .{ .data = try dupeStr(allocator, obj, "data"), .mimeType = try dupeStr(allocator, obj, "mimeType") } };
        }
        return error.UnexpectedToken;
    }
};

fn dupeStr(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) std.json.ParseFromValueError![]const u8 {
    return switch (obj.get(key) orelse return error.MissingField) {
        .string => |s| try allocator.dupe(u8, s),
        else => error.UnexpectedToken,
    };
}

// --- Tools ----------------------------------------------------------------

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// A JSON Schema object describing the tool's arguments.
    inputSchema: Value,
};

pub const ListToolsResult = struct {
    tools: []const Tool,
    nextCursor: ?[]const u8 = null,
};

pub const CallToolParams = struct {
    name: []const u8,
    arguments: ?Value = null,
};

pub const CallToolResult = struct {
    content: []const Content,
    isError: ?bool = null,
    structuredContent: ?Value = null,
};

// --- Resources ------------------------------------------------------------

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

pub const ListResourcesResult = struct {
    resources: []const Resource,
    nextCursor: ?[]const u8 = null,
};

pub const ReadResourceParams = struct {
    uri: []const u8,
};

/// The contents of a resource: either UTF-8 `text` or base64 `blob`.
pub const ResourceContents = union(enum) {
    text: struct { uri: []const u8, mimeType: ?[]const u8 = null, text: []const u8 },
    blob: struct { uri: []const u8, mimeType: ?[]const u8 = null, blob: []const u8 },

    pub fn jsonStringify(self: ResourceContents, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .text => |t| {
                try jw.objectField("uri");
                try jw.write(t.uri);
                if (t.mimeType) |m| {
                    try jw.objectField("mimeType");
                    try jw.write(m);
                }
                try jw.objectField("text");
                try jw.write(t.text);
            },
            .blob => |b| {
                try jw.objectField("uri");
                try jw.write(b.uri);
                if (b.mimeType) |m| {
                    try jw.objectField("mimeType");
                    try jw.write(m);
                }
                try jw.objectField("blob");
                try jw.write(b.blob);
            },
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: Value, options: std.json.ParseOptions) std.json.ParseFromValueError!ResourceContents {
        _ = options;
        const obj = switch (source) {
            .object => |o| o,
            else => return error.UnexpectedToken,
        };
        const uri = try dupeStr(allocator, obj, "uri");
        const mime: ?[]const u8 = if (obj.get("mimeType")) |m| switch (m) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        } else null;
        if (obj.get("text")) |t| return switch (t) {
            .string => |s| .{ .text = .{ .uri = uri, .mimeType = mime, .text = try allocator.dupe(u8, s) } },
            else => error.UnexpectedToken,
        };
        if (obj.get("blob")) |b| return switch (b) {
            .string => |s| .{ .blob = .{ .uri = uri, .mimeType = mime, .blob = try allocator.dupe(u8, s) } },
            else => error.UnexpectedToken,
        };
        return error.MissingField;
    }
};

pub const ReadResourceResult = struct {
    contents: []const ResourceContents,
};

// --- Prompts --------------------------------------------------------------

pub const PromptArgument = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    required: ?bool = null,
};

pub const Prompt = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    title: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
};

pub const ListPromptsResult = struct {
    prompts: []const Prompt,
    nextCursor: ?[]const u8 = null,
};

pub const GetPromptParams = struct {
    name: []const u8,
    arguments: ?Value = null,
};

pub const Role = enum { user, assistant };

pub const PromptMessage = struct {
    role: Role,
    content: Content,
};

pub const GetPromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const PromptMessage,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectJson(value: anytype, expected: []const u8) !void {
    const s = try std.json.Stringify.valueAlloc(testing.allocator, value, .{ .emit_null_optional_fields = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(expected, s);
}

test "Content serializes with a type tag" {
    try expectJson(Content.text_("hi"),
        \\{"type":"text","text":"hi"}
    );
    try expectJson(Content{ .image = .{ .data = "AAAA", .mimeType = "image/png" } },
        \\{"type":"image","data":"AAAA","mimeType":"image/png"}
    );
}

test "CallToolResult omits null fields" {
    const r = CallToolResult{ .content = &.{Content.text_("4")} };
    try expectJson(r,
        \\{"content":[{"type":"text","text":"4"}]}
    );

    const e = CallToolResult{ .content = &.{Content.text_("boom")}, .isError = true };
    try expectJson(e,
        \\{"content":[{"type":"text","text":"boom"}],"isError":true}
    );
}

test "Tool serializes inputSchema" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const schema = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"type":"object","properties":{"a":{"type":"number"}}}
    , .{});
    const tool = Tool{ .name = "add", .description = "Add numbers", .inputSchema = schema };
    try expectJson(tool,
        \\{"name":"add","description":"Add numbers","inputSchema":{"type":"object","properties":{"a":{"type":"number"}}}}
    );
}

test "InitializeResult round-trips through wire shape" {
    const r = InitializeResult{
        .protocolVersion = "2025-06-18",
        .capabilities = .{ .tools = .{} },
        .serverInfo = .{ .name = "demo", .version = "0.1.0" },
    };
    try expectJson(r,
        \\{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"demo","version":"0.1.0"}}
    );
}

test "ResourceContents and prompt message" {
    try expectJson(ResourceContents{ .text = .{ .uri = "file:///a", .text = "x" } },
        \\{"uri":"file:///a","text":"x"}
    );
    try expectJson(PromptMessage{ .role = .assistant, .content = Content.text_("ok") },
        \\{"role":"assistant","content":{"type":"text","text":"ok"}}
    );
}
