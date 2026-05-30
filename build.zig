const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Public library module: `@import("mcp")` ---
    const mcp_mod = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Unit + integration tests ---
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // --- Examples ---
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "server_stdio", .path = "examples/server_stdio.zig" },
        .{ .name = "client_stdio", .path = "examples/client_stdio.zig" },
        .{ .name = "server_http", .path = "examples/server_http.zig" },
        .{ .name = "client_http", .path = "examples/client_http.zig" },
    };
    const examples_step = b.step("examples", "Build example executables");
    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "mcp", .module = mcp_mod }},
            }),
        });
        b.installArtifact(exe);
        examples_step.dependOn(&exe.step);
    }
}
