// Runs the acceptance suites: the subprocess integration suite, which spawns
// the compiled `synapse`, `synapse-fake` and `synapse-hook` binaries, and the
// doc and text consistency checks. The programs themselves are built by Alire.
//
//   zig build test               the doc and text checks
//   zig build test-integration   the subprocess suite
//
// The suite runs against `bin/synapse`, `bin/synapse-fake` and
// `bin/synapse-hook` unless `-Dsynapse-bin`, `-Dsynapse-fake-bin` or
// `-Dhook-bin` name others.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimisation mode of the test programs (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

    // `zig build test-integration -Dtest-filter="name"` runs the tests whose
    // name contains the text.
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Skip tests whose name does not contain this text",
    );
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    // The doc and text consistency checks read the shipped docs and scripts
    // directly: no binary to spawn and nothing to import.
    const lint_mod = b.createModule(.{
        .root_source_file = b.path("tests/acceptance/lint_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lint_tests = b.addTest(.{ .root_module = lint_mod, .filters = test_filters });
    b.step("test", "Run the doc and text consistency checks")
        .dependOn(&b.addRunArtifact(lint_tests).step);

    const it_opts = b.addOptions();
    const synapse_bin = b.option([]const u8, "synapse-bin", "The synapse binary to test (default: bin/synapse)") orelse "bin/synapse";
    const fake_bin = b.option([]const u8, "synapse-fake-bin", "The synapse-fake binary to test (default: bin/synapse-fake)") orelse "bin/synapse-fake";
    const hook_bin = b.option([]const u8, "hook-bin", "The synapse-hook binary to test (default: bin/synapse-hook)") orelse "bin/synapse-hook";
    it_opts.addOptionPath("synapse_bin", .{ .cwd_relative = synapse_bin });
    it_opts.addOptionPath("synapse_fake_bin", .{ .cwd_relative = fake_bin });
    it_opts.addOptionPath("hook_bin", .{ .cwd_relative = hook_bin });
    it_opts.addOption([]const u8, "fake_bin_dir", "tests/acceptance/fixtures/fake-bin");

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/acceptance/integration/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addOptions("build_options", it_opts);

    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_module = integration_mod,
        .filters = test_filters,
    });
    b.step("test-integration", "Run the subprocess integration suite (spawns the real binaries)")
        .dependOn(&b.addRunArtifact(integration_tests).step);
}
