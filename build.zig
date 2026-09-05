// Build graph for the Zig rewrite. See the compiled task note
// `second-brain-setup-008` and its design note for why this is shaped the way
// it is; the short version is that the module graph below IS the layering, not
// a description of it.
//
// The one rule: `core` imports `ports`, and nothing else. It never imports an
// adapter, so a dependency pointing the wrong way fails to compile rather than
// surviving until someone notices it in review. Per-app dependency sets fall
// out of the same mechanism -- `synapse-bard` simply never lists the
// tree-sitter adapter, so no libtree-sitter and no C compiler enter its
// build at all.
//
// `std.Io` is the system boundary rather than a bespoke Fs/Clock/Http trio, so
// there is nothing here to wire for those: core functions take an `Io`
// parameter. Only process spawning needs a port of our own (`ports/exec.zig`),
// because `std.Io` does not cover it.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default, not Debug, and the difference is not academic:
    // `setup.sh` installs whatever `zig build` produced, and a Debug build of
    // this tagger is 16x slower than an optimised one -- 23.9s against 1.5s
    // over 1,000 Java files, measured. Shipping the default was shipping that.
    //
    // Safe rather than Fast, for 0.4s per 1,000 files: this code computes
    // offsets into a memory-mapped cache that any process on the machine can
    // write to, and `tags_cache/format.zig` validates every one of them on the
    // strength of bounds checks staying on. Turning them off to save a third
    // of a second would trade the format's safety argument for a number nobody
    // is waiting on.
    // Not `standardOptimizeOption`, which defaults to Debug: `setup.sh`
    // installs whatever `zig build` produced, and a Debug build of this tagger
    // is 16x slower than an optimised one -- 23.5s against 1.5s over 1,000
    // Java files, measured. Shipping the default was shipping that.
    //
    // (`standardOptimizeOption(.{ .preferred_optimize_mode = ... })` does not
    // do this. It honours the preference only when `--release` is passed, and
    // it removes `-Doptimize=` from the build's options entirely.)
    //
    // Safe rather than Fast, for 0.4s per 1,000 files: this code computes
    // offsets into a memory-mapped cache that any process on the machine can
    // write to, and `tags_cache/format.zig` validates every one of them on the
    // strength of bounds checks staying on. Trading the format's safety
    // argument for a third of a second is not a trade worth making, and the
    // tests keep those checks too.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

    // `zig build test -Dtest-filter="name"` runs the full module graph
    // filtered to matching tests, without hand-building a standalone `zig
    // test` binary and copying this file's own `--dep` flags by hand.
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Skip tests whose name does not contain this text",
    );
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

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
    // it, `synapse-bard` does not, so bard's build contains no libtree-sitter
    // and needs no C toolchain. Folding it into `adapters` -- which bard does
    // need, for the process helper -- would quietly hand bard the C
    // dependency it was designed to avoid.
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

    // The hooks, in their own binary. Not subcommands of `synapse`: a hook runs on
    // every edit and every turn, so its startup must depend on nothing else the
    // stage links -- and this one imports no `treesitter`, so it links no
    // libtree-sitter and needs no C compiler. That is what the per-app dependency
    // sets above are for.
    const hook = b.addExecutable(.{
        .name = "synapse-hook",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/hook/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "adapters", .module = adapters },
                .{ .name = "model", .module = model },
            },
        }),
    });
    b.installArtifact(hook);

    // synapse-bard: the Bible-graph and Writer's notes vault binary for a
    // YAML-templated fiction bible. Imports no `treesitter` -- it parses YAML
    // frontmatter only, never tree-sitter's grammars -- so it carries no
    // libtree-sitter and needs no C compiler, the same per-app dependency-set
    // discipline `hook` above already follows. See the compiled task note
    // `synapse-bard-001` for the full build-out; this target and its
    // placeholder `main.zig` are step one.
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
            },
        }),
    });
    b.installArtifact(bard);

    // synapse-bard's own hooks, same relationship to synapse-bard that hook
    // above has to synapse -- a separate binary so a hook's startup carries
    // nothing synapse-bard's own CLI needs but a hook doesn't.
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

    // The binary the integration suite mostly runs: the same app with the
    // grammar compile-and-load step stubbed. Its own step rather than part
    // of the default install, because it must never reach `~/.claude/bin` --
    // but `test-integration`'s own compile-order dependency (via
    // `addOptionPath` below) builds it first, since without it the suite
    // has no tagger at all. See `src/apps/synapse/main_fake.zig`.
    const fake = b.addExecutable(.{
        .name = "synapse-fake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/apps/synapse/main_fake.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "treesitter", .module = treesitter },
                .{ .name = "core", .module = core },
                .{ .name = "model", .module = model },
                // `adapters` for the process spawner, which subcommands like
                // `enumerate` need to reach `git ls-files`. It arrives here
                // transitively through `treesitter` either way; naming it adds
                // no dependency, only the ability to import it. What this
                // binary's narrower set is about is the *grammar* stub, not
                // denying it the ability to run a subprocess -- the integration
                // suite runs this binary, so anything a shipped script calls
                // has to work here too.
                .{ .name = "adapters", .module = adapters },
                // `ports` for `vault_cmd.zig`'s `LinkGraph` subcommands, same
                // "arrives transitively, naming it adds only the ability to
                // import it" reasoning as `adapters` above.
                .{ .name = "ports", .module = ports },
            },
        }),
    });
    b.step("fake", "Build the stubbed-grammar binary the integration suite mostly runs")
        .dependOn(&b.addInstallArtifact(fake, .{}).step);

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

    // Same reasoning as `differential`: it needs a real cache from a real
    // repository, so it is a tool built on demand rather than a test.
    const bench = b.addExecutable(.{
        .name = "tags-cache-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/tags_cache_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core }},
        }),
    });
    b.step("bench", "Build the tags-cache timing tool")
        .dependOn(&b.addInstallArtifact(bench, .{}).step);

    // Fetches the Unicode Character Database fresh from unicode.org and
    // regenerates `src/core/unicode_tables.zig`, committed like any other
    // source file. Host-only (needs real network access, and runs once on
    // a maintainer's own machine, never cross-compiled) -- unlike `fake`/
    // `differential`/`bench` above, this one is a Run step, not just an
    // install: a fetch/parse failure is a real, reportable build failure,
    // not a tool whose non-zero exit is itself the interesting result.
    const gen_unicode_tables = b.addExecutable(.{
        .name = "gen-unicode-tables",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/gen_unicode_tables.zig"),
            .target = b.graph.host,
        }),
    });
    b.step("gen-unicode-tables", "Fetch the UCD and regenerate the vendored NFC/case-fold tables")
        .dependOn(&b.addRunArtifact(gen_unicode_tables).step);

    // Deliberately no `run` step. A Run step treats a non-zero exit as a build
    // failure, and non-zero is a normal, contractual result for this binary --
    // `2` for a usage error, `1` for a refusal, all of them asserted by the
    // integration suite. A step that reports those as broken builds would be
    // lying. Invoke `zig-out/bin/synapse` directly, which is what the hooks,
    // the tests and the installed copy all do anyway.

    // Zig tests cover internals -- format round-trips, binary search, scoring
    // -- plus a `*_cmd.zig`'s own assembly logic where a real `Context` and a
    // real `Store` are reachable without a real git repo or network call
    // (`cmd_test_support.zig`'s fixture), plus static doc/text consistency
    // checks (`tests/lint_test.zig`) that need no process spawn at all. Real
    // subprocess/git-integration behavior is `zig build test-integration`'s
    // job instead, kept out of this fast in-process suite.
    const test_step = b.step("test", "Run Zig unit tests");

    // Compile the same tests without running them, so a cross-target build can
    // check code the executable does not reach. Zig analyses declarations
    // lazily: `zig build -Dtarget=x86_64-linux` only compiles what the app
    // actually references, so a module the app has not wired yet -- the tags
    // cache format, today -- would sit unchecked on every target but this one,
    // which is precisely where a byte-order or padding assumption hides. The
    // test root references everything, so building it covers everything.
    const test_build_step = b.step("test-build", "Compile the unit tests without running them");

    // `hook.root_module` as well as the libraries: the hooks' shared helpers carry
    // tests (the namespace agreement rule, the JSON string escaping) and an app root
    // is the only way to reach them, since an app is not a module anything imports.
    // `bard.root_module`/`bard_hook.root_module` alongside them for the same reason,
    // once either has tests of its own to pull in -- empty today, harmless to include.
    for ([_]*std.Build.Module{ model, core, ports, adapters, treesitter, exe.root_module, hook.root_module, bard.root_module, bard_hook.root_module }) |mod| {
        const unit = b.addTest(.{ .root_module = mod, .filters = test_filters });
        test_step.dependOn(&b.addRunArtifact(unit).step);
        test_build_step.dependOn(&unit.step);
    }

    // Doc/text consistency checks with no binary to spawn and no Zig
    // function to call -- reads the shipped docs and scripts directly, so
    // it needs no imports from the rest of the module graph.
    const lint_mod = b.createModule(.{
        .root_source_file = b.path("tests/lint_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lint_tests = b.addTest(.{ .root_module = lint_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(lint_tests).step);
    test_build_step.dependOn(&lint_tests.step);

    // Spawns the real compiled binaries as real subprocesses -- a slower,
    // genuinely different layer than the unit tests above, so it stays out
    // of `test`/`test-build` entirely rather than folded in. `addOptionPath`
    // wires the compile-order dependency on each binary automatically; no
    // manual `.dependOn` is needed for those.
    const it_opts = b.addOptions();
    it_opts.addOptionPath("synapse_bin", exe.getEmittedBin());
    it_opts.addOptionPath("synapse_fake_bin", fake.getEmittedBin());
    it_opts.addOptionPath("hook_bin", hook.getEmittedBin());
    it_opts.addOptionPath("bard_bin", bard.getEmittedBin());
    it_opts.addOptionPath("bard_hook_bin", bard_hook.getEmittedBin());
    it_opts.addOption([]const u8, "fake_bin_dir", "tests/fixtures/fake-bin");

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "adapters", .module = adapters }},
    });
    integration_mod.addOptions("build_options", it_opts);

    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_module = integration_mod,
        .filters = test_filters,
    });
    b.step("test-integration", "Run the Zig-native subprocess integration suite (spawns the real binaries)")
        .dependOn(&b.addRunArtifact(integration_tests).step);
}
