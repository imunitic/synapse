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

    // libtree-sitter, pinned by commit hash in build.zig.zon. Upstream ships
    // its own build.zig and we use its artifact rather than compiling the C
    // ourselves -- but the pin is a master commit, not a release tag, and that
    // is deliberate: every tagged release up to v0.26.12 has a build.zig
    // written against the pre-0.16 API (`Compile.addCSourceFile`, which moved
    // to `Module`), so `b.dependency` cannot even evaluate it under our pinned
    // toolchain. Master has the fix. The hash makes the commit as reproducible
    // as a tag would be; revisit when a release carries the fixed build.
    const ts_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    const ts_lib = ts_dep.artifact("tree-sitter");

    // The tree-sitter Extractor is its own module, not part of `adapters`, and
    // that separation is the per-app dependency set made real: `synapse` lists
    // it, a future `bard` does not, and so bard's build contains no
    // libtree-sitter and needs no C toolchain. Folding it into `adapters`
    // -- which bard does need, for the process helper -- would quietly hand
    // bard the C dependency it was designed to avoid.
    const treesitter = b.addModule("treesitter", .{
        .root_source_file = b.path("src/adapters/treesitter/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    treesitter.addImport("model", model);
    treesitter.addImport("ports", ports);
    treesitter.addImport("core", core);
    // treesitter -> adapters, never the reverse: this is how it reaches the
    // shared process helper without adapters gaining the C dependency, so an
    // app importing only `adapters` still links no libtree-sitter.
    treesitter.addImport("adapters", adapters);
    treesitter.linkLibrary(ts_lib);
    treesitter.addIncludePath(ts_dep.path("lib/include"));

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
                .{ .name = "treesitter", .module = treesitter },
                .{ .name = "model", .module = model },
            },
        }),
    });
    b.installArtifact(exe);

    // The acceptance check for the tree-sitter port: not installed, not part
    // of `check`, because it needs real grammars and real repositories. Built
    // on demand with `zig build differential`.
    const differential = b.addExecutable(.{
        .name = "tags-differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/tags_differential.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "treesitter", .module = treesitter }},
        }),
    });
    b.step("differential", "Build the tags acceptance-check tool")
        .dependOn(&b.addInstallArtifact(differential, .{}).step);

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
    for ([_]*std.Build.Module{ model, core, ports, adapters, treesitter }) |mod| {
        const unit = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}
