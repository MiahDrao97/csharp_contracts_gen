//! Write the .cs files from the composed classes and enums

/// Generate the code files
pub fn generateFiles(
    io: Io,
    gpa: Allocator,
    files: *const RefMap,
    dir: *Dir,
    namespace: []const u8,
    opts: Options,
) !void {
    const csproj: []const u8 = try fmt.allocPrint(gpa, "{s}.csproj", .{namespace});
    defer gpa.free(csproj);

    if (opts.sln) |_| {
        const csproj_dir: Dir = dir: {
            dir.createDir(io, namespace, .default_file) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            break :dir try dir.openDir(io, namespace, .{});
        };
        dir.close(io);
        dir.* = csproj_dir;
    }

    // group allows us to write files asynchronously
    var group: Io.Group = .init;
    defer group.cancel(io);

    var open_err: ?Io.File.OpenError = null;
    var write_err: ?Io.File.Writer.Error = null;
    var oom: ?Allocator.Error = null;

    // generate .csproj
    if (opts.generate_csproj) {
        group.async(io, writeCsprojFile, .{ io, dir.*, csproj, opts, &open_err, &write_err });
    }

    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();

    // generate models
    const models_dir: Dir = models_dir: {
        dir.createDir(io, opts.models_dir, .default_file) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        break :models_dir try dir.openDir(io, opts.models_dir, .{});
    };
    defer models_dir.close(io);

    var iter: RefMap.Iterator = files.iterator();
    while (iter.next()) |file| switch (file.value_ptr.*) {
        .composite => |comp| log.debug("Skipping file generation of composite type {s}. Composite types are assumed to be intermediary and not meant to make it to the final contracts.", .{comp.name}),
        inline else => |_, tag| {
            if (tag == .class and file.value_ptr.class.definition != .contract) {
                log.debug("Skipping file generation of class {s} as it is an intermediate type.", .{file.value_ptr.class.name});
                continue;
            }

            if (write_err) |e| return e;
            if (open_err) |e| return e;
            if (oom) |e| return e;

            group.async(io, writeSourceFile, .{
                io,
                arena.allocator(),
                models_dir,
                namespace,
                file.value_ptr.*,
                opts,
                &open_err,
                &write_err,
                &oom,
            });
        },
    };
    try group.await(io);
    if (write_err) |e| return e;
    if (open_err) |e| return e;
    if (oom) |e| return e;

    // run this check to inform the user if they missed anything
    group.async(io, checkEnumExceptions, .{&opts.enums});

    if (opts.sln) |s| {
        const csproj_path: []const u8 = try std.fs.path.join(arena.allocator(), &.{ s.parent_dir_path, namespace, csproj });
        // add proj to sln
        var child: std.process.Child = try std.process.spawn(io, .{ .argv = &.{ "dotnet", "sln", s.path, "add", csproj_path } });

        switch (try child.wait(io)) {
            .exited => |code| {
                if (code != 0) {
                    log.err("Adding {s} to solution {s} exited with code {d}.", .{ csproj, s.path, code });
                    return error.FailedToAddSln;
                } else {
                    log.debug("Successfully added {s} to solution {s}", .{ csproj, s.path });
                }
            },
            inline else => |x, tag| {
                log.err("Could not determine success of adding {s} to solution {s}: {t}({d})", .{ csproj, s.path, tag, x });
                return error.FailedToAddSln;
            },
        }
    }

    try group.await(io);
}

fn writeSourceFile(
    io: Io,
    arena: Allocator,
    models_dir: Dir,
    namespace: []const u8,
    file_gen: FileGen,
    opts: Options,
    open_err: *?Io.File.OpenError,
    write_err: *?Io.File.Writer.Error,
    oom: *?Allocator.Error,
) Io.Cancelable!void {
    var stream: Io.Writer.Allocating = .init(arena);
    file_gen.fileName(&stream.writer) catch {
        oom.* = error.OutOfMemory;
        return;
    };
    const file_name: []const u8 = stream.written();
    std.debug.assert(mem.endsWith(u8, file_name, ".cs"));
    const styled_name: []const u8 = file_name[0 .. file_name.len - ".cs".len];

    const file: File = models_dir.createFile(io, file_name, .{}) catch |err| return switch (err) {
        error.Canceled => |canceled| canceled,
        else => |e| open_err.* = e,
    };
    defer file.close(io);
    log.info("Created file {s} \u{1f4c4}", .{file_name});

    var buf: [2048]u8 = undefined;
    var writer: File.Writer = file.writer(io, &buf);
    _ = switch (file_gen) {
        .class => |c| writeClassFile(arena, &writer.interface, styled_name, namespace, opts.models_dir, c, opts.enable_nullable),
        .@"enum" => |e| writeEnumFile(arena, &writer.interface, styled_name, namespace, opts.models_dir, e, opts.enable_nullable, opts.enums),
        .composite => unreachable,
    } catch |err| return switch (err) {
        error.WriteFailed => write_err.* = writer.err.?,
        error.OutOfMemory => |e| oom.* = e,
    };
    writer.flush() catch |err| return switch (err) {
        error.Canceled => |canceled| canceled,
        else => |e| write_err.* = e,
    };
    log.info("\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 Finished writing {d} bytes to file {s} \u{2705}", .{ writer.pos, file_name });
}

