//! In-process memory transport: a pair of cross-wired, thread-safe message
//! queues. Used to run a server and client in the same test process and have
//! them talk to each other over the real `Transport` interface — no
//! subprocesses, no sockets.
//!
//! `readMessage` blocks until a message is available or the channel is closed,
//! so a server's `run()` loop on one thread and a client on another behave
//! exactly as they would over stdio.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Transport = @import("../transport.zig").Transport;

/// A thread-safe FIFO of owned message payloads. Synchronization uses the
/// 0.16 `Io.Mutex`/`Io.Condition`, which require an `Io`; the owning `Pipe`
/// supplies one from a `Threaded` instance.
const Channel = struct {
    gpa: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList([]u8) = .empty,
    closed: bool = false,

    fn deinit(self: *Channel) void {
        for (self.queue.items) |m| self.gpa.free(m);
        self.queue.deinit(self.gpa);
    }

    fn push(self: *Channel, bytes: []const u8) !void {
        const dup = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(dup);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.queue.append(self.gpa, dup);
        self.cond.signal(self.io);
    }

    fn pop(self: *Channel, out_gpa: Allocator) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.queue.items.len == 0) {
            if (self.closed) return null;
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
        const front = self.queue.orderedRemove(0);
        defer self.gpa.free(front);
        return try out_gpa.dupe(u8, front);
    }

    fn close(self: *Channel) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
        self.cond.broadcast(self.io);
    }
};

/// One side of a `Pipe`. Reads from `in`, writes to `out`.
pub const Endpoint = struct {
    in: *Channel,
    out: *Channel,

    pub fn transport(self: *Endpoint) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{
        .readMessage = readMessage,
        .writeMessage = writeMessage,
        .close = close,
    };

    fn readMessage(ptr: *anyopaque, gpa: Allocator) anyerror!?[]u8 {
        const self: *Endpoint = @ptrCast(@alignCast(ptr));
        return self.in.pop(gpa);
    }

    fn writeMessage(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Endpoint = @ptrCast(@alignCast(ptr));
        return self.out.push(bytes);
    }

    fn close(ptr: *anyopaque) void {
        const self: *Endpoint = @ptrCast(@alignCast(ptr));
        self.out.close();
        self.in.close();
    }
};

/// A bidirectional in-process pipe. Side A's writes are side B's reads and vice
/// versa. Heap-allocated so the embedded channels/endpoints have stable
/// addresses; free with `destroy`.
pub const Pipe = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,
    a2b: Channel,
    b2a: Channel,
    ep_a: Endpoint,
    ep_b: Endpoint,

    pub fn create(gpa: Allocator) !*Pipe {
        const self = try gpa.create(Pipe);
        self.* = .{
            .gpa = gpa,
            .threaded = std.Io.Threaded.init(gpa, .{}),
            .a2b = undefined,
            .b2a = undefined,
            .ep_a = undefined,
            .ep_b = undefined,
        };
        const io = self.threaded.io();
        self.a2b = .{ .gpa = gpa, .io = io };
        self.b2a = .{ .gpa = gpa, .io = io };
        self.ep_a = .{ .in = &self.b2a, .out = &self.a2b };
        self.ep_b = .{ .in = &self.a2b, .out = &self.b2a };
        return self;
    }

    pub fn destroy(self: *Pipe) void {
        self.a2b.deinit();
        self.b2a.deinit();
        self.threaded.deinit();
        self.gpa.destroy(self);
    }

    pub fn transportA(self: *Pipe) Transport {
        return self.ep_a.transport();
    }

    pub fn transportB(self: *Pipe) Transport {
        return self.ep_b.transport();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "enqueue/dequeue in order, close ends the stream" {
    const a = testing.allocator;
    const pipe = try Pipe.create(a);
    defer pipe.destroy();

    const ta = pipe.transportA();
    const tb = pipe.transportB();

    try ta.writeMessage("hello");
    try ta.writeMessage("world");

    const m1 = (try tb.readMessage(a)).?;
    defer a.free(m1);
    const m2 = (try tb.readMessage(a)).?;
    defer a.free(m2);
    try testing.expectEqualStrings("hello", m1);
    try testing.expectEqualStrings("world", m2);

    ta.close();
    try testing.expect((try tb.readMessage(a)) == null);
}

test "blocking read wakes when a message arrives on another thread" {
    const a = testing.allocator;
    const pipe = try Pipe.create(a);
    defer pipe.destroy();

    const Echo = struct {
        fn run(t: Transport) void {
            const msg = (t.readMessage(std.testing.allocator) catch return) orelse return;
            defer std.testing.allocator.free(msg);
            t.writeMessage(msg) catch {};
        }
    };

    const th = try std.Thread.spawn(.{}, Echo.run, .{pipe.transportB()});
    const ta = pipe.transportA();
    try ta.writeMessage("ping");
    const back = (try ta.readMessage(a)).?;
    defer a.free(back);
    try testing.expectEqualStrings("ping", back);
    th.join();
}
