// Build graph for the Zig rewrite. See the compiled task note
// `second-brain-setup-008` and its design note for why this is shaped the way
// it is; the short version is that the module graph below IS the layering, not
// a description of it.
//
// The one rule: `core` imports `ports`, and nothing else. It never imports an
// adapter, so a dependency pointing the wrong way fails to compile rather than
// surviving until someone notices it in review. Per-app dependency sets fall
// out of the same mechanism -- a future `bard` executable simply never lists
// the tree-sitter adapter, so no libtree-sitter and no C compiler enter its
// build at all.
//
// `std.Io` is the system boundary rather than a bespoke Fs/Clock/Http trio, so
// there is nothing here to wire for those: core functions take an `Io`
// parameter. Only process spawning needs a port of our own (`ports/exec.zig`),
// because `std.Io` does not cover it.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The vocabulary every layer speaks: defs, refs, nodes. Imports nothing.
    // It sits below `ports` rather than inside `core` because a port's
    // signatures name these types, and `core` imports `ports` -- putting the
    // model in `core` would close that loop into a cycle. The model being at
    // the bottom is also just true: it is what the other layers agree on.
    const model = b.addModule("model", .{
        .root_source_file = b.path("src/model/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Port definitions: vtables and the types crossing them, no
    // implementations. Imports only the model.
    const ports = b.addModule("ports", .{
        .root_source_file = b.path("src/ports/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    ports.addImport("model", model);

    // The graph itself: model, indexes, ranking, query, staleness, cache.
    // Pure. Reaches the system only through an injected `std.Io` and the
    // ports above.
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addImport("model", model);
    core.addImport("ports", ports);

    // Adapters: the implementations behind the ports, and the only place a C
    // library, a network or another process is reachable from. Imports core
    // and ports; nothing imports it back.
    const adapters = b.addModule("adapters", .{
        .root_source_file = b.path("src/adapters/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapters.addImport("model", model);
    adapters.addImport("core", core);
    adapters.addImport("ports", ports);

    const exe = b.addExecutable(.{
        .name = "synapse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/synapse/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "ports", .module = ports },
                .{ .name = "adapters", .module = adapters },
            },
        }),
    });
    b.installArtifact(exe);

    // Deliberately no `run` step. A Run step treats a non-zero exit as a build
    // failure, and non-zero is a normal, contractual result for this binary --
    // `2` for a usage error, `1` for a refusal, all of them asserted by the
    // bats suite. A step that reports those as broken builds would be lying.
    // Invoke `zig-out/bin/synapse` directly, which is what the hooks, the
    // tests and the installed copy all do anyway.

    // Zig tests cover internals only -- format round-trips, binary search,
    // scoring. The CLI contract belongs to tests/*.bats and stays there: if an
    // assertion can be written against stdout or an exit code, duplicating it
    // here would quietly retire bats as the specification.
    const test_step = b.step("test", "Run Zig unit tests (bats owns the CLI contract)");
    for ([_]*std.Build.Module{ model, core, ports, adapters }) |mod| {
        const unit = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}
