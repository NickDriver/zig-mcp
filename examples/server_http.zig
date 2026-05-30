//! Example MCP server over HTTP. Serves the same `add`/`echo` tools as the
//! stdio example at http://127.0.0.1:7345/mcp.
//!
//! Test with curl:
//!   curl -s http://127.0.0.1:7345/mcp -H 'content-type: application/json' \
//!     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'

const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var server = mcp.Server.init(gpa, .{ .name = "zig-mcp-http-example", .version = "0.1.0" });
    defer server.deinit();

    try server.addTool(.{
        .name = "add",
        .description = "Add two numbers and return the sum.",
        .input_schema =
        \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}
        ,
    }, addTool);

    std.debug.print("zig-mcp HTTP server listening on http://127.0.0.1:7345/mcp\n", .{});
    try mcp.transport.http.serve(gpa, &server, "127.0.0.1", 7345, .{});
}

fn addTool(ctx: mcp.Server.ToolContext) anyerror!mcp.CallToolResult {
    const obj = switch (ctx.arguments) {
        .object => |o| o,
        else => return error.InvalidArguments,
    };
    const a = numberField(obj, "a") orelse return error.MissingArgument;
    const b = numberField(obj, "b") orelse return error.MissingArgument;
    const text = try std.fmt.allocPrint(ctx.arena, "{d}", .{a + b});
    return ctx.text(text);
}

fn numberField(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    return switch (obj.get(key) orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}
