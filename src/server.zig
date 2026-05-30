//! MCP server: a registry of tools (and, from P5, resources/prompts) plus a
//! dispatch loop that handles the built-in protocol methods over any
//! `Transport`.
//!
//! Lifecycle per request: parse the envelope, run the handler inside a
//! per-request arena, serialize the response into a `gpa`-owned buffer, write
//! it, then free the buffer and reset the arena. Handlers may allocate freely
//! in the arena; their output is copied during serialization before the arena
//! is released.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const capabilities = @import("capabilities.zig");
const Transport = @import("transport.zig").Transport;

pub const Server = struct {
    gpa: Allocator,
    info: protocol.Implementation,
    instructions: ?[]const u8,
    /// Owns the duped tool names/descriptions and parsed input schemas.
    registry: std.heap.ArenaAllocator,
    tools: std.StringArrayHashMapUnmanaged(ToolEntry) = .{},
    resources: std.StringArrayHashMapUnmanaged(ResourceEntry) = .{},
    prompts: std.StringArrayHashMapUnmanaged(PromptEntry) = .{},
    /// The protocol version agreed during `initialize` (set on handshake).
    negotiated_version: []const u8 = capabilities.preferred_version,
    initialized: bool = false,

    pub const Options = struct {
        name: []const u8,
        version: []const u8,
        title: ?[]const u8 = null,
        instructions: ?[]const u8 = null,
    };

    /// Context handed to a tool handler. `arena` is reset after the call; do
    /// not retain anything allocated from it past the handler's return.
    pub const ToolContext = struct {
        server: *Server,
        arena: Allocator,
        /// The tool's `arguments` object, or JSON `null` if none were sent.
        arguments: Value,

        /// Convenience: a successful result of a single text block. The content
        /// slice is allocated in the request arena (returning `&.{...}` from a
        /// handler would dangle, since it points at the handler's stack frame).
        pub fn text(ctx: ToolContext, s: []const u8) !protocol.CallToolResult {
            const content = try ctx.arena.alloc(protocol.Content, 1);
            content[0] = .{ .text = .{ .text = s } };
            return .{ .content = content };
        }
    };

    pub const ToolHandler = *const fn (ctx: ToolContext) anyerror!protocol.CallToolResult;

    pub const ToolDef = struct {
        name: []const u8,
        description: ?[]const u8 = null,
        title: ?[]const u8 = null,
        /// A JSON Schema (as text) describing the tool's arguments object.
        input_schema: []const u8 = "{\"type\":\"object\"}",
    };

    const ToolEntry = struct {
        tool: protocol.Tool,
        handler: ToolHandler,
    };

    // --- Resources ---

    pub const ResourceContext = struct {
        server: *Server,
        arena: Allocator,
        uri: []const u8,
    };

    pub const ResourceHandler = *const fn (ctx: ResourceContext) anyerror!protocol.ReadResourceResult;

    pub const ResourceDef = struct {
        uri: []const u8,
        name: []const u8,
        title: ?[]const u8 = null,
        description: ?[]const u8 = null,
        mimeType: ?[]const u8 = null,
    };

    const ResourceEntry = struct {
        resource: protocol.Resource,
        handler: ResourceHandler,
    };

    // --- Prompts ---

    pub const PromptContext = struct {
        server: *Server,
        arena: Allocator,
        /// The prompt's `arguments` object, or JSON `null`.
        arguments: Value,
    };

    pub const PromptHandler = *const fn (ctx: PromptContext) anyerror!protocol.GetPromptResult;

    pub const PromptDef = struct {
        name: []const u8,
        description: ?[]const u8 = null,
        title: ?[]const u8 = null,
        arguments: ?[]const protocol.PromptArgument = null,
    };

    const PromptEntry = struct {
        prompt: protocol.Prompt,
        handler: PromptHandler,
    };

    pub fn init(gpa: Allocator, opts: Options) Server {
        return .{
            .gpa = gpa,
            .info = .{ .name = opts.name, .version = opts.version, .title = opts.title },
            .instructions = opts.instructions,
            .registry = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Server) void {
        self.tools.deinit(self.gpa);
        self.resources.deinit(self.gpa);
        self.prompts.deinit(self.gpa);
        self.registry.deinit();
        self.* = undefined;
    }

    /// Register a tool. Names, descriptions and schemas are copied, so the
    /// caller need not keep `def`'s slices alive.
    pub fn addTool(self: *Server, def: ToolDef, handler: ToolHandler) !void {
        const a = self.registry.allocator();
        const name = try a.dupe(u8, def.name);
        const description = if (def.description) |d| try a.dupe(u8, d) else null;
        const title = if (def.title) |t| try a.dupe(u8, t) else null;
        const schema = try std.json.parseFromSliceLeaky(Value, a, def.input_schema, .{});
        try self.tools.put(self.gpa, name, .{
            .tool = .{ .name = name, .description = description, .title = title, .inputSchema = schema },
            .handler = handler,
        });
    }

    /// Register a readable resource. Strings are copied.
    pub fn addResource(self: *Server, def: ResourceDef, handler: ResourceHandler) !void {
        const a = self.registry.allocator();
        const uri = try a.dupe(u8, def.uri);
        try self.resources.put(self.gpa, uri, .{
            .resource = .{
                .uri = uri,
                .name = try a.dupe(u8, def.name),
                .title = if (def.title) |t| try a.dupe(u8, t) else null,
                .description = if (def.description) |d| try a.dupe(u8, d) else null,
                .mimeType = if (def.mimeType) |m| try a.dupe(u8, m) else null,
            },
            .handler = handler,
        });
    }

    /// Register a prompt. Strings (including argument metadata) are copied.
    pub fn addPrompt(self: *Server, def: PromptDef, handler: PromptHandler) !void {
        const a = self.registry.allocator();
        const name = try a.dupe(u8, def.name);
        var arguments: ?[]const protocol.PromptArgument = null;
        if (def.arguments) |src| {
            const dst = try a.alloc(protocol.PromptArgument, src.len);
            for (src, 0..) |arg, i| dst[i] = .{
                .name = try a.dupe(u8, arg.name),
                .description = if (arg.description) |d| try a.dupe(u8, d) else null,
                .required = arg.required,
            };
            arguments = dst;
        }
        try self.prompts.put(self.gpa, name, .{
            .prompt = .{
                .name = name,
                .description = if (def.description) |d| try a.dupe(u8, d) else null,
                .title = if (def.title) |t| try a.dupe(u8, t) else null,
                .arguments = arguments,
            },
            .handler = handler,
        });
    }

    /// Serve requests until the transport reaches end-of-stream.
    pub fn run(self: *Server, transport: Transport) !void {
        while (try transport.readMessage(self.gpa)) |raw| {
            defer self.gpa.free(raw);
            try self.handleMessage(transport, raw);
        }
    }

    fn handleMessage(self: *Server, transport: Transport, raw: []const u8) !void {
        const response = (try self.handleRaw(raw)) orelse return;
        try self.writeAndFree(transport, response);
    }

    /// Process one raw incoming message and return the response payload
    /// (`gpa`-owned; caller frees), or `null` if the message was a notification
    /// (no response). Transport-independent — used by both the stdio run loop
    /// and the HTTP transport.
    pub fn handleRaw(self: *Server, raw: []const u8) !?[]u8 {
        var msg = jsonrpc.Message.parse(self.gpa, raw) catch {
            return try jsonrpc.writeError(self.gpa, .null, jsonrpc.error_code.parse_error, "Parse error");
        };
        defer msg.deinit();

        if (msg.isNotification()) {
            self.handleNotification(msg);
            return null;
        }
        if (!msg.isRequest()) return null; // responses: server issues no requests yet

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        return self.dispatch(&arena, msg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try jsonrpc.writeError(self.gpa, msg.id(), jsonrpc.error_code.internal_error, "Internal error"),
        };
    }

    fn writeAndFree(self: *Server, transport: Transport, response: []u8) !void {
        defer self.gpa.free(response);
        try transport.writeMessage(response);
    }

    fn handleNotification(self: *Server, msg: jsonrpc.Message) void {
        const method = msg.method().?;
        if (std.mem.eql(u8, method, "notifications/initialized")) {
            self.initialized = true;
        }
        // Other notifications (cancelled, progress, ...) are ignored for now.
    }

    /// Returns a `gpa`-owned response payload.
    fn dispatch(self: *Server, arena: *std.heap.ArenaAllocator, msg: jsonrpc.Message) ![]u8 {
        const method = msg.method().?;
        const id = msg.id();

        if (std.mem.eql(u8, method, "initialize"))
            return self.handleInitialize(arena, id, msg.params());
        if (std.mem.eql(u8, method, "ping"))
            return jsonrpc.writeResult(self.gpa, id, struct {}{});
        if (std.mem.eql(u8, method, "tools/list"))
            return self.handleToolsList(arena, id);
        if (std.mem.eql(u8, method, "tools/call"))
            return self.handleToolsCall(arena, id, msg.params());
        if (std.mem.eql(u8, method, "resources/list"))
            return self.handleResourcesList(arena, id);
        if (std.mem.eql(u8, method, "resources/read"))
            return self.handleResourcesRead(arena, id, msg.params());
        if (std.mem.eql(u8, method, "prompts/list"))
            return self.handlePromptsList(arena, id);
        if (std.mem.eql(u8, method, "prompts/get"))
            return self.handlePromptsGet(arena, id, msg.params());

        return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.method_not_found, "Method not found");
    }

    fn serverCapabilities(self: *Server) capabilities.ServerCapabilities {
        return .{
            .tools = if (self.tools.count() > 0) .{} else null,
            .resources = if (self.resources.count() > 0) .{} else null,
            .prompts = if (self.prompts.count() > 0) .{} else null,
        };
    }

    fn handleInitialize(self: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, params: Value) ![]u8 {
        const p = std.json.parseFromValueLeaky(protocol.InitializeParams, arena.allocator(), params, .{ .ignore_unknown_fields = true }) catch {
            return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.invalid_params, "Invalid initialize params");
        };
        self.negotiated_version = capabilities.negotiateVersion(p.protocolVersion);

        const result = protocol.InitializeResult{
            .protocolVersion = self.negotiated_version,
            .capabilities = self.serverCapabilities(),
            .serverInfo = self.info,
            .instructions = self.instructions,
        };
        return jsonrpc.writeResult(self.gpa, id, result);
    }

    fn handleToolsList(self: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id) ![]u8 {
        const entries = self.tools.values();
        const tools = try arena.allocator().alloc(protocol.Tool, entries.len);
        for (entries, 0..) |entry, i| tools[i] = entry.tool;
        return jsonrpc.writeResult(self.gpa, id, protocol.ListToolsResult{ .tools = tools });
    }

    fn handleToolsCall(self: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, params: Value) ![]u8 {
        const p = std.json.parseFromValueLeaky(protocol.CallToolParams, arena.allocator(), params, .{ .ignore_unknown_fields = true }) catch {
            return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.invalid_params, "Invalid tools/call params");
        };

        const entry = self.tools.get(p.name) orelse {
            return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.invalid_params, "Unknown tool");
        };

        const ctx = ToolContext{
            .server = self,
            .arena = arena.allocator(),
            .arguments = p.arguments orelse Value.null,
        };

        // A handler error becomes an `isError` tool result (a tool failure the
        // model can see and react to), not a protocol-level JSON-RPC error.
        const result = entry.handler(ctx) catch |err| blk: {
            const content = try arena.allocator().alloc(protocol.Content, 1);
            content[0] = .{ .text = .{ .text = @errorName(err) } }; // @errorName is static
            break :blk protocol.CallToolResult{ .content = content, .isError = true };
        };
        return jsonrpc.writeResult(self.gpa, id, result);
    }

    fn handleResourcesList(self: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id) ![]u8 {
        const entries = self.resources.values();
        const list = try arena.allocator().alloc(protocol.Resource, entries.len);
        for (entries, 0..) |entry, i| list[i] = entry.resource;
        return jsonrpc.writeResult(self.gpa, id, protocol.ListResourcesResult{ .resources = list });
    }

    fn handleResourcesRead(self: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, params: Value) ![]u8 {
        const p = std.json.parseFromValueLeaky(protocol.ReadResourceParams, arena.allocator(), params, .{ .ignore_unknown_fields = true }) catch {
            return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.invalid_params, "Invalid resources/read params");
        };
        const entry = self.resources.get(p.uri) orelse {
            return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.invalid_params, "Unknown resource");
        };
        const ctx = ResourceContext{ .server = self, .arena = arena.allocator(), .uri = p.uri };
        const result = entry.handler(ctx) catch {
            return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.internal_error, "Resource read failed");
        };
        return jsonrpc.writeResult(self.gpa, id, result);
    }

    fn handlePromptsList(self: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id) ![]u8 {
        const entries = self.prompts.values();
        const list = try arena.allocator().alloc(protocol.Prompt, entries.len);
        for (entries, 0..) |entry, i| list[i] = entry.prompt;
        return jsonrpc.writeResult(self.gpa, id, protocol.ListPromptsResult{ .prompts = list });
    }

    fn handlePromptsGet(self: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, params: Value) ![]u8 {
        const p = std.json.parseFromValueLeaky(protocol.GetPromptParams, arena.allocator(), params, .{ .ignore_unknown_fields = true }) catch {
            return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.invalid_params, "Invalid prompts/get params");
        };
        const entry = self.prompts.get(p.name) orelse {
            return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.invalid_params, "Unknown prompt");
        };
        const ctx = PromptContext{
            .server = self,
            .arena = arena.allocator(),
            .arguments = p.arguments orelse Value.null,
        };
        const result = entry.handler(ctx) catch {
            return jsonrpc.writeError(self.gpa, id, jsonrpc.error_code.internal_error, "Prompt generation failed");
        };
        return jsonrpc.writeResult(self.gpa, id, result);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const memory = @import("transport/memory.zig");

