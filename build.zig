const std = @import("std");
const Build = std.Build;
const ResolvedTarget = Build.ResolvedTarget;
const OpimizeMode = std.builtin.OptimizeMode;
const Module = Build.Module;
const Step = Build.Step;
const Run = Step.Run;
const Compile = Step.Compile;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target: ResolvedTarget = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize: OpimizeMode = b.standardOptimizeOption(.{});

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod: *Module = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const parsing: *Module = b.createModule(.{
        .root_source_file = b.path("src/parsing/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const code_gen: *Module = b.createModule(.{
        .root_source_file = b.path("src/code_gen/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zul: *Module = b.dependency("zul", .{}).module("zul");
    const ymlz: *Module = b.dependency("ymlz", .{}).module("root");
    const iter_z: *Module = b.dependency("iter_z", .{}).module("iter_z");

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe: *Compile = b.addExecutable(.{
        .name = "csharp_contracts_gen",
        .root_module = exe_mod,
    });
    exe.root_module.addImport("zul", zul);
    exe.root_module.addImport("ymlz", ymlz);
    exe.root_module.addImport("parsing", parsing);
    exe.root_module.addImport("code_gen", code_gen);

    parsing.addImport("zul", zul);
    parsing.addImport("ymlz", ymlz);
    parsing.addImport("iter_z", iter_z);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd: *Run = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step: *Step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests: *Compile = b.addTest(.{
        .root_module = exe_mod,
    });
    exe_unit_tests.root_module.addImport("zul", zul);
    exe_unit_tests.root_module.addImport("parsing", parsing);
    exe_unit_tests.root_module.addImport("code_gen", code_gen);

    // const run_exe_unit_tests: *Run = b.addRunArtifact(exe_unit_tests);

    const parsing_unit_tests: *Compile = b.addTest(.{
        .root_module = parsing,
        .single_threaded = true,
    });

    // https://ziggit.dev/t/zig-debugging-with-lldb/3931/5
    // const codelldb: *Run = b.addSystemCommand(&.{"codelldb"});
    // codelldb.addArtifactArg(parsing_unit_tests);
    // codelldb.addArgs(&.{ "--port", "1234" });
    // const lldb_step: *Step = b.step("debugtest", "Debug unit tests");
    // lldb_step.dependOn(&codelldb.step);
    const run_parsing_unit_tests: *Run = b.addRunArtifact(parsing_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step: *Step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_parsing_unit_tests.step);
}
