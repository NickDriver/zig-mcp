//! Streamable-HTTP transport (a pragmatic v1 subset of MCP's HTTP transport).
//!
//! Client side (`HttpClientTransport`): each outgoing message is POSTed to the
//! server endpoint; the HTTP response body (a single JSON-RPC message, when the
//! server replies `application/json`) is queued and handed back by the next
//! `readMessage`. This adapts HTTP's request/response shape onto the
//! `Transport` interface that the `Client` is written against.
//!
//! Server side (`serve`): a TCP accept loop that reads each POST body, runs it
//! through `Server.handleRaw`, and replies with the JSON-RPC response
//! (`application/json`) or `202 Accepted` for notifications.
//!
//! v1 limitations: no SSE parsing on the client, no server-initiated streaming
//! (GET/SSE), and no session resumption. The `Mcp-Session-Id` header is not yet
//! tracked. This is enough to interoperate for the request/response flows the
//! `Client` performs (initialize, tools, resources, prompts).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Transport = @import("../transport.zig").Transport;
const Server = @import("../server.zig").Server;

const max_body_bytes = 16 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Client transport
// ---------------------------------------------------------------------------

pub const HttpClientTransport = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,
    http: std.http.Client,
    endpoint: []u8,
    queue: std.ArrayList([]u8) = .empty,

    /// `endpoint` is the full URL of the server's MCP endpoint, e.g.
    /// "http://127.0.0.1:7345/mcp". Heap-allocated; free with `deinit`.
    pub fn init(gpa: Allocator, endpoint: []const u8) !*HttpClientTransport {
        const self = try gpa.create(HttpClientTransport);
        errdefer gpa.destroy(self);
        const endpoint_owned = try gpa.dupe(u8, endpoint);
        errdefer gpa.free(endpoint_owned);
        self.* = .{
            .gpa = gpa,
            .threaded = std.Io.Threaded.init(gpa, .{}),
            .http = undefined,
            .endpoint = endpoint_owned,
        };
        self.http = .{ .allocator = gpa, .io = self.threaded.io() };
        return self;
    }

    pub fn deinit(self: *HttpClientTransport) void {
        self.http.deinit();
        self.threaded.deinit();
        for (self.queue.items) |m| self.gpa.free(m);
        self.queue.deinit(self.gpa);
        self.gpa.free(self.endpoint);
        self.gpa.destroy(self);
    }

    pub fn transport(self: *HttpClientTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{
        .readMessage = readMessage,
        .writeMessage = writeMessage,
        .close = close,
    };

    fn writeMessage(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *HttpClientTransport = @ptrCast(@alignCast(ptr));

        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();

        const result = self.http.fetch(.{
            .location = .{ .url = self.endpoint },
            .method = .POST,
            .payload = bytes,
            .response_writer = &body.writer,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "application/json, text/event-stream" },
            },
        }) catch return error.WriteFailed;
        _ = result;

        const payload = body.written();
        if (payload.len > 0) {
            const dup = try self.gpa.dupe(u8, payload);
            errdefer self.gpa.free(dup);
            try self.queue.append(self.gpa, dup);
        }
    }

    fn readMessage(ptr: *anyopaque, gpa: Allocator) anyerror!?[]u8 {
        const self: *HttpClientTransport = @ptrCast(@alignCast(ptr));
        if (self.queue.items.len == 0) return null;
        const front = self.queue.orderedRemove(0);
        defer self.gpa.free(front);
        return try gpa.dupe(u8, front);
    }

    fn close(ptr: *anyopaque) void {
        _ = ptr;
    }
};

// ---------------------------------------------------------------------------
// Server loop
// ---------------------------------------------------------------------------

pub const ServeOptions = struct {
    /// Per-connection reader/writer buffer sizes.
    buffer_size: usize = 64 * 1024,
    /// The path that accepts MCP messages. Other paths get 404.
    endpoint_path: []const u8 = "/mcp",
};

/// Run an MCP server over HTTP, listening on `host:port`. Blocks, serving
/// connections sequentially, until a fatal error occurs.
pub fn serve(gpa: Allocator, mcp_server: *Server, host: []const u8, port: u16, options: ServeOptions) !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = try std.Io.net.IpAddress.parse(host, port);
    var net_server = try address.listen(io, .{ .reuse_address = true });
    defer net_server.deinit(io);

    const read_buf = try gpa.alloc(u8, options.buffer_size);
    defer gpa.free(read_buf);
    const write_buf = try gpa.alloc(u8, options.buffer_size);
    defer gpa.free(write_buf);
    const body_buf = try gpa.alloc(u8, options.buffer_size);
    defer gpa.free(body_buf);

    while (true) {
        const stream = net_server.accept(io) catch continue;
        defer stream.close(io);
        handleConnection(gpa, mcp_server, io, stream, options, read_buf, write_buf, body_buf) catch {};
    }
}

fn handleConnection(
    gpa: Allocator,
    mcp_server: *Server,
    io: std.Io,
    stream: std.Io.net.Stream,
    options: ServeOptions,
    read_buf: []u8,
    write_buf: []u8,
    body_buf: []u8,
) !void {
    var sr = stream.reader(io, read_buf);
    var sw = stream.writer(io, write_buf);
    var http_server = std.http.Server.init(&sr.interface, &sw.interface);

    while (true) {
        var req = http_server.receiveHead() catch return; // connection closed / parse end

        if (!std.mem.startsWith(u8, req.head.target, options.endpoint_path)) {
            try req.respond("", .{ .status = .not_found });
            continue;
        }
        if (req.head.method != .POST) {
            // GET would be the SSE stream; unsupported in v1.
            try req.respond("", .{ .status = .method_not_allowed });
            continue;
        }

        const body_reader = req.readerExpectNone(body_buf);
        const body = try body_reader.allocRemaining(gpa, .limited(max_body_bytes));
        defer gpa.free(body);

        const maybe_response = try mcp_server.handleRaw(body);
        if (maybe_response) |response| {
            defer gpa.free(response);
            try req.respond(response, .{
                .status = .ok,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
        } else {
            try req.respond("", .{ .status = .accepted });
        }
    }
}