fn writeClassFile(
    arena: Allocator,
    writer: *Io.Writer,
    styled_name: []const u8,
    namespace: []const u8,
    models_dir: []const u8,
    class: composing.Class,
    enable_nullable: bool,
) (Io.Writer.Error || Allocator.Error)!void {
    try writer.print(
        \\/// <auto-generated />
        \\
        \\using System;
        \\using System.Collections.Generic;
        \\using System.ComponentModel.DataAnnotations;
        \\using Newtonsoft.Json;
        \\
        \\{s}
    , .{
        if (enable_nullable) "#nullable enable" ++ newline ++ newline else "",
    });

    // WARN : File-scoped namespaces are not allowed in netstandard2.0
    try if (enable_nullable)
        writer.print("namespace {s}.{s};" ++ newline ++ newline, .{ namespace, models_dir })
    else
        writer.print("namespace {s}.{s}" ++ newline ++ "{{" ++ newline, .{ namespace, models_dir });

    try tabIf(writer, !enable_nullable);
    try writer.writeAll("/// <summary>" ++ newline);
    try tabIf(writer, !enable_nullable);
    try writer.print("/// {s}" ++ newline, .{
        try formatSummary(arena, class.description, if (enable_nullable) 1 else 2),
    });
    try tabIf(writer, !enable_nullable);
    try writer.writeAll("/// </summary>" ++ newline);

    if (class.deprecated) {
        try tabIf(writer, !enable_nullable);
        try writer.writeAll("[Obsolete]" ++ newline);
    }
    try tabIf(writer, !enable_nullable);
    try writer.print("public partial class {s}", .{styled_name});
    if (class.extends) |base_class| {
        try writer.print(" : {s}", .{base_class});
    }
    try writer.writeAll(newline);

    try tabIf(writer, !enable_nullable);
    try writer.writeAll("{" ++ newline);

    if (class.discriminator) |discriminator| {
        const required: bool = class.required.get(discriminator.name) != null;
        try writeClassProp(arena, writer, discriminator, required, enable_nullable);
    }
    for (class.props) |prop| {
        const required: bool = class.required.get(prop.name) != null;
        try writeClassProp(arena, writer, prop, required, enable_nullable);
    }

    try tabIf(writer, !enable_nullable);
    try writer.writeAll("}" ++ newline);
    if (!enable_nullable) try writer.writeByte('}');
}

fn writeClassProp(
    arena: Allocator,
    writer: *Io.Writer,
    prop: Property,
    required: bool,
    enable_nullable: bool,
) (Allocator.Error || Io.Writer.Error)!void {
    var stream: Io.Writer.Allocating = .init(arena);
    prop.stylizeName(&stream.writer) catch return error.OutOfMemory;
    const styled_prop_name: []const u8 = stream.written();

    try tabIf(writer, !enable_nullable);
    try writer.writeAll(tab ++ "/// <summary>" ++ newline);
    try tabIf(writer, !enable_nullable);
    try writer.print(
        tab ++ "/// {s}" ++ newline,
        .{try formatSummary(arena, prop.description, if (enable_nullable) 1 else 2)},
    );
    try tabIf(writer, !enable_nullable);
    try writer.writeAll(tab ++ "/// </summary>" ++ newline);

    if (prop.deprecated) {
        try tabIf(writer, !enable_nullable);
        try writer.writeAll(tab ++ "[Obsolete]" ++ newline);
    }
    // this attribute does not make sense if the property is nullable
    // however, the modifier is still valid because you can be forced to provide a value on initialization; null is still allowed, but you have to assign _some_ value
    if (required and !prop.nullable) {
        try tabIf(writer, !enable_nullable);
        try writer.writeAll(tab ++ "[Required]" ++ newline);
    }

    // handle data annotations
    for (prop.data_annotations) |data_annotation| {
        try tabIf(writer, !enable_nullable);
        try writer.print(tab ++ "{f}" ++ newline, .{data_annotation});
    }

    try tabIf(writer, !enable_nullable);
    try if (!mem.eql(u8, prop.name, styled_prop_name))
        writer.print(tab ++ "[JsonProperty(\"{s}\")]" ++ newline, .{prop.name})
    else
        writer.print(tab ++ "[JsonProperty(nameof({s}))]" ++ newline, .{prop.name});

    try tabIf(writer, !enable_nullable);
    try writer.writeAll(tab ++ "public ");
    if (required and enable_nullable) {
        // if nullable is disabled, it's a likely a C# version that does not support this modifier
        try writer.writeAll("required ");
    }
    try writer.print("{s}", .{prop.type.name});
    if (prop.nullable) {
        if (prop.type.mem_type == .value or enable_nullable) {
            try writer.writeByte('?');
        }
    }
    try writer.print(" {s} {{ get; set; }}" ++ newline ++ newline, .{styled_prop_name});
}

