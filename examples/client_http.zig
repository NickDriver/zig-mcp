//! Example MCP client over HTTP. Connects to a server (default
//! http://127.0.0.1:7345/mcp), handshakes, lists tools, and calls `add`.
//!
//! Start examples/server_http first, then run this.

const std = @import("std");
const mcp = @import("mcp");

const endpoint = "http://127.0.0.1:7345/mcp";

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const t = try mcp.transport.http.HttpClientTransport.init(gpa, endpoint);
    defer t.deinit();

    var client = mcp.Client.init(gpa, t.transport(), .{
        .name = "zig-mcp-http-client",
        .version = "0.1.0",
    });
    defer client.deinit();

    try client.initialize();
    std.debug.print("connected to {s}; negotiated protocol {s}\n", .{ endpoint, client.negotiated_version.? });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try client.listTools(a);
    std.debug.print("server exposes {d} tool(s):\n", .{tools.len});
    for (tools) |tool| std.debug.print("  - {s}\n", .{tool.name});

    const args = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"a":40,"b":2}
    , .{});
    const result = try client.callTool(a, "add", args);
    if (result.content.len > 0) std.debug.print("add(40, 2) = {s}\n", .{result.content[0].text.text});
}
