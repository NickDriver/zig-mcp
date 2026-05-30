# zig-mcp

A [Model Context Protocol](https://modelcontextprotocol.io) (MCP) library for
**Zig 0.16**, covering **both the server and client** sides over **stdio** and
**HTTP**. Pure Zig, no external dependencies, no libc.

```zig
const mcp = @import("mcp");
```

- **Server** — expose tools, resources, and prompts to an AI application.
- **Client** — connect to and drive any MCP server from Zig.
- **Transports** — newline-delimited JSON over stdio, or Streamable HTTP. Both
  sides are written against a small `Transport` interface, so the protocol logic
  is transport-agnostic (there's also an in-process `memory` transport used for
  tests).
- **Protocol** — JSON-RPC 2.0, capability negotiation, and the core primitives
  of MCP `2025-06-18` (negotiates down to older revisions a client requests).

> Status: early (`v0.1.0`). The core request/response flows are implemented
> and tested. See [Limitations](#limitations).

## Requirements

- Zig **0.16.0**.

## Install

```sh
zig fetch --save git+https://github.com/NickDriver/zig-mcp
```

Then in `build.zig`:

```zig
const mcp = b.dependency("zig_mcp", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("mcp", mcp.module("mcp"));
```

## Writing a server

```zig
const std = @import("std");
const mcp = @import("mcp");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var server = mcp.Server.init(gpa, .{ .name = "my-server", .version = "0.1.0" });
    defer server.deinit();

    try server.addTool(.{
        .name = "add",
        .description = "Add two numbers.",
        .input_schema =
        \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}
        ,
    }, addTool);

    // Serve over stdio (what Claude Desktop/Code launch):
    const t = try mcp.transport.stdio.StdioTransport.init(gpa);
    defer t.deinit();
    try server.run(t.transport());

    // ...or over HTTP:
    // try mcp.transport.http.serve(gpa, &server, "127.0.0.1", 7345, .{});
}

fn addTool(ctx: mcp.Server.ToolContext) anyerror!mcp.CallToolResult {
    const obj = ctx.arguments.object; // the JSON `arguments`
    const a = obj.get("a").?.integer;
    const b = obj.get("b").?.integer;
    const text = try std.fmt.allocPrint(ctx.arena, "{d}", .{a + b});
    return ctx.text(text); // single text block, allocated in the request arena
}
```

Register resources and prompts with `server.addResource(...)` /
`server.addPrompt(...)`; their handlers receive a `ResourceContext` /
`PromptContext` and return a `ReadResourceResult` / `GetPromptResult`.

A handler that returns an error becomes an `isError` tool result the model can
see, not a protocol-level failure. Allocate any slices you return from
`ctx.arena` — returning `&.{...}` of runtime values would dangle.

## Writing a client

```zig
const t = try mcp.transport.http.HttpClientTransport.init(gpa, "http://127.0.0.1:7345/mcp");
defer t.deinit();

var client = mcp.Client.init(gpa, t.transport(), .{ .name = "my-client", .version = "0.1.0" });
defer client.deinit();

try client.initialize(); // handshake + notifications/initialized

var arena = std.heap.ArenaAllocator.init(gpa);
defer arena.deinit();

const tools = try client.listTools(arena.allocator());
const args = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"a\":40,\"b\":2}", .{});
const result = try client.callTool(arena.allocator(), "add", args);
// result.content[0].text.text == "42"
```

To talk to a server launched as a subprocess, use
`StdioTransport.fromFiles(gpa, child.stdout.?, child.stdin.?, buf)` — see
`examples/client_stdio.zig`.

Typed-result helpers (`listTools`, `callTool`, `listResources`, `readResource`,
`listPrompts`, `getPrompt`) take an `out_arena` allocator and return values
allocated from it.

## Examples

Build them with `zig build` (binaries land in `zig-out/bin/`):

| Example | What it does |
| --- | --- |
| `server_stdio` | Server with `add`/`echo` tools, a resource, and a prompt, over stdio. |
| `client_stdio` | Spawns `server_stdio` as a child and drives it. |
| `server_http`  | The same tools served at `http://127.0.0.1:7345/mcp`. |
| `client_http`  | Connects to `server_http` over HTTP. |

```sh
zig build test          # run the unit + loopback integration tests
zig build               # build the examples
./zig-out/bin/client_stdio
```

## Architecture

```
src/
  mcp.zig          public API (re-exports)
  jsonrpc.zig      JSON-RPC 2.0 envelope: parse + serialize
  protocol.zig     MCP payload types (Tool, Content, Resource, Prompt, ...)
  capabilities.zig capability structs + version negotiation
  transport.zig    the Transport interface
  transport/
    stdio.zig      newline-delimited JSON over stdin/stdout (or any files)
    memory.zig     in-process paired transport (tests)
    http.zig       Streamable-HTTP client transport + server loop
  server.zig       tool/resource/prompt registry + dispatch loop
  client.zig       handshake + typed request helpers
```

## Limitations

v1 implements the request/response core. Not yet supported:

- Server→client requests: **sampling**, **elicitation**, **roots** queries.
- **SSE** parsing on the HTTP client and server-initiated HTTP streaming (GET).
- HTTP **session resumption** (`Mcp-Session-Id` is not tracked).
- Resource **subscriptions**, **completions**, logging, and the experimental
  **Tasks** primitive (`2025-11-25`).

These are structured to be addable without breaking the public API.

## License

MIT — see [LICENSE](LICENSE).