fn writeEnumFile(
    arena: Allocator,
    writer: *Io.Writer,
    styled_name: []const u8,
    namespace: []const u8,
    models_dir: []const u8,
    @"enum": composing.Enum,
    enable_nullable: bool,
    enum_options: EnumOptions,
) (Io.Writer.Error || Allocator.Error)!void {
    try writer.print(
        \\/// <auto-generated />
        \\
        \\using System;
        \\using System.Runtime.Serialization;
        \\using Newtonsoft.Json;
        \\using Newtonsoft.Json.Converters;
        \\
        \\{s}
    , .{
        if (enable_nullable) "#nullable enable" ++ newline ++ newline else "",
    });

    // WARN : File-scoped namespaces are not allowed in netstandard2.0
    try if (enable_nullable)
        writer.print("namespace {s}.{s};" ++ newline ++ newline, .{ namespace, models_dir })
    else
        writer.print("namespace {s}.{s}" ++ newline ++ "{{" ++ newline, .{ namespace, models_dir });

    try tabIf(writer, !enable_nullable);
    try writer.writeAll("/// <summary>" ++ newline);
    try tabIf(writer, !enable_nullable);
    try writer.print(
        "/// {s}" ++ newline,
        .{try formatSummary(arena, @"enum".description, if (enable_nullable) 1 else 2)},
    );
    try tabIf(writer, !enable_nullable);
    try writer.writeAll("/// </summary>" ++ newline);
    try tabIf(writer, !enable_nullable);
    try writer.writeAll("[JsonConverter(typeof(StringEnumConverter))]" ++ newline);

    if (@"enum".deprecated) {
        try tabIf(writer, !enable_nullable);
        try writer.writeAll("[Obsolete]" ++ newline);
    }
    if (@"enum".is_flag) {
        try tabIf(writer, !enable_nullable);
        try writer.writeAll("[Flags]" ++ newline);
    }
    try tabIf(writer, !enable_nullable);
    try writer.print("public enum {s}" ++ newline, .{styled_name});

    try tabIf(writer, !enable_nullable);
    try writer.writeAll("{" ++ newline);

    var none_option: bool = enum_options.emit_none;
    if (enum_options.except_for.getPtr(@"enum".name)) |except| {
        none_option = !none_option;
        except.* = true; // mark as evaluated
    } else if (enum_options.except_for.getPtr(styled_name)) |except| {
        none_option = !none_option;
        except.* = true; // mark as evaluated
    }

    var enum_val_offset: usize = 0;
    try tabIf(writer, !enable_nullable);
    if (none_option or @"enum".is_flag) {
        // flags will always have None = 0
        try writer.writeAll(tab ++ "None = 0," ++ newline ++ newline);
        enum_val_offset += 1;
    }
    for (@"enum".members, 0..) |member, i| {
        try tabIf(writer, !enable_nullable);
        try writer.print(tab ++ "[EnumMember(Value = \"{s}\")]" ++ newline, .{member});
        try tabIf(writer, !enable_nullable);
        try writer.print(tab ++ "{f} = {d}", .{
            Casing.titleCase(member),
            if (@"enum".is_flag) std.math.pow(usize, 2, i) else i + enum_val_offset,
        });

        if (i < @"enum".members.len - 1)
            try writer.writeAll("," ++ newline ++ newline);
    }
    try writer.writeAll(newline);
    try tabIf(writer, !enable_nullable);
    try writer.writeAll("}" ++ newline);
    if (!enable_nullable) try writer.writeByte('}');
}

