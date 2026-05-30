//! Stdio transport: newline-delimited JSON over stdin/stdout.
//!
//! This is the transport launched-as-a-subprocess MCP servers use (Claude
//! Desktop/Code, etc.). Each message is a single line of JSON terminated by
//! '\n'; per the spec, messages must not contain embedded newlines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Transport = @import("../transport.zig").Transport;

pub const StdioTransport = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,
    in_buf: []u8,
    out_buf: []u8,
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,

    const default_buffer = 64 * 1024;

    /// Transport over this process's own stdin/stdout — what a server launched
    /// as a subprocess uses. Heap-allocated so the embedded reader/writer
    /// interfaces (referred to by stable pointer) don't move. Free with `deinit`.
    pub fn init(gpa: Allocator) !*StdioTransport {
        return fromFiles(gpa, std.Io.File.stdin(), std.Io.File.stdout(), default_buffer);
    }

    /// Transport over arbitrary files — e.g. a client talking to a child
    /// process: pass the child's stdout (to read) and stdin (to write).
    pub fn fromFiles(gpa: Allocator, in_file: std.Io.File, out_file: std.Io.File, buffer_size: usize) !*StdioTransport {
        const self = try gpa.create(StdioTransport);
        errdefer gpa.destroy(self);

        const in_buf = try gpa.alloc(u8, buffer_size);
        errdefer gpa.free(in_buf);
        const out_buf = try gpa.alloc(u8, buffer_size);
        errdefer gpa.free(out_buf);

        self.* = .{
            .gpa = gpa,
            .threaded = std.Io.Threaded.init(gpa, .{}),
            .in_buf = in_buf,
            .out_buf = out_buf,
            .reader = undefined,
            .writer = undefined,
        };
        const io = self.threaded.io();
        self.reader = in_file.readerStreaming(io, in_buf);
        self.writer = out_file.writerStreaming(io, out_buf);
        return self;
    }

    pub fn deinit(self: *StdioTransport) void {
        self.threaded.deinit();
        self.gpa.free(self.in_buf);
        self.gpa.free(self.out_buf);
        self.gpa.destroy(self);
    }

    pub fn transport(self: *StdioTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{
        .readMessage = readMessage,
        .writeMessage = writeMessage,
        .close = close,
    };

    fn readMessage(ptr: *anyopaque, gpa: Allocator) anyerror!?[]u8 {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        const r = &self.reader.interface;
        while (true) {
            var msg: std.Io.Writer.Allocating = .init(gpa);
            errdefer msg.deinit();

            _ = r.streamDelimiterEnding(&msg.writer, '\n') catch |e| switch (e) {
                error.ReadFailed => return error.ReadFailed,
                error.WriteFailed => return error.OutOfMemory,
            };

            // After streamDelimiterEnding, either the next byte is the '\n'
            // delimiter (consume it) or we hit a true end-of-stream.
            const had_delim = if (r.takeByte()) |_| true else |e| switch (e) {
                error.EndOfStream => false,
                error.ReadFailed => return error.ReadFailed,
            };

            const body = msg.written();
            if (body.len == 0) {
                if (had_delim) {
                    msg.deinit();
                    continue; // blank line — skip
                }
                msg.deinit();
                return null; // clean EOF
            }
            return try msg.toOwnedSlice();
        }
    }

    fn writeMessage(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        const w = &self.writer.interface;
        try w.writeAll(bytes);
        try w.writeByte('\n');
        try w.flush();
    }

    fn close(ptr: *anyopaque) void {
        // stdin/stdout are owned by the process; nothing to close here. A
        // pending readMessage unblocks when the parent closes our stdin.
        _ = ptr;
    }
};
