//! zig-mcp — a Model Context Protocol (MCP) library for Zig.
//!
//! Public entry point. Re-exports the JSON-RPC layer, protocol types,
//! capabilities, and (as they land) the transports, server, and client.
//! See README.md for usage.

const std = @import("std");

pub const jsonrpc = @import("jsonrpc.zig");
pub const protocol = @import("protocol.zig");
pub const capabilities = @import("capabilities.zig");
pub const transport = @import("transport.zig");
pub const server = @import("server.zig");
pub const client = @import("client.zig");

pub const Transport = transport.Transport;
pub const Server = server.Server;
pub const Client = client.Client;

// Commonly used types, re-exported at the top level for convenience.
pub const Id = jsonrpc.Id;
pub const Implementation = protocol.Implementation;
pub const Tool = protocol.Tool;
pub const Content = protocol.Content;
pub const CallToolResult = protocol.CallToolResult;
pub const Resource = protocol.Resource;
pub const Prompt = protocol.Prompt;
pub const ClientCapabilities = capabilities.ClientCapabilities;
pub const ServerCapabilities = capabilities.ServerCapabilities;

/// MCP protocol version this library advertises by default during the
/// `initialize` handshake.
pub const protocol_version = capabilities.preferred_version;

test {
    // Pull every submodule's tests into the test binary.
    _ = jsonrpc;
    _ = protocol;
    _ = capabilities;
    _ = transport;
    _ = server;
    _ = client;
}
