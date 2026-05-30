//! Example MCP server over stdio. Exposes two tools: `add` and `echo`.
//!
//! Run it directly and feed it JSON-RPC lines on stdin, or register it as a
//! local MCP server in an MCP-capable client (e.g. Claude Code/Desktop).

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var server = mcp.Server.init(gpa, .{
        .name = "zig-mcp-example",
        .version = "0.1.0",
        .instructions = "A demo server with `add` and `echo` tools.",
    });
    defer server.deinit();

    try server.addTool(.{
        .name = "add",
        .description = "Add two numbers and return the sum.",
        .input_schema =
        \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}
        ,
    }, addTool);

    try server.addTool(.{
        .name = "echo",
        .description = "Echo back the provided text.",
        .input_schema =
        \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
        ,
    }, echoTool);

    try server.addResource(.{
        .uri = "mem://readme",
        .name = "readme",
        .description = "A static in-memory document.",
        .mimeType = "text/plain",
    }, readmeResource);

    try server.addPrompt(.{
        .name = "greet",
        .description = "Produce a friendly greeting.",
        .arguments = &.{.{ .name = "name", .description = "Who to greet", .required = false }},
    }, greetPrompt);

    const t = try mcp.transport.stdio.StdioTransport.init(gpa);
    defer t.deinit();

    try server.run(t.transport());
}

fn addTool(ctx: mcp.Server.ToolContext) anyerror!mcp.CallToolResult {
    const a = numberField(ctx.arguments, "a") orelse return error.MissingArgument;
    const b = numberField(ctx.arguments, "b") orelse return error.MissingArgument;
    const text = try std.fmt.allocPrint(ctx.arena, "{d}", .{a + b});
    return ctx.text(text);
}

fn echoTool(ctx: mcp.Server.ToolContext) anyerror!mcp.CallToolResult {
    const text = switch (ctx.arguments) {
        .object => |o| switch (o.get("text") orelse return error.MissingArgument) {
            .string => |s| s,
            else => return error.InvalidArgument,
        },
        else => return error.InvalidArgument,
    };
    return ctx.text(text);
}

fn readmeResource(ctx: mcp.Server.ResourceContext) anyerror!mcp.protocol.ReadResourceResult {
    const contents = try ctx.arena.alloc(mcp.protocol.ResourceContents, 1);
    contents[0] = .{ .text = .{ .uri = ctx.uri, .mimeType = "text/plain", .text = "Hello from a zig-mcp resource." } };
    return .{ .contents = contents };
}

fn greetPrompt(ctx: mcp.Server.PromptContext) anyerror!mcp.protocol.GetPromptResult {
    const who = switch (ctx.arguments) {
        .object => |o| switch (o.get("name") orelse std.json.Value.null) {
            .string => |s| s,
            else => "world",
        },
        else => "world",
    };
    const text = try std.fmt.allocPrint(ctx.arena, "Hello, {s}! Welcome to zig-mcp.", .{who});
    const messages = try ctx.arena.alloc(mcp.protocol.PromptMessage, 1);
    messages[0] = .{ .role = .user, .content = .{ .text = .{ .text = text } } };
    return .{ .messages = messages };
}

fn numberField(v: std.json.Value, key: []const u8) ?f64 {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(key) orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}
