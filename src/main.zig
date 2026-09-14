const HELP_MESSAGE =
    \\.\GenerateCsharpContracts.exe <args>
    \\
    \\--yaml, -y                        [Required]:
    \\                                  Path to the .yaml file that defines the contracts
    \\
    \\--namespace, -n                   [Required]:
    \\                                  Namespace on the generated classes and enums
    \\
    \\--output, -o                      Path to the output directory (defaults to ".")
    \\
    \\--models-directory                Directory and sub-namespace that the classes and enums will be generated into (defaults to "Models")
    \\                                  Example: my-service/MyService.Shared/Models
    \\
    \\--newtonsoft-version              Which Newtonsoft.Json version to install in the generated .csproj file (defaults to {s})
    \\
    \\--nullable-disable                Toggle to disable nullable reference types.
    \\                                  If this is passed in, the .csproj file will be .NET Standard 2.0 instead to be compatible
    \\                                  with .NET Framework 4.8.
    \\
    \\--sln-path, -s                    Optionally provide a path to a solution file.
    \\                                  This path overrides the --output argument and will add the generated csproj to the solution.
    \\                                  Assumes that `dotnet` is an available command.
    \\
    \\--skip-csproj                     Skip .csproj file generation and create the C# files only.
    \\
    \\--enums-omit-none                 By default, enums are generated with a `None` option with value 0 (default value in C#).
    \\                                  Toggle this flag to disable this behavior.
    \\                                  As a result, the first value in the enum list will be assigned value 0.
    \\                                  Additionally, you can call out enums that you don't want this behavior applied to (--enum-behavior-except-for).
    \\                                  Keep in mind, however, that flag enums will always declare `None = 0`.
    \\
    \\--enum-behavior-except-for, -e    Call out any number of enums (comma or semicolon-delimited) that you don't want the blanket behavior for (whether or not we're generating `None = 0`).
    \\
    \\Generates C# files from a .yaml contract file.
    \\This creates the C# class/enum files that are defined in '#/components/schemas' in your .yaml file.
;

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;

    if (@import("builtin").target.os.tag == .windows) {
        // allows for printing unicode to console
        _ = SetConsoleOutputCP(65001);
    }

    var arg_iter: std.process.Args.Iterator = try init.minimal.args.iterateAllocator(gpa);
    defer arg_iter.deinit();
    // skip first arg since that's .exe itself
    _ = arg_iter.next();

    if (help_msg: {
        const arg: []const u8 = arg_iter.next() orelse break :help_msg true;
        if (mem.eql(u8, "--help", arg) or mem.eql(u8, "?", arg) or mem.eql(u8, "-h", arg))
            break :help_msg true;

        // ok, help message is not being requested, so let's get our args again
        arg_iter.deinit();
        arg_iter = try init.minimal.args.iterateAllocator(gpa);
        _ = arg_iter.next();
        break :help_msg false;
    }) {
        print(HELP_MESSAGE, .{generation.default_newtonsoft_version});
        return;
    }

    var yaml_in: Arg = .unassigned;
    var namespace_in: Arg = .unassigned;
    var output_dir: Arg = .defaultValue(".");
    var models_dir: Arg = .defaultValue("Models");
    var newtonsoft_version: Arg = .defaultValue(generation.default_newtonsoft_version);
    var nullable: Flag = .on;
    var generate_csproj: Flag = .on;
    var enums_none_option: Flag = .on;
    var except_for: Arg = .unassigned;
    var sln_path: Arg = .unassigned;

    while (arg_iter.next()) |arg| {
        if (try yaml_in.parseFor(&.{ "-y", "--yaml" }, arg, &arg_iter)) continue;
        if (try namespace_in.parseFor(&.{ "-n", "--namespace" }, arg, &arg_iter)) continue;
        if (try output_dir.parseFor(&.{ "-o", "--output" }, arg, &arg_iter)) continue;
        if (try models_dir.parseFor(&.{"--models-directory"}, arg, &arg_iter)) continue;
        if (try newtonsoft_version.parseFor(&.{"--newtonsoft-version"}, arg, &arg_iter)) continue;
        if (try nullable.toggleOn(&.{"--nullable-disable"}, arg)) continue;
        if (try sln_path.parseFor(&.{ "-s", "--sln-path" }, arg, &arg_iter)) continue;
        if (try generate_csproj.toggleOn(&.{"--skip-csproj"}, arg)) continue;
        if (try enums_none_option.toggleOn(&.{"--enums-omit-none"}, arg)) continue;
        if (try except_for.parseFor(&.{ "--enum-behavior-except-for", "-e" }, arg, &arg_iter)) continue;

        print("Unrecognized argument {s}\n", .{arg});
        return error.UnrecognizedArgument;
    }

    const start: Io.Timestamp = .now(io, .real);
    var enum_options: EnumOptions = .{
        .emit_none = enums_none_option.value,
        .except_for = .empty,
    };
    defer enum_options.except_for.deinit(gpa);

    if (except_for.value) |not_these_enums| {
        var tokenizer: mem.TokenIterator(u8, .any) = mem.tokenizeAny(u8, not_these_enums, &.{ ',', ';' });
        while (tokenizer.next()) |enum_name| if (enum_name.len > 0) {
            try enum_options.except_for.put(gpa, enum_name, false);
        };
    }
    execute(
        io,
        gpa,
        yaml_in.value orelse {
            print("No value assigned for .yaml input file (--yaml, -y).\n", .{});
            return error.Unassigned;
        },
        namespace_in.value orelse {
            print("No value assigned for C# file namespace (--namespace, -n).\n", .{});
            return error.Unassigned;
        },
        output_dir.value.?,
        models_dir.value.?,
        newtonsoft_version.value.?,
        nullable.value,
        sln_path.value,
        generate_csproj.value,
        enum_options,
    ) catch |err| {
        print("Failed to generate contracts \u{274c}\n", .{});
        return err;
    };
    print("Finished generation in {d:.4}ms \u{1f389}\n", .{
        @as(f128, start.untilNow(io, .real).toNanoseconds()) / 1_000_000.0,
    });
}

