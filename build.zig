// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target: ResolvedTarget = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize: OptimizedMode = b.standardOptimizeOption(.{});

    const mod_yaml: *Module = b.dependency("zig_yaml", .{}).module("yaml");
    const mod_zutil: *Module = b.dependency("zutil", .{}).module("zutil");
    const mod_composing: *Module = b.createModule(.{
        .root_source_file = b.path("src/composing/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yaml", .module = mod_yaml },
            .{ .name = "zutil", .module = mod_zutil },
        },
    });
    const mod_generation: *Module = b.createModule(.{
        .root_source_file = b.path("src/generation/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "composing", .module = mod_composing },
            .{ .name = "zutil", .module = mod_zutil },
        },
    });
    const main: *Module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yaml", .module = mod_yaml },
            .{ .name = "zutil", .module = mod_zutil },
            .{ .name = "composing", .module = mod_composing },
            .{ .name = "generation", .module = mod_generation },
        },
    });

    const test_composing: *Compile = b.addTest(.{ .root_module = mod_composing, .name = "Test composing module" });
    const run_test_composing: *Run = b.addRunArtifact(test_composing);

    const test_generation: *Compile = b.addTest(.{ .root_module = mod_generation, .name = "Test generation module" });
    const run_test_generation: *Run = b.addRunArtifact(test_generation);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step: *Step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test_composing.step);
    test_step.dependOn(&run_test_generation.step);

    const exe: *Compile = b.addExecutable(.{ .root_module = main, .name = "GenerateCsharpContracts" });
    b.installArtifact(exe);
}

const std = @import("std");
const Build = std.Build;
const Module = Build.Module;
const Step = Build.Step;
const Run = Step.Run;
const Compile = Step.Compile;
const OptimizedMode = std.builtin.OptimizeMode;
const ResolvedTarget = std.Build.ResolvedTarget;