fn addToolHandler(ctx: Server.ToolContext) anyerror!protocol.CallToolResult {
    const args = ctx.arguments;
    const a = numberField(args, "a") orelse return error.MissingArg;
    const b = numberField(args, "b") orelse return error.MissingArg;
    const text = try std.fmt.allocPrint(ctx.arena, "{d}", .{a + b});
    return ctx.text(text);
}

fn numberField(v: Value, key: []const u8) ?f64 {
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

/// Drive a server on a background thread over a memory pipe, send raw JSON
/// from the test thread, and collect the response.
const Harness = struct {
    pipe: *memory.Pipe,
    server: *Server,
    thread: std.Thread,

    fn start(gpa: Allocator, server: *Server) !Harness {
        const pipe = try memory.Pipe.create(gpa);
        const thread = try std.Thread.spawn(.{}, runServer, .{ server, pipe.transportB() });
        return .{ .pipe = pipe, .server = server, .thread = thread };
    }

    fn runServer(server: *Server, t: Transport) void {
        server.run(t) catch {};
    }

    fn request(self: *Harness, gpa: Allocator, raw: []const u8) ![]u8 {
        const client = self.pipe.transportA();
        try client.writeMessage(raw);
        return (try client.readMessage(gpa)).?;
    }

    fn notify(self: *Harness, raw: []const u8) !void {
        try self.pipe.transportA().writeMessage(raw);
    }

    fn stop(self: *Harness) void {
        self.pipe.transportA().close();
        self.thread.join();
        self.pipe.destroy();
    }
};

test "server: initialize, tools/list, tools/call over a transport" {
    const a = testing.allocator;
    var server = Server.init(a, .{ .name = "test-server", .version = "0.1.0" });
    defer server.deinit();
    try server.addTool(.{
        .name = "add",
        .description = "Add two numbers",
        .input_schema =
        \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}
        ,
    }, addToolHandler);

    var h = try Harness.start(a, &server);
    defer h.stop();

    {
        const resp = try h.request(a,
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
        );
        defer a.free(resp);
        var m = try jsonrpc.Message.parse(a, resp);
        defer m.deinit();
        try testing.expect(m.isResponse());
        const result = m.result().?;
        try testing.expectEqualStrings("2025-06-18", result.object.get("protocolVersion").?.string);
        try testing.expectEqualStrings("test-server", result.object.get("serverInfo").?.object.get("name").?.string);
    }

    try h.notify(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );

    {
        const resp = try h.request(a,
            \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        );
        defer a.free(resp);
        var m = try jsonrpc.Message.parse(a, resp);
        defer m.deinit();
        const tools = m.result().?.object.get("tools").?.array;
        try testing.expectEqual(@as(usize, 1), tools.items.len);
        try testing.expectEqualStrings("add", tools.items[0].object.get("name").?.string);
    }

    {
        const resp = try h.request(a,
            \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"a":2,"b":3}}}
        );
        defer a.free(resp);
        var m = try jsonrpc.Message.parse(a, resp);
        defer m.deinit();
        const content = m.result().?.object.get("content").?.array;
        try testing.expectEqualStrings("5", content.items[0].object.get("text").?.string);
    }
}

test "server: unknown method -> method_not_found" {
    const a = testing.allocator;
    var server = Server.init(a, .{ .name = "s", .version = "0" });
    defer server.deinit();

    var h = try Harness.start(a, &server);
    defer h.stop();

    const resp = try h.request(a,
        \\{"jsonrpc":"2.0","id":9,"method":"does/not/exist"}
    );
    defer a.free(resp);
    var m = try jsonrpc.Message.parse(a, resp);
    defer m.deinit();
    try testing.expectEqual(@as(i64, jsonrpc.error_code.method_not_found), m.err().?.object.get("code").?.integer);
}

test "server: handler error becomes isError result" {
    const a = testing.allocator;
    var server = Server.init(a, .{ .name = "s", .version = "0" });
    defer server.deinit();
    try server.addTool(.{ .name = "add" }, addToolHandler); // missing args -> error

    var h = try Harness.start(a, &server);
    defer h.stop();

    const resp = try h.request(a,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add","arguments":{}}}
    );
    defer a.free(resp);
    var m = try jsonrpc.Message.parse(a, resp);
    defer m.deinit();
    try testing.expect(m.result().?.object.get("isError").?.bool);
}