fn execute(
    io: Io,
    gpa: Allocator,
    yaml_path: []const u8,
    namespace: []const u8,
    output_dir: []const u8,
    models_dir: []const u8,
    newtonsoft_version: []const u8,
    nullable: bool,
    sln_path: ?[]const u8,
    generate_csproj: bool,
    enum_options: EnumOptions,
) !void {
    print(
        \\
        \\Thank you for using C# Contract Gen!
        \\Bringing you an opinionated code generator that creates the code you would've written.
        \\Blink and you'll miss it! {u}
        \\
        \\Args: {u}
        \\  yaml path: {s}
        \\  C# namespace: {s}
        \\  output directory: {s}
        \\  models directory: {s}
        \\  Newtonsoft.Json Version: {s}
        \\  enable nullable: {any}
        \\  solution path: {?s}
        \\  generate .csproj: {any}
        \\  enums none option: {any}
        \\
    , .{
        '\u{26a1}',
        '\u{1f4cb}',
        yaml_path,
        namespace,
        output_dir,
        models_dir,
        newtonsoft_version,
        nullable,
        sln_path,
        generate_csproj,
        enum_options.emit_none,
    });

    var iter: std.StringHashMapUnmanaged(bool).KeyIterator = enum_options.except_for.keyIterator();
    var first_line: bool = true;
    while (iter.next()) |key| {
        if (first_line) {
            print("    (except for): ", .{});
            print("{s}", .{key.*});
            first_line = false;
        } else {
            print(", {s}", .{key.*});
        }
    }
    print("\n\n", .{});

    const file_in: File = try Dir.cwd().openFile(io, yaml_path, .{});
    defer file_in.close(io);

    var sln_opts: ?generation.SlnOptions = null;
    var dir_out: Dir = if (sln_path) |sln| sln: {
        if (mem.endsWith(u8, sln, ".sln")) {
            var backward_iter: mem.SplitBackwardsIterator(u8, .any) = mem.splitBackwardsAny(u8, sln, "\\/");
            const sln_file_name: []const u8 = backward_iter.next().?;
            const sln_parent_dir_path: []const u8 = sln[0 .. sln.len - sln_file_name.len];
            sln_opts = .{
                .path = sln,
                .parent_dir_path = sln_parent_dir_path,
            };
            break :sln try Dir.cwd().openDir(io, sln_parent_dir_path, .{});
        }
        print("Path provided to solution file was invalid: '{s}'\n", .{sln});
        return error.InvalidSolutionPath;
    } else Dir.cwd().openDir(io, output_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => create_dir: {
            Dir.cwd().createDir(io, output_dir, .default_file) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            break :create_dir try Dir.cwd().openDir(io, output_dir, .{});
        },
        else => return err,
    };
    defer dir_out.close(io);

    var source_buf: [2048]u8 = undefined;
    var file_reader: File.Reader = file_in.reader(io, &source_buf);
    var stream: Io.Writer.Allocating = .init(gpa);
    defer stream.deinit();

    _ = file_reader.interface.streamRemaining(&stream.writer) catch |err| return switch (err) {
        error.ReadFailed => file_reader.err.?,
        error.WriteFailed => error.OutOfMemory,
    };

    var composer: Composer = .init(gpa, nullable);
    defer composer.deinit();

    const load_yaml: Managed(LoadYaml) = try Yaml.load(gpa, stream.written());
    defer load_yaml.deinit();

    const yaml_in: Yaml = load_yaml.value.yaml catch |err| {
        // failed to parse
        try load_yaml.value.parser_errors.renderToStderr(io, .{}, .on);
        return err;
    };
    try composer.compose(yaml_in);

    try generation.generateFiles(io, gpa, &composer.ref_map, &dir_out, namespace, .{
        .newtonsoft_version = newtonsoft_version,
        .enable_nullable = nullable,
        .sln = sln_opts,
        .generate_csproj = generate_csproj,
        .models_dir = models_dir,
        .enums = enum_options,
    });
}

/// see docs: https://learn.microsoft.com/en-us/windows/console/setconsoleoutputcp
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: c_uint) callconv(.winapi) std.os.windows.BOOL;

const std = @import("std");
const yaml = @import("yaml");
const composing = @import("composing");
const generation = @import("generation");
const zutil = @import("zutil");
const mem = std.mem;
const Io = std.Io;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const DebugAllocator = std.heap.DebugAllocator;
const Yaml = yaml.Yaml;
const LoadYaml = Yaml.LoadYaml;
const Managed = Yaml.Managed;
const File = Io.File;
const Dir = Io.Dir;
const Composer = composing.Composer;
const Arg = zutil.cli.Arg;
const Flag = zutil.cli.Flag;
const FileGen = composing.FileGen;
const EnumOptions = generation.EnumOptions;
const MultiArrayList = std.MultiArrayList;
const print = std.debug.print;
