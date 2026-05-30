//! MCP client: drives a remote server over any `Transport`.
//!
//! Requests are correlated by a monotonic integer id. `call` sends a request
//! and reads messages until the matching response arrives, declining any
//! server-initiated requests (sampling/elicitation are not implemented in v1)
//! and ignoring interim notifications.
//!
//! Typed helpers (`listTools`, `callTool`, ...) take an `out_arena` allocator
//! and return results allocated from it, so ownership is the caller's and the
//! transient response buffers are freed internally.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const capabilities = @import("capabilities.zig");
const Transport = @import("transport.zig").Transport;

pub const Client = struct {
    gpa: Allocator,
    transport: Transport,
    info: protocol.Implementation,
    caps: capabilities.ClientCapabilities,
    /// Holds data that lives for the client's lifetime (negotiated version).
    arena: std.heap.ArenaAllocator,
    next_id: i64 = 1,
    negotiated_version: ?[]const u8 = null,
    initialized: bool = false,

    pub const Options = struct {
        name: []const u8,
        version: []const u8,
        title: ?[]const u8 = null,
        capabilities: capabilities.ClientCapabilities = .{},
    };

    pub fn init(gpa: Allocator, transport: Transport, opts: Options) Client {
        return .{
            .gpa = gpa,
            .transport = transport,
            .info = .{ .name = opts.name, .version = opts.version, .title = opts.title },
            .caps = opts.capabilities,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Client) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn nextId(self: *Client) jsonrpc.Id {
        const id: jsonrpc.Id = .{ .number = self.next_id };
        self.next_id += 1;
        return id;
    }

    /// Send a request and return the matching response message. The caller owns
    /// the returned `Message` and must `deinit` it.
    pub fn call(self: *Client, method: []const u8, params: anytype) !jsonrpc.Message {
        const id = self.nextId();
        const req = try jsonrpc.writeRequest(self.gpa, id, method, params);
        defer self.gpa.free(req);
        try self.transport.writeMessage(req);

        while (true) {
            const raw = (try self.transport.readMessage(self.gpa)) orelse return error.ConnectionClosed;
            var msg = jsonrpc.Message.parse(self.gpa, raw) catch {
                self.gpa.free(raw);
                continue; // skip undecodable input
            };
            self.gpa.free(raw); // Message owns its data (alloc_always)

            if (msg.isResponse()) {
                if (msg.id().eql(id)) return msg;
                msg.deinit(); // response to something else; ignore
                continue;
            }
            if (msg.isRequest()) {
                // A server-initiated request (e.g. sampling). v1 declines.
                const reply = try jsonrpc.writeError(self.gpa, msg.id(), jsonrpc.error_code.method_not_found, "Client does not support server-initiated requests");
                defer self.gpa.free(reply);
                try self.transport.writeMessage(reply);
                msg.deinit();
                continue;
            }
            // Notification: ignore.
            msg.deinit();
        }
    }

    /// Perform the `initialize` handshake and send `notifications/initialized`.
    pub fn initialize(self: *Client) !void {
        const params = protocol.InitializeParams{
            .protocolVersion = capabilities.preferred_version,
            .capabilities = self.caps,
            .clientInfo = self.info,
        };
        var msg = try self.call("initialize", params);
        defer msg.deinit();

        if (msg.err() != null) return error.InitializeFailed;
        const result = msg.result() orelse return error.InitializeFailed;
        const version = switch (result) {
            .object => |o| switch (o.get("protocolVersion") orelse return error.InitializeFailed) {
                .string => |s| s,
                else => return error.InitializeFailed,
            },
            else => return error.InitializeFailed,
        };
        self.negotiated_version = try self.arena.allocator().dupe(u8, version);

        const note = try jsonrpc.writeNotification(self.gpa, "notifications/initialized", jsonrpc.omit);
        defer self.gpa.free(note);
        try self.transport.writeMessage(note);
        self.initialized = true;
    }

    pub fn ping(self: *Client) !void {
        var msg = try self.call("ping", jsonrpc.omit);
        defer msg.deinit();
        if (msg.err() != null) return error.RequestFailed;
    }

    /// List the server's tools. The returned slice is allocated from `out_arena`.
    pub fn listTools(self: *Client, out_arena: Allocator) ![]const protocol.Tool {
        var msg = try self.call("tools/list", jsonrpc.omit);
        defer msg.deinit();
        const result = try requireResult(msg);
        const parsed = try std.json.parseFromValueLeaky(protocol.ListToolsResult, out_arena, result, .{ .ignore_unknown_fields = true });
        return parsed.tools;
    }

    /// Call a tool. `arguments` is the JSON arguments object (or `null`). The
    /// result is allocated from `out_arena`.
    pub fn callTool(self: *Client, out_arena: Allocator, name: []const u8, arguments: ?Value) !protocol.CallToolResult {
        const params = protocol.CallToolParams{ .name = name, .arguments = arguments };
        var msg = try self.call("tools/call", params);
        defer msg.deinit();
        const result = try requireResult(msg);
        return std.json.parseFromValueLeaky(protocol.CallToolResult, out_arena, result, .{ .ignore_unknown_fields = true });
    }

    /// List the server's resources. Allocated from `out_arena`.
    pub fn listResources(self: *Client, out_arena: Allocator) ![]const protocol.Resource {
        var msg = try self.call("resources/list", jsonrpc.omit);
        defer msg.deinit();
        const result = try requireResult(msg);
        const parsed = try std.json.parseFromValueLeaky(protocol.ListResourcesResult, out_arena, result, .{ .ignore_unknown_fields = true });
        return parsed.resources;
    }

    /// Read a resource by uri. Allocated from `out_arena`.
    pub fn readResource(self: *Client, out_arena: Allocator, uri: []const u8) !protocol.ReadResourceResult {
        var msg = try self.call("resources/read", protocol.ReadResourceParams{ .uri = uri });
        defer msg.deinit();
        const result = try requireResult(msg);
        return std.json.parseFromValueLeaky(protocol.ReadResourceResult, out_arena, result, .{ .ignore_unknown_fields = true });
    }

    /// List the server's prompts. Allocated from `out_arena`.
    pub fn listPrompts(self: *Client, out_arena: Allocator) ![]const protocol.Prompt {
        var msg = try self.call("prompts/list", jsonrpc.omit);
        defer msg.deinit();
        const result = try requireResult(msg);
        const parsed = try std.json.parseFromValueLeaky(protocol.ListPromptsResult, out_arena, result, .{ .ignore_unknown_fields = true });
        return parsed.prompts;
    }

    /// Fetch a prompt by name. `arguments` is the JSON arguments object (or
    /// `null`). Allocated from `out_arena`.
    pub fn getPrompt(self: *Client, out_arena: Allocator, name: []const u8, arguments: ?Value) !protocol.GetPromptResult {
        var msg = try self.call("prompts/get", protocol.GetPromptParams{ .name = name, .arguments = arguments });
        defer msg.deinit();
        const result = try requireResult(msg);
        return std.json.parseFromValueLeaky(protocol.GetPromptResult, out_arena, result, .{ .ignore_unknown_fields = true });
    }

    fn requireResult(msg: jsonrpc.Message) !Value {
        if (msg.err() != null) return error.RequestFailed;
        return msg.result() orelse error.RequestFailed;
    }
};

// ---------------------------------------------------------------------------
// Tests: full client <-> server loopback over the memory transport.
// ---------------------------------------------------------------------------

const testing = std.testing;
const memory = @import("transport/memory.zig");
const Server = @import("server.zig").Server;

fn addToolHandler(ctx: Server.ToolContext) anyerror!protocol.CallToolResult {
    const obj = switch (ctx.arguments) {
        .object => |o| o,
        else => return error.InvalidArgument,
    };
    const a: f64 = switch (obj.get("a") orelse return error.MissingArg) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return error.InvalidArgument,
    };
    const b: f64 = switch (obj.get("b") orelse return error.MissingArg) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return error.InvalidArgument,
    };
    const text = try std.fmt.allocPrint(ctx.arena, "{d}", .{a + b});
    return ctx.text(text);
}