fn formatSummary(arena: Allocator, summary: []const u8, tabs: u8) Allocator.Error![]const u8 {
    var stream: Io.Writer.Allocating = .init(arena);
    stream.writer.writeAll(newline) catch return error.OutOfMemory;
    for (0..tabs) |_| stream.writer.writeAll(&tab) catch return error.OutOfMemory;
    stream.writer.writeAll("/// ") catch return error.OutOfMemory;
    return try mem.replaceOwned(u8, arena, summary, "\n", stream.written());
}

fn writeCsprojFile(
    io: Io,
    dir: Dir,
    csproj: []const u8,
    opts: Options,
    open_err: *?Io.File.OpenError,
    write_err: *?Io.File.Writer.Error,
) Io.Cancelable!void {
    const csproj_file: File = dir.createFile(io, csproj, .{}) catch |err| return switch (err) {
        error.Canceled => |canceled| canceled,
        else => |e| open_err.* = e,
    };
    defer csproj_file.close(io);
    log.info("Created file {s} \u{1f4be}", .{csproj});

    var buf: [2048]u8 = undefined;
    var writer: File.Writer = csproj_file.writer(io, &buf);
    writer.interface.print(
        \\<Project Sdk="Microsoft.NET.Sdk">
        \\
        \\  <PropertyGroup>
        \\    <TargetFramework>{s}</TargetFramework>
        \\    <ImplicitUsings>disable</ImplicitUsings>
        \\    <Nullable>{s}</Nullable>
        \\  </PropertyGroup>
        \\
        \\  <ItemGroup>
        \\    <PackageReference Include="Newtonsoft.Json" Version="{s}" />
        \\    <PackageReference Include="System.ComponentModel.Annotations" Version="5.0.0" />
        \\  </ItemGroup>
        \\
        \\  <PropertyGroup>
        \\    <NoWarn>0612,8019</NoWarn>
        \\  </PropertyGroup>
        \\
        \\  <ItemGroup>
        \\    <Folder Include="{s}\" />
        \\  </ItemGroup>
        \\
        \\</Project>
    , .{
        if (opts.enable_nullable) "net10.0" else "netstandard2.0",
        if (opts.enable_nullable) "enable" else "disable",
        opts.newtonsoft_version,
        opts.models_dir,
    }) catch {
        write_err.* = writer.err.?;
        return;
    };
    writer.flush() catch |err| return switch (err) {
        error.Canceled => |canceled| canceled,
        else => |e| write_err.* = e,
    };
    log.info("\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 Finished writing {d} bytes to file {s} \u{2705}", .{ writer.pos, csproj });
}

fn checkEnumExceptions(enum_options: *const EnumOptions) void {
    var iter: std.StringHashMapUnmanaged(bool).Iterator = enum_options.except_for.iterator();
    while (iter.next()) |entry| {
        if (!entry.value_ptr.*) {
            log.warn("Enum '{s}' was called out as an exception to the behavior of {s} `None = 0`, but that enum was not found.", .{
                entry.key_ptr.*,
                if (enum_options.emit_none) "including" else "omitting",
            });
        }
    }
}

fn tabIf(writer: *Io.Writer, condition: bool) !void {
    if (condition) try writer.writeAll(&tab);
}

pub const Options = struct {
    newtonsoft_version: []const u8 = default_newtonsoft_version,
    enable_nullable: bool = true,
    sln: ?SlnOptions = null,
    generate_csproj: bool = false,
    models_dir: []const u8,
    enums: EnumOptions,
};

pub const SlnOptions = struct {
    path: []const u8,
    parent_dir_path: []const u8,
};

pub const EnumOptions = struct {
    /// Are we emitting `None = 0` for enums as a general rule?
    emit_none: bool,
    /// And which enums are being called out as an exception?
    except_for: std.StringHashMapUnmanaged(bool),
};

pub const default_newtonsoft_version: []const u8 = "13.0.4";

const newline: []const u8 = "\n"; // I'm sorry, but screw you, Windows
const tab: [4]u8 = @splat(' ');
const log = std.log.scoped(.generation);

const std = @import("std");
const composing = @import("composing");
const builtin = @import("builtin");
const zutil = @import("zutil");
const fmt = std.fmt;
const mem = std.mem;
const Io = std.Io;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayListUnmanaged;
const FileGen = composing.FileGen;
const Property = composing.Property;
const RefMap = composing.Composer.RefMap;
const DataAnnotations = composing.DataAnnotations;
const Dir = Io.Dir;
const File = Io.File;
const Casing = zutil.string.Casing;
