//! Example MCP client over stdio. Spawns an MCP server as a child process,
//! performs the handshake, lists its tools, and calls one.
//!
//! Usage: client_stdio   (spawns ./zig-out/bin/server_stdio)

const std = @import("std");
const mcp = @import("mcp");

const server_cmd = "zig-out/bin/server_stdio";

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // An Io for spawning/reaping the child process.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Spawn the server with piped stdin/stdout.
    var child = try std.process.spawn(io, .{
        .argv = &.{server_cmd},
        .stdin = .pipe,
        .stdout = .pipe,
    });

    // Read from the child's stdout; write to its stdin.
    const t = try mcp.transport.stdio.StdioTransport.fromFiles(gpa, child.stdout.?, child.stdin.?, 64 * 1024);
    defer t.deinit();

    var client = mcp.Client.init(gpa, t.transport(), .{
        .name = "zig-mcp-example-client",
        .version = "0.1.0",
    });
    defer client.deinit();

    try client.initialize();
    std.debug.print("connected; server negotiated protocol {s}\n", .{client.negotiated_version.?});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const tools = try client.listTools(a);
    std.debug.print("server exposes {d} tool(s):\n", .{tools.len});
    for (tools) |tool| {
        std.debug.print("  - {s}: {s}\n", .{ tool.name, tool.description orelse "" });
    }

    const args = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"a":40,"b":2}
    , .{});
    const result = try client.callTool(a, "add", args);
    if (result.content.len > 0) {
        std.debug.print("add(40, 2) = {s}\n", .{result.content[0].text.text});
    }

    // Close the child's stdin so it sees EOF and exits, then reap it.
    child.stdin.?.close(io);
    child.stdin = null;
    _ = try child.wait(io);
}