fn docResourceHandler(ctx: Server.ResourceContext) anyerror!protocol.ReadResourceResult {
    const body = try std.fmt.allocPrint(ctx.arena, "contents of {s}", .{ctx.uri});
    const contents = try ctx.arena.alloc(protocol.ResourceContents, 1);
    contents[0] = .{ .text = .{ .uri = ctx.uri, .mimeType = "text/plain", .text = body } };
    return .{ .contents = contents };
}

fn greetPromptHandler(ctx: Server.PromptContext) anyerror!protocol.GetPromptResult {
    const who = switch (ctx.arguments) {
        .object => |o| switch (o.get("name") orelse Value.null) {
            .string => |s| s,
            else => "world",
        },
        else => "world",
    };
    const text = try std.fmt.allocPrint(ctx.arena, "Hello, {s}!", .{who});
    const messages = try ctx.arena.alloc(protocol.PromptMessage, 1);
    messages[0] = .{ .role = .user, .content = .{ .text = .{ .text = text } } };
    return .{ .messages = messages };
}

test "client <-> server loopback: initialize, listTools, callTool" {
    const a = testing.allocator;

    var server = Server.init(a, .{ .name = "loop-server", .version = "0.1.0" });
    defer server.deinit();
    try server.addTool(.{
        .name = "add",
        .description = "Add two numbers",
        .input_schema =
        \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}}}
        ,
    }, addToolHandler);

    const pipe = try memory.Pipe.create(a);
    defer pipe.destroy();

    const ServerThread = struct {
        fn run(s: *Server, t: Transport) void {
            s.run(t) catch {};
        }
    };
    const th = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, pipe.transportB() });

    var client = Client.init(a, pipe.transportA(), .{ .name = "loop-client", .version = "0.1.0" });
    defer client.deinit();

    // Handshake.
    try client.initialize();
    try testing.expect(client.initialized);
    try testing.expectEqualStrings("2025-06-18", client.negotiated_version.?);

    // List tools.
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const tools = try client.listTools(arena.allocator());
        try testing.expectEqual(@as(usize, 1), tools.len);
        try testing.expectEqualStrings("add", tools[0].name);
    }

    // Call a tool and read the text content back.
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const args = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
            \\{"a":7,"b":8}
        , .{});
        const res = try client.callTool(arena.allocator(), "add", args);
        try testing.expectEqual(@as(usize, 1), res.content.len);
        try testing.expectEqualStrings("15", res.content[0].text.text);
        try testing.expect(res.isError == null or res.isError.? == false);
    }

    // ping round-trips.
    try client.ping();

    // Shut the server down.
    pipe.transportA().close();
    th.join();
}

