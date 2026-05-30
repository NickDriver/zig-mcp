//! Transport abstraction: a bidirectional stream of whole JSON-RPC messages.
//!
//! Both the server and client are written against this interface, so they work
//! unchanged over stdio, an in-process pipe (for tests), or HTTP. A transport
//! deals in complete message payloads — the framing (newline delimiting for
//! stdio, HTTP bodies/SSE events for HTTP) is the transport's concern, not the
//! protocol layer's.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read the next complete message. Returns the message bytes (allocated
        /// with the passed `gpa`; the caller frees them) or `null` on a clean
        /// end-of-stream / closed transport. May block until a message arrives.
        readMessage: *const fn (ptr: *anyopaque, gpa: Allocator) anyerror!?[]u8,
        /// Write one complete message. The transport adds whatever framing it
        /// needs; `bytes` is the raw JSON payload.
        writeMessage: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
        /// Release resources and unblock any pending `readMessage`.
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn readMessage(self: Transport, gpa: Allocator) anyerror!?[]u8 {
        return self.vtable.readMessage(self.ptr, gpa);
    }

    pub fn writeMessage(self: Transport, bytes: []const u8) anyerror!void {
        return self.vtable.writeMessage(self.ptr, bytes);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};

pub const stdio = @import("transport/stdio.zig");
pub const memory = @import("transport/memory.zig");
pub const http = @import("transport/http.zig");

test {
    _ = stdio;
    _ = memory;
    _ = http;
}
