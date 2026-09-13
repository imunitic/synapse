// Build graph for synapse-bard, split out from the repo root's own build
// graph (see the compiled task note and design note for "Separate
// synapse-bard into its own build tree" for why). A path dependency on the
// repo root (declared in `build.zig.zon`) supplies `model`/`ports`/`core`/
// `adapters` -- this file only ever requests those four, never `treesitter`,
// so libtree-sitter and the C toolchain it needs stay entirely out of this
// build.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Skip tests whose name does not contain this text",
    );
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const synapse_dep = b.dependency("synapse", .{ .target = target, .optimize = optimize });
    const model = synapse_dep.module("model");
    const ports = synapse_dep.module("ports");
    const core = synapse_dep.module("core");
    const adapters = synapse_dep.module("adapters");

    // synapse-bard's own adapters: the Bible-graph and Writer's notes vault
    // implementations, built on the dep's shared `disk_store`.
    const bard_adapters = b.addModule("bard_adapters", .{
        .root_source_file = b.path("src/adapters/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    bard_adapters.addImport("model", model);
    bard_adapters.addImport("ports", ports);
    bard_adapters.addImport("core", core);
    bard_adapters.addImport("adapters", adapters);

    // synapse-bard: the Bible-graph and Writer's notes vault binary for a
    // YAML-templated fiction bible. Imports no `treesitter` -- it parses YAML
    // frontmatter only, never tree-sitter's grammars -- so it carries no
    // libtree-sitter and needs no C compiler.
    const bard = b.addExecutable(.{
        .name = "synapse-bard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/bard/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "ports", .module = ports },
                .{ .name = "adapters", .module = adapters },
                .{ .name = "model", .module = model },
                .{ .name = "bard_adapters", .module = bard_adapters },
            },
        }),
    });
    b.installArtifact(bard);

    // synapse-bard's own hooks, same relationship to synapse-bard that
    // synapse-hook has to synapse in the root build -- a separate binary so
    // a hook's startup carries nothing synapse-bard's own CLI needs but a
    // hook doesn't.
    const bard_hook = b.addExecutable(.{
        .name = "synapse-bard-hook",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/bard_hook/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "adapters", .module = adapters },
                .{ .name = "model", .module = model },
            },
        }),
    });
    b.installArtifact(bard_hook);

    const test_step = b.step("test", "Run Zig unit tests");
    const test_build_step = b.step("test-build", "Compile the unit tests without running them");

    for ([_]*std.Build.Module{ bard_adapters, bard.root_module, bard_hook.root_module }) |mod| {
        const unit = b.addTest(.{ .root_module = mod, .filters = test_filters });
        test_step.dependOn(&b.addRunArtifact(unit).step);
        test_build_step.dependOn(&unit.step);
    }
}