test "client <-> server loopback: resources and prompts" {
    const a = testing.allocator;

    var server = Server.init(a, .{ .name = "rp-server", .version = "0.1.0" });
    defer server.deinit();
    try server.addResource(.{
        .uri = "mem://doc",
        .name = "doc",
        .description = "A demo document",
        .mimeType = "text/plain",
    }, docResourceHandler);
    try server.addPrompt(.{
        .name = "greet",
        .description = "Greet someone",
        .arguments = &.{.{ .name = "name", .required = false }},
    }, greetPromptHandler);

    const pipe = try memory.Pipe.create(a);
    defer pipe.destroy();

    const ServerThread = struct {
        fn run(s: *Server, t: Transport) void {
            s.run(t) catch {};
        }
    };
    const th = try std.Thread.spawn(.{}, ServerThread.run, .{ &server, pipe.transportB() });

    var client = Client.init(a, pipe.transportA(), .{ .name = "rp-client", .version = "0.1.0" });
    defer client.deinit();
    try client.initialize();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();

    // Resources.
    const resources = try client.listResources(al);
    try testing.expectEqual(@as(usize, 1), resources.len);
    try testing.expectEqualStrings("mem://doc", resources[0].uri);

    const read = try client.readResource(al, "mem://doc");
    try testing.expectEqual(@as(usize, 1), read.contents.len);
    try testing.expectEqualStrings("contents of mem://doc", read.contents[0].text.text);

    // Prompts.
    const prompts = try client.listPrompts(al);
    try testing.expectEqual(@as(usize, 1), prompts.len);
    try testing.expectEqualStrings("greet", prompts[0].name);

    const args = try std.json.parseFromSliceLeaky(Value, al,
        \\{"name":"Zig"}
    , .{});
    const prompt = try client.getPrompt(al, "greet", args);
    try testing.expectEqual(@as(usize, 1), prompt.messages.len);
    try testing.expectEqual(protocol.Role.user, prompt.messages[0].role);
    try testing.expectEqualStrings("Hello, Zig!", prompt.messages[0].content.text.text);

    pipe.transportA().close();
    th.join();
}
